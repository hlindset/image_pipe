defmodule ImagePipe.Decode do
  # Source fetch and image decode bracket.
  #
  # `with_image/4` fetches through `ImagePipe.Source.with_fetched/3`, admits only
  # sources whose signature names an accepted family, checks bounded header
  # dimensions when available, verifies that libvips chose a loader of that family,
  # reads stored dimensions and EXIF orientation
  # through libvips, then reopens sequentially with planned
  # shrink-on-load options. It passes the resulting `ImagePipe.Transform.State`
  # and `ImagePipe.Transform.SourceGeometry` to the caller.
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  alias Image.Options.Open, as: ImageOpenOptions
  alias ImagePipe.Decode.HeaderDimensions
  alias ImagePipe.Decode.SourceFormat
  alias ImagePipe.Decode.Streaming
  alias ImagePipe.Decode.WebpFrames
  alias ImagePipe.Format.Detector
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Foreign
  alias Vix.Vips.Image, as: VipsImage

  @peek_bytes 32 * 1024
  @reject_families [:bmp, :ico, :svg, :avif_sequence, :unknown]

  @type error() ::
          {:source, term()}
          | {:decode, term()}
          | {:input_limit, term()}
          | {:page_out_of_range, non_neg_integer(), pos_integer()}
  @type input() ::
          Source.Resolved.t() | Source.Response.t() | {:download, pid(), binary()} | seekable()

  @typedoc "A fetched source body that every decode can reopen."
  @type seekable() :: {:path, Path.t()} | {:buffer, binary()}

  @doc "Returns whether a JPEG or PNG prefix opens successfully with the matching decoder."
  defdelegate streamable_source?(prefix), to: Streaming, as: :eligible?

  @doc """
  Fetches and decodes a source, then calls `fun` with its `Transform.State`
  and `SourceGeometry`.

  The request owns EXIF orientation and decode-time preflight intent.
  After the header open, the bracket passes the request and resulting
  `SourceGeometry` to `ImagePipe.Transform.Executor.decode_options/2`, which
  returns the shrink-on-load options for the sequential re-open.

  Returns errors tagged `{:source, _}` for fetch failures, `{:decode, _}` for
  corrupt/unsupported bodies or libvips open failures, and `{:input_limit, _}`
  when stored dimensions exceed `opts[:max_input_pixels]` or the source declares
  more frames or pages than `opts[:max_input_frames]`. Only the first frame or
  page is decoded, so the pixel limit applies per frame. The frame limit guards
  the loader's own walk over every frame: an animated WebP is counted from its
  container before any libvips open, and other families are checked against
  libvips' `n-pages` before the decoding re-open. These tags map to
  HTTP statuses in `Response.ErrorStatus`. `fun`'s return value passes through
  unchanged, including errors.

  ## The `[:source, :fetch_decode]` span

  The span starts before `Source.with_fetched/3`, enclosing its fetch span,
  and stops after decode, before `fun` runs. This requires a manual
  `Telemetry.start_span/3` bracket so transform/encode failures are attributed
  to the caller. Fetch/decode errors emit an error `:stop`; exceptions before
  decode completes emit `:exception`. Exceptions from `fun` do not close it again.

  ## Skipping

  `skip` is `{formats, on_skip}`. When the source signature names a format in
  `formats`, the bracket calls `on_skip` with that format and the source bytes
  as a chunk enumerable instead of `fun`, without any libvips call or image
  limit check. The span stops with `skipped: true`.
  """
  @spec with_image(
          input(),
          Spec.t(),
          keyword(),
          (State.t(), SourceGeometry.t() -> result),
          {[ImagePipe.Format.source_format()],
           (ImagePipe.Format.source_format(), Enumerable.t() -> result) | nil}
        ) :: result | {:error, error()}
        when result: var
  def with_image(source, %Spec{} = request, opts, fun, skip \\ {[], nil})
      when is_function(fun, 2) do
    auto_rotate? = auto_rotate?(request)
    span = Telemetry.start_span(Telemetry.telemetry_opts(opts), [:source, :fetch_decode], %{})
    decoded = make_ref()
    {skip_formats, on_skip} = skip

    try do
      source
      |> with_source_response(opts, fn response ->
        case decode(response, request, opts, auto_rotate?, skip_formats) do
          {:ok, state, geometry, stop_metadata} ->
            Telemetry.stop_span(span, stop_metadata)
            {decoded, fun.(state, geometry)}

          {:skip, format, detected, input} ->
            Telemetry.stop_span(span, %{
              result: :ok,
              skipped: true,
              detected_source_format: detected
            })

            {decoded, on_skip.(format, chunks(input))}

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

  @doc """
  Fetches `source` once and calls `fun` with a seekable body, which
  `with_image/5` can decode any number of times, each with its own plan.

  Returns `fun`'s result, or the `{:source, _}` error from fetching or
  draining the body.
  """
  @spec with_seekable(Source.Resolved.t() | Source.Response.t(), keyword(), (seekable() -> r)) ::
          r | {:error, error()}
        when r: var
  def with_seekable(source, opts, fun) when is_function(fun, 1) do
    with_source_response(source, opts, fn response ->
      with {:ok, input} <- input(response), do: fun.(input)
    end)
  end

  @doc """
  Decodes a watermark asset's bytes into its default image in display
  orientation.

  Applies the same family allowlist, frame limit, and per-frame pixel limit as
  `with_image/4`. Failures are `{:decode, _}` or `{:input_limit, _}`.
  """
  @spec watermark(binary(), keyword()) :: {:ok, VipsImage.t()} | {:error, error()}
  def watermark(bytes, opts) when is_binary(bytes) do
    input = {:buffer, bytes}

    with {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- gate_detected(detected) |> wrap_decode_error(),
         :ok <- validate_header_pixels(peek, opts) |> wrap_input_limit_error(),
         :ok <- validate_container_frames(peek, input, opts),
         {:ok, image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         :ok <- validate_frames(page_count(image), opts) |> wrap_input_limit_error(),
         {:ok, _format, _resolution} <-
           resolve_source_format(detected, image) |> wrap_decode_error(),
         :ok <-
           validate_pixels({Image.width(image), Image.height(image)}, 1, opts)
           |> wrap_input_limit_error() do
      case Image.autorotate(image) do
        {:ok, {image, _flags}} -> {:ok, image}
        error -> wrap_decode_error(error)
      end
    end
  end

  defp with_source_response(%Source.Resolved{} = source, opts, fun),
    do: Source.with_fetched(source, opts, fun)

  defp with_source_response(input, _opts, fun), do: fun.(input)

  # The marker distinguishes `fun`'s result from a fetch/decode error, which
  # still needs to close the span.
  defp unwrap_decoded({decoded, result}, _span, decoded), do: result

  defp unwrap_decoded({:error, reason} = error, span, _decoded) do
    Telemetry.stop_span(span, error_stop_metadata(reason))
    error
  end

  defp decode(response, request, opts, auto_rotate?, skip_formats) do
    with {:ok, input} <- input(response),
         {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- check_skip(detected, skip_formats, input),
         :ok <- gate_detected(detected) |> wrap_decode_error(),
         :ok <- validate_header_pixels(peek, opts) |> wrap_input_limit_error(),
         :ok <- validate_container_frames(peek, input, opts),
         :ok <- verify_file_loader(detected, input) |> wrap_decode_error(),
         {:ok, header_image} <-
           open_seekable_input(input, header_options(input), opts) |> wrap_decode_error(),
         frames = page_count(header_image),
         :ok <- validate_frames(frames, opts) |> wrap_input_limit_error(),
         {:ok, source_format, resolution} <-
           resolve_source_format(detected, header_image) |> wrap_decode_error(),
         {:ok, page_image} <- select_page(header_image, request.page, frames, input, opts),
         storage_dimensions = {Image.width(page_image), Image.height(page_image)},
         :ok <-
           validate_pixels(storage_dimensions, frames_decoded(request.page, header_image), opts)
           |> wrap_input_limit_error(),
         pending_orientation =
           PendingOrientation.from_exif(exif_orientation(page_image), auto_rotate?),
         display_dimensions =
           PendingOrientation.display_dims(storage_dimensions, pending_orientation),
         geometry = %SourceGeometry{
           storage_dimensions: storage_dimensions,
           display_dimensions: display_dimensions,
           pending_orientation: pending_orientation,
           source_format: source_format,
           pages: frames,
           debug_facts: debug_facts(input, page_image, opts)
         },
         decode_options = Executor.decode_options(request, geometry) ++ page_option(request.page),
         {:ok, image} <- reopen(input, header_image, decode_options, opts) do
      state = seed_state(image, storage_dimensions, decode_options, pending_orientation, opts)

      {:ok, state, geometry,
       ok_stop_metadata(image, decode_options, storage_dimensions, detected, resolution)
       |> Map.put(:source_frames, frames)
       |> put_page(request.page)}
    end
  end

  defp check_skip(detected, skip_formats, input) do
    format = skip_format(detected)

    case format in skip_formats do
      true -> {:skip, format, detected, input}
      false -> :ok
    end
  end

  defp skip_format(:avif_sequence), do: :avif
  defp skip_format(detected), do: detected

  @chunk_bytes 65_536

  defp chunks({:path, path}), do: File.stream!(path, @chunk_bytes)
  defp chunks({:download, download, _prefix}), do: Source.Download.stream(download)

  defp chunks({:buffer, binary}) do
    Stream.unfold(binary, fn
      "" -> nil
      <<chunk::binary-size(@chunk_bytes), rest::binary>> -> {chunk, rest}
      rest -> {rest, ""}
    end)
  end

  defp auto_rotate?(%Spec{orient: :auto}), do: true
  defp auto_rotate?(%Spec{orient: :none}), do: false

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
    do: %{
      result: :processing_error,
      error: Telemetry.error_tag(inner),
      detected_source_format: family
    }

  defp error_stop_metadata({:input_limit, {:too_many_input_frames, _count, _max}}),
    do: %{result: :processing_error, error: :input_limit, limit: :frames}

  defp error_stop_metadata({:input_limit, {:too_many_input_pixels, _count, _max}}),
    do: %{result: :processing_error, error: :input_limit, limit: :pixels}

  defp error_stop_metadata({:decode, {:unsupported_source_format, family, loader} = inner}) do
    %{
      result: :processing_error,
      error: Telemetry.error_tag(inner),
      detected_source_format: family,
      source_loader: loader
    }
  end

  defp error_stop_metadata({:page_out_of_range, page, pages}) do
    %{result: :processing_error, error: :page_out_of_range, page: page, source_frames: pages}
  end

  defp error_stop_metadata({:source, error}),
    do: %{result: :source_error, error: Telemetry.error_tag(error)}

  defp error_stop_metadata(error),
    do: %{result: :processing_error, error: Telemetry.error_tag(error)}

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

  defp input({:download, _pid, _prefix} = input), do: {:ok, input}
  defp input({kind, _body} = input) when kind in [:path, :buffer], do: {:ok, input}
  defp input(%Source.Response{} = response), do: seekable_input(response)

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

  defp peek_bytes({:download, _download, prefix}), do: {:ok, prefix}

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

  # Only a loader of the detected family may decode the source. libvips picks
  # by sniffing, so a higher-priority loader for the same signature (such as a
  # RAW loader for TIFF-signature files) would otherwise decode it.
  defp resolve_source_format(detected, header_image) do
    with {:ok, source_format} <- SourceFormat.verify(header_image, detected) do
      {:ok, source_format, resolution(detected)}
    end
  end

  defp resolution(detected) when detected in [:avif, :heif], do: :libvips_codec
  defp resolution(_detected), do: :detected

  # libvips' file sniffing lets a RAW loader claim TIFF-signature files by name
  # (`.dng`, `.nef`, ...), and that loader parses the file during the header
  # open, before `resolve_source_format/2` could reject it.
  defp verify_file_loader(:tiff, {:path, path}) do
    case Foreign.find_load(path) do
      {:ok, "VipsForeignLoadTiff" <> _suffix} -> :ok
      {:ok, loader} -> {:error, {:unsupported_source_format, :tiff, loader}}
      {:error, _reason} = error -> error
    end
  end

  defp verify_file_loader(_detected, _input), do: :ok

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

  defp open_seekable_input({:download, download, prefix}, decode_options, opts) do
    case Keyword.fetch!(decode_options, :access) do
      :random -> open_buffer(prefix, decode_options, opts)
      :sequential -> Streaming.open(download, decode_options)
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

  defp validate_header_pixels(peek, opts) do
    case HeaderDimensions.read(peek) do
      {:ok, dimensions} -> validate_pixels(dimensions, 1, opts)
      :unknown -> :ok
    end
  end

  defp validate_container_frames(peek, input, opts) do
    if WebpFrames.animated?(peek) do
      max_input_frames = Keyword.fetch!(opts, :max_input_frames)

      case WebpFrames.count(input, max_input_frames) do
        {:ok, frames} -> validate_frames(frames, opts) |> wrap_input_limit_error()
        {:error, _reason} = error -> wrap_decode_error(error)
      end
    else
      :ok
    end
  end

  defp page_count(image) do
    case VipsImage.header_value(image, "n-pages") do
      {:ok, pages} when is_integer(pages) and pages > 0 -> pages
      _ -> 1
    end
  end

  defp validate_frames(frames, opts) do
    max_input_frames = Keyword.fetch!(opts, :max_input_frames)

    if frames <= max_input_frames do
      :ok
    else
      {:error, {:too_many_input_frames, frames, max_input_frames}}
    end
  end

  # Without a page, libvips decodes the source's default image (the primary
  # image for HEIF), which can differ from page 0. A selected page gets its own
  # header open so its dimensions and orientation apply.
  defp select_page(header_image, nil, _pages, _input, _opts), do: {:ok, header_image}

  defp select_page(_header_image, page, pages, _input, _opts) when page >= pages,
    do: {:error, {:page_out_of_range, page, pages}}

  defp select_page(_header_image, page, _pages, input, opts) do
    input
    |> open_seekable_input([access: :random, fail_on: :error, page: page], opts)
    |> wrap_decode_error()
  end

  # A download's header comes from its buffered prefix, which can't be decoded
  # in full. A path or buffer opens sequentially, as its decode does, so a
  # decode without load options reuses the header open.
  defp header_options({:download, _download, _prefix}), do: [access: :random, fail_on: :error]
  defp header_options(_input), do: [access: :sequential, fail_on: :error]

  defp reopen(input, header_image, decode_options, opts) do
    if decode_options == header_options(input),
      do: {:ok, header_image},
      else: input |> open_seekable_input(decode_options, opts) |> wrap_decode_error()
  end

  defp page_option(nil), do: []
  defp page_option(page), do: [page: page]

  defp put_page(metadata, nil), do: metadata
  defp put_page(metadata, page), do: Map.put(metadata, :page, page)

  # Timed frames (animations carry `delay`) are composited onto the frames
  # before them, so decoding frame N decodes N + 1 canvases. Pages of a TIFF or
  # HEIF collection decode independently.
  defp frames_decoded(nil, _header_image), do: 1

  defp frames_decoded(page, header_image) do
    case VipsImage.header_value(header_image, "delay") do
      {:ok, _delays} -> page + 1
      _still -> 1
    end
  end

  defp validate_pixels({w, h}, frames, opts) do
    max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
    pixel_count = w * h * frames

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

  # Collect non-sensitive debug facts on every generation; rendering is gated
  # elsewhere. Missing values return nil/false. Exceptions emit one debug error
  # event and discard the facts so collection cannot break decoding.
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
        %{error: Telemetry.error_tag(exception)}
      )

      %{}
  end

  defp source_byte_size({:buffer, binary}), do: byte_size(binary)
  defp source_byte_size({:download, _download, _prefix}), do: nil

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
