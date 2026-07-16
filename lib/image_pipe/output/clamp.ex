defmodule ImagePipe.Output.Clamp do
  @moduledoc false
  # Generic, product-neutral uniform downscale of a realized image so it fits a
  # set of result caps: per-axis dimensions (`:max_width`/`:max_height`) and a
  # total pixel budget (`:max_pixels`). The producer passes the EFFECTIVE caps =
  # min(host max_result_*, encoder limit), so encoding cannot fail AND the host
  # result cap downscales rather than errors (imgproxy `limitScale` parity).
  #
  # The core `clamp/3` is product-neutral and format-blind: it reads/resizes via
  # the `image` library directly and returns `clamp_info` describing what it did.
  # `clamp_with_telemetry/4` is the shared seam every stack (framework + dialects)
  # calls: it runs `clamp/3` and, when clamping occurred, emits the `[:output,
  # :clamp]` one-shot tagged with the negotiated `format`. Format enters here only
  # to label that event, never to influence the resize.
  #
  # Resize is lazy; measuring width/height reads libvips header fields (O(1)).

  alias ImagePipe.Telemetry
  alias Vix.Vips.Image, as: VixImage

  @type limit :: pos_integer() | :infinity
  @type limits :: %{max_width: limit(), max_height: limit(), max_pixels: limit()}

  @type clamp_info :: %{
          scale: float(),
          source_dimensions: {pos_integer(), pos_integer()},
          dimensions: {pos_integer(), pos_integer()},
          limits: limits()
        }

  # Bounded escape for the pixel verify-and-shrink loop. Realistic caps converge
  # in one iteration; the bound only guards an adversarially tiny pixel cap (a
  # few hundred px) that needs several geometric steps.
  @max_pixel_iterations 16

  @spec clamp(VixImage.t(), limits(), keyword()) ::
          {:ok, VixImage.t(), clamp_info() | nil}
          | {:error, {:encode, Exception.t(), list()}}
  def clamp(%VixImage{} = image, %{} = limits, opts) do
    w = Image.width(image)
    h = Image.height(image)
    scale = primary_scale(limits, w, h)

    if scale >= 1.0 do
      {:ok, image, nil}
    else
      image_module = Keyword.get(opts, :image_module, Image)

      with {:ok, resized} <- resize(image_module, image, scale),
           {:ok, resized} <- enforce(image_module, image, resized, limits, @max_pixel_iterations) do
        rw = Image.width(resized)
        rh = Image.height(resized)

        {:ok, resized,
         %{
           scale: rw / w,
           source_dimensions: {w, h},
           dimensions: {rw, rh},
           limits: limits
         }}
      end
    end
  end

  # Shared clamp seam: run the product-neutral `clamp/3` and, when it actually
  # downscaled, emit the `[:output, :clamp]` one-shot tagged with the negotiated
  # `format`. All three stacks (framework + both dialects) call this so the event
  # fires from one site. Fires only when clamping occurred (`clamp/3` returns
  # `nil` info for a no-op).
  @spec clamp_with_telemetry(VixImage.t(), limits(), atom(), keyword()) ::
          {:ok, VixImage.t(), clamp_info() | nil}
          | {:error, {:encode, Exception.t(), list()}}
  def clamp_with_telemetry(%VixImage{} = image, %{} = limits, format, opts) do
    with {:ok, resized, info} <- clamp(image, limits, opts) do
      emit_clamp_telemetry(info, format, opts)
      {:ok, resized, info}
    end
  end

  defp emit_clamp_telemetry(nil, _format, _opts), do: :ok

  defp emit_clamp_telemetry(%{} = info, format, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:output, :clamp],
      %{scale: info.scale},
      %{
        format: format,
        source_dimensions: info.source_dimensions,
        dimensions: info.dimensions,
        limits: info.limits
      }
    )

    :ok
  end

  # Most-aggressive scale across the per-axis dimension caps (linear) and the
  # pixel budget (sqrt). Each `*_scale` helper returns exactly 1.0 when its cap
  # does not bind, else a value < 1.0, so the minimum is always <= 1.0; a result
  # of 1.0 means no cap binds -> no-op.
  defp primary_scale(%{max_width: mw, max_height: mh, max_pixels: mp}, w, h) do
    Enum.min([axis_scale(mw, w), axis_scale(mh, h), pixel_scale(mp, w * h)])
  end

  defp axis_scale(:infinity, _dim), do: 1.0
  defp axis_scale(max_dim, dim) when dim <= max_dim, do: 1.0
  defp axis_scale(max_dim, dim), do: max_dim / dim

  defp pixel_scale(:infinity, _px), do: 1.0
  defp pixel_scale(max_px, px) when px <= max_px, do: 1.0
  defp pixel_scale(max_px, px), do: :math.sqrt(max_px / px)

  # Dimension caps are satisfied by the primary resize's construction; only the
  # pixel budget can overshoot (a product of two independently rounded axes), so
  # this loop verifies the realized result and shrinks the dominant axis toward
  # the aspect-preserving pixel budget until it fits. Always resizes from the
  # ORIGINAL (never the already-resized image) to avoid compounding rounding;
  # only ever shrinks, so dimension caps stay satisfied. Checks ALL caps each
  # iteration (defensive). Exhausting the bound is a tagged encode error.
  defp enforce(image_module, original, resized, limits, iters_left) do
    rw = Image.width(resized)
    rh = Image.height(resized)

    cond do
      within_caps?(rw, rh, limits) ->
        {:ok, resized}

      iters_left == 0 ->
        {:error, encode_error(:pixel_enforce_exhausted)}

      true ->
        target_long = shrink_target(rw, rh, limits)
        long_orig = max(Image.width(original), Image.height(original))
        # round-to target_long on the long axis; +0.49 lands on target_long, not target_long+1.
        scale = (target_long + 0.49) / long_orig

        with {:ok, resized} <- resize(image_module, original, scale) do
          enforce(image_module, original, resized, limits, iters_left - 1)
        end
    end
  end

  defp within_caps?(w, h, %{max_width: mw, max_height: mh, max_pixels: mp}) do
    within?(w, mw) and within?(h, mh) and within?(w * h, mp)
  end

  defp within?(_value, :infinity), do: true
  defp within?(value, limit), do: value <= limit

  # Largest dominant-axis length that fits the long axis's own dimension cap and
  # (aspect-preserving) the pixel budget, with a strict -1 progress floor so the
  # loop always advances at least one pixel and therefore terminates. The
  # :infinity terms are naturally ignored by Enum.min (an atom sorts above the
  # always-present `long - 1` integer).
  defp shrink_target(rw, rh, %{max_width: mw, max_height: mh, max_pixels: mp}) do
    long = max(rw, rh)
    short = min(rw, rh)
    long_dim_cap = if rw >= rh, do: mw, else: mh

    Enum.min([long - 1, dim_target(long_dim_cap), pixel_target(mp, long, short)])
  end

  defp dim_target(:infinity), do: :infinity
  defp dim_target(max_dim), do: max_dim

  defp pixel_target(:infinity, _long, _short), do: :infinity
  # long' * (long' * short / long) <= max_px  =>  long' = floor(sqrt(max_px * long / short)).
  # The sqrt is non-negative, so `trunc` is `floor` here.
  defp pixel_target(max_px, long, short), do: trunc(:math.sqrt(max_px * long / short))

  # Per-axis 1px floor: never scale an axis below one realized pixel. This is the
  # equivalent of imgproxy's `WScale >= 1/widthToScale` (prepare.go:252-258) and
  # is what keeps an extreme aspect ratio (e.g. 40000x1) from rounding the short
  # axis to 0 under a tight cap.
  defp resize(image_module, image, scale) do
    w = Image.width(image)
    h = Image.height(image)
    hscale = max(scale, 1.0 / w)
    vscale = max(scale, 1.0 / h)

    case image_module.resize(image, hscale, vertical_scale: vscale) do
      {:ok, resized} -> {:ok, resized}
      {:error, reason} -> {:error, encode_error(reason)}
    end
  end

  defp encode_error(reason) do
    {:encode, RuntimeError.exception("clamp resize failed: #{inspect(reason)}"), []}
  end
end
