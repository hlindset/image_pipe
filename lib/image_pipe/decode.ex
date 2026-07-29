defmodule ImagePipe.Decode do
  @moduledoc """
  Core fetch-through-decode bracket, shared by every dialect.

  `with_image/4` runs the two-open decode flow (header open for stored dims +
  EXIF orientation, then a sequential re-open with shrink-on-load options) as a
  bracket: it fetches through `ImagePipe.Source.with_fetched/3`, builds an
  `ImagePipe.Transform.SourceGeometry` from the header open, asks the caller for
  a `DecodePlanner.Request.t()` via `decode_request_fun`, re-opens sequentially
  with the planned options, seeds a `Transform.State` the same way
  `ImagePipe.Transform.Executor` does, and hands both to `fun`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  alias Image.Options.Open, as: ImageOpenOptions
  alias ImagePipe.Decode.SourceFormat
  alias ImagePipe.Error
  alias ImagePipe.Format.Detector
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @peek_bytes 32 * 1024
  @reject_families [:gif, :bmp, :ico, :svg]
  @authoritative_formats [:jpeg, :png, :webp, :tiff, :jpeg2000, :jpeg_xl]

  @type error() :: {:source, term()} | {:decode, term()} | {:input_limit, term()}

  @doc """
  Fetch, decode, and run `fun` over the resulting `Transform.State` +
  `SourceGeometry`.

  `opts` MUST include `auto_rotate?: boolean()` — the EXIF auto-orient policy
  is always the caller's (dialect's) choice, never baked into this core
  primitive; this bracket owns only the storage/display compensation once
  that choice is made. `decode_request_fun` receives the `SourceGeometry`
  built from the header open and must return a `DecodePlanner.Request.t()`
  describing the caller's decode-time preflight (resize target, crop extent,
  trim, terminal reduction, required floor) — fed to
  `DecodePlanner.open_options_for/5` to compute the shrink-on-load options for
  the sequential re-open.

  Errors normalize to `{:source, _}` (fetch failure), `{:decode, _}` (a
  corrupt/unsupported body or a libvips open failure), or `{:input_limit, _}`
  (stored header dimensions exceed `opts[:max_input_pixels]`), so a dialect's
  status mapping can reuse `Response.ErrorStatus`. `fun`'s own return value
  passes through unchanged (its own errors, e.g. a transform failure, are the
  caller's to classify).

  ## The `[:source, :fetch_decode]` span

  This bracket emits the `[:source, :fetch_decode]` span, so every dialect gains
  it from this one seam. The span encloses the fetch AND the decode but NOT the
  caller's build: it opens before `Source.with_fetched/3` (so `[:source,
  :fetch]` nests inside it) and closes *inside* the bracket, immediately after
  the decoded `State`/`SourceGeometry` are built and before `fun` runs — a
  transform/encode failure in `fun` can never be misattributed to it. That
  close site is not a function boundary, hence the manual
  `Telemetry.start_span/3` bracket: a fetch/decode error closes the span with
  an error `:stop`, and a raise before the decode completed closes it with
  `:exception` semantics (a raise from `fun`, after the span already stopped,
  does not re-close it).
  """
  @spec with_image(
          Source.Resolved.t(),
          keyword(),
          (SourceGeometry.t() -> DecodePlanner.Request.t()),
          (State.t(), SourceGeometry.t() -> result)
        ) :: result | {:error, error()}
        when result: var
  def with_image(%Source.Resolved{} = resolved, opts, decode_request_fun, fun)
      when is_function(decode_request_fun, 1) and is_function(fun, 2) do
    auto_rotate? = Keyword.fetch!(opts, :auto_rotate?)
    span = Telemetry.start_span(Telemetry.telemetry_opts(opts), [:source, :fetch_decode], %{})
    decoded = make_ref()

    try do
      resolved
      |> Source.with_fetched(opts, fn %Source.Response{} = response ->
        case decode(response, opts, auto_rotate?, decode_request_fun) do
          {:ok, state, geometry, stop_metadata} ->
            Telemetry.stop_span(span, stop_metadata)
            {decoded, fun.(state, geometry)}

          {:error, _reason} = error ->
            error
        end
      end)
      |> unwrap_decoded(span, decoded)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Telemetry.exception_span(span, kind, reason, stacktrace)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  # `fun` ran (the span already stopped `:ok` inside the bracket): pass its
  # result through untouched. Otherwise the fetch or the decode failed before
  # the build was reached, and the error closes the span here.
  defp unwrap_decoded({decoded, result}, _span, decoded), do: result

  defp unwrap_decoded({:error, reason} = error, span, _decoded) do
    Telemetry.stop_span(span, error_stop_metadata(reason))
    error
  end

  defp decode(response, opts, auto_rotate?, decode_request_fun) do
    with {:ok, input} <- seekable_input(response),
         {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- gate_detected(detected) |> wrap_decode_error(),
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         {:ok, source_format, resolution} <-
           resolve_source_format(detected, header_image) |> wrap_decode_error(),
         storage_dimensions = {Image.width(header_image), Image.height(header_image)},
         :ok <- validate_pixels(storage_dimensions, opts) |> wrap_input_limit_error(),
         pending_orientation =
           PendingOrientation.from_exif(exif_orientation(header_image), auto_rotate?),
         display_dimensions =
           PendingOrientation.display_dims(storage_dimensions, pending_orientation),
         geometry = %SourceGeometry{
           storage_dimensions: storage_dimensions,
           display_dimensions: display_dimensions,
           pending_orientation: pending_orientation,
           source_format: source_format,
           debug_facts: debug_facts(input, header_image, opts)
         },
         decode_request = decode_request_fun.(geometry),
         decode_options =
           DecodePlanner.open_options_for(
             decode_request,
             source_format,
             storage_dimensions,
             exif_quarter_turn?(header_image),
             auto_rotate?
           ),
         {:ok, image} <-
           open_seekable_input(input, decode_options, opts)
           |> wrap_decode_error() do
      state = seed_state(image, storage_dimensions, decode_options, pending_orientation, opts)

      {:ok, state, geometry,
       ok_stop_metadata(image, decode_options, storage_dimensions, detected, resolution)}
    end
  end

  defp ok_stop_metadata(image, decode_options, storage_dimensions, detected, resolution) do
    load_option =
      cond do
        Keyword.has_key?(decode_options, :shrink) ->
          {:shrink, Keyword.fetch!(decode_options, :shrink)}

        Keyword.has_key?(decode_options, :scale) ->
          {:scale, Keyword.fetch!(decode_options, :scale)}

        true ->
          nil
      end

    %{
      result: :ok,
      load_option: load_option,
      achieved_shrink: compute_achieved_shrink(storage_dimensions, image),
      original_dims: storage_dimensions,
      loaded_dims: {Image.width(image), Image.height(image)},
      detected_source_format: detected,
      source_format_resolution: resolution
    }
  end

  # Failure shapes over this module's wrapped error taxonomy: the
  # unsupported-format reject keeps its specific tag and rejected family, a
  # source failure is `:source_error`, and everything else (`{:decode, _}`,
  # `{:input_limit, _}`) is `:processing_error` with its taxonomy tag.
  defp error_stop_metadata({:decode, {:unsupported_source_format, family} = inner}),
    do: %{result: :processing_error, error: Error.tag(inner), detected_source_format: family}

  defp error_stop_metadata({:source, error}),
    do: %{result: :source_error, error: Error.tag(error)}

  defp error_stop_metadata(error),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp seed_state(image, storage_dimensions, decode_options, pending_orientation, opts) do
    source_dimensions = shrink_source_dimensions(decode_options, storage_dimensions)

    decode_shrink =
      if source_dimensions, do: compute_achieved_shrink(storage_dimensions, image), else: nil

    %State{
      image: image,
      source_dimensions: source_dimensions,
      decode_shrink: decode_shrink,
      pending_orientation: pending_orientation,
      telemetry_opts: Telemetry.telemetry_opts(opts)
    }
  end

  # The residual resize sizes against the exact original extent, but only when
  # the decode was actually shrunk (a shrink/scale load option was emitted).
  defp shrink_source_dimensions(decode_options, storage_dimensions) do
    if Keyword.has_key?(decode_options, :shrink) or Keyword.has_key?(decode_options, :scale) do
      storage_dimensions
    else
      nil
    end
  end

  defp compute_achieved_shrink({orig_w, orig_h}, image) do
    loaded_w = Image.width(image)
    loaded_h = Image.height(image)
    %{w: max(1.0, orig_w / loaded_w), h: max(1.0, orig_h / loaded_h)}
  end

  defp seekable_input(%Source.Response{path: path, stream: nil}) when is_binary(path),
    do: {:ok, {:path, path}}

  # The drained value is a host-implementable Source adapter stream (a boundary
  # we don't control). A StreamError carries a classified source reason; any
  # other exception/throw/exit raised while draining the source is normalized
  # to a safe {:source, :stream_exception} rather than crashing.
  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
    _exception -> {:error, {:source, :stream_exception}}
  catch
    _kind, _reason -> {:error, {:source, :stream_exception}}
  end

  defp seekable_input(%Source.Response{}), do: {:error, {:source, :invalid_adapter_result}}

  defp peek_bytes({:buffer, binary}) when is_binary(binary),
    do: {:ok, binary_part(binary, 0, min(byte_size(binary), @peek_bytes))}

  defp peek_bytes({:path, path}) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        result = :file.read(device, @peek_bytes)
        File.close(device)

        case result do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, {:peek_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:peek_failed, reason}}
    end
  end

  defp gate_detected(detected) when detected in @reject_families,
    do: {:error, {:unsupported_source_format, detected}}

  defp gate_detected(_detected), do: :ok

  defp resolve_source_format(detected, _header_image) when detected in @authoritative_formats,
    do: {:ok, detected, :detected}

  defp resolve_source_format(detected, header_image) when detected in [:avif, :heif] do
    case SourceFormat.from_image(header_image) do
      {:ok, source_format} -> {:ok, source_format, :libvips_codec}
      {:error, _reason} -> {:ok, detected, :libvips_codec}
    end
  end

  defp resolve_source_format(:unknown, header_image) do
    case SourceFormat.from_image(header_image) do
      {:ok, source_format} -> {:ok, source_format, :libvips_fallback}
      {:error, _reason} = error -> error
    end
  end

  defp open_seekable_input({:path, path}, decode_options, opts) do
    case Keyword.get(opts, :image_open_module) do
      nil -> Image.open(path, decode_options)
      module -> module.open(path, decode_options)
    end
  end

  defp open_seekable_input({:buffer, binary}, decode_options, opts) do
    case Keyword.get(opts, :image_open_module) do
      nil -> open_buffer(binary, decode_options, opts)
      module -> module.open(binary, decode_options)
    end
  end

  defp open_buffer(binary, decode_options, opts) do
    loader = Keyword.get(opts, :buffer_loader, &VipsImage.new_from_buffer/2)

    with {:ok, vips_opts} <- ImageOpenOptions.validate_options(decode_options) do
      loader.(binary, vips_opts)
    end
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) -> value
      _ -> 1
    end
  end

  defp exif_quarter_turn?(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, v} when v in [5, 6, 7, 8] -> true
      _ -> false
    end
  end

  defp validate_pixels({w, h}, opts) do
    max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
    pixel_count = w * h

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp wrap_decode_error({:error, {:source, _reason}} = error), do: error
  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

  # Best-effort, non-sensitive source facts for the debug headers. Collected on
  # every generation (rendering is gated elsewhere). A genuinely-absent value
  # returns nil/false through the helper's own `case`; only a real raise is an
  # anomaly — surfaced as one `[:debug, :collect, :error]` event, then the whole
  # fact set degrades to %{} so collection never breaks decoding.
  defp debug_facts(input, header_image, opts) do
    %{
      source_bytes: source_byte_size(input),
      source_color_space: source_interpretation(header_image),
      source_icc?: source_has_icc?(header_image),
      source_bit_depth: source_bit_depth(header_image),
      source_alpha?: source_alpha?(header_image),
      source_orientation: source_orientation(header_image)
    }
  rescue
    exception ->
      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:debug, :collect, :error],
        %{},
        %{error: Error.tag(exception)}
      )

      %{}
  end

  defp source_byte_size({:buffer, binary}), do: byte_size(binary)

  defp source_byte_size({:path, path}) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> nil
    end
  end

  defp source_interpretation(image) do
    case VipsImage.interpretation(image) do
      interp when is_atom(interp) -> interp
    end
  end

  defp source_has_icc?(image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, blob} when is_binary(blob) and byte_size(blob) > 0 -> true
      _ -> false
    end
  end

  # Bit depth in bits per sample derived from the image interpretation, mirroring
  # the encoder's `icc_depth/1` logic: 16-bit interpretations yield 16, all others 8.
  defp source_bit_depth(image) do
    case VipsImage.interpretation(image) do
      :VIPS_INTERPRETATION_GREY16 -> 16
      :VIPS_INTERPRETATION_RGB16 -> 16
      :VIPS_INTERPRETATION_scRGB -> 16
      _ -> 8
    end
  end

  defp source_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _ -> nil
    end
  end

  defp source_alpha?(image), do: Image.has_alpha?(image)
end
