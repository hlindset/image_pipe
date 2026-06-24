defmodule ImagePipe.Output.Capabilities do
  @moduledoc false

  # libvips output-format write capability, probed once and cached in
  # :persistent_term. Capabilities cannot change without a process restart, so a
  # process-lifetime cache is correct here.
  #
  # Production callers use `supports?/1` (the boot-probed result). `supports?/2`
  # accepts an `:output_capabilities` map as an internal *test-injection seam* —
  # it lets tests simulate a build that cannot write a given format without
  # touching the global `:persistent_term`, keeping `async: true` tests race-free.
  # This is the same opts-injection convention the request pipeline uses for
  # `:source_session_supervisor`; it is not a documented/validated public option.

  require Logger

  alias Vix.Vips.Image, as: VixImage

  @probed_formats [:avif, :webp, :jpeg_xl]
  @baseline_formats [:jpeg, :png]

  @spec probe() :: :ok
  def probe do
    Enum.each(@probed_formats, fn format ->
      supported? = probe_once(format)
      maybe_warn(format, supported?)
    end)

    :ok
  end

  @spec supports?(atom()) :: boolean()
  def supports?(format) when format in @baseline_formats, do: true
  def supports?(format) when format in @probed_formats, do: probe_once(format)
  def supports?(_format), do: false

  # Internal test seam: an `:output_capabilities` map in `opts` overrides the
  # probe (see module comment). Production omits it and falls back to `supports?/1`.
  @spec supports?(atom(), keyword()) :: boolean()
  def supports?(format, opts) do
    case opts |> Keyword.get(:output_capabilities, %{}) |> Map.fetch(format) do
      {:ok, supported?} -> supported?
      :error -> supports?(format)
    end
  end

  @spec maybe_warn(atom(), boolean()) :: :ok
  defp maybe_warn(_format, true), do: :ok

  defp maybe_warn(format, false) do
    Logger.warning(
      "ImagePipe: libvips build cannot write #{format}; requests resolving to " <>
        "#{format} will fall back (automatic) or be rejected (explicit)."
    )

    :ok
  end

  # Reads the cached result; probes once on first miss and caches it. The probe
  # is a 1x1 in-memory encode, so first-call cost is negligible.
  # Concurrent first-callers may both probe and put; benign — the result is
  # deterministic and :persistent_term.put/2 is atomic.
  defp probe_once(format) do
    case :persistent_term.get({__MODULE__, format}, :unknown) do
      :unknown ->
        result = probe_format(format)
        :persistent_term.put({__MODULE__, format}, result)
        result

      result ->
        result
    end
  end

  # JPEG XL is encoded through Vix directly to a seekable memory buffer (the
  # `image` package's suffix allowlist rejects `.jxl`, and `jxlsave` cannot write
  # a non-seekable target), so its probe must exercise that same path rather than
  # `Image.write` to reflect what the encoder can actually do.
  defp probe_format(:jpeg_xl) do
    with {:ok, image} <- Image.new(8, 8),
         {:ok, _binary} <- VixImage.write_to_buffer(image, ".jxl") do
      true
    else
      _error -> false
    end
  rescue
    _exception -> false
  end

  defp probe_format(format) do
    with {:ok, image} <- Image.new(1, 1),
         {:ok, _binary} <- Image.write(image, :memory, suffix: suffix(format)) do
      true
    else
      _error -> false
    end
  rescue
    # External libvips boundary: any failure means the encoder is unavailable.
    _exception -> false
  end

  defp suffix(:avif), do: ".avif"
  defp suffix(:webp), do: ".webp"
end
