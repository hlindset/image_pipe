# credo:disable-for-this-file ExDNA.Credo
# This module deliberately mirrors ImagePipe.Request.Processor's two-open
# decode flow: Decode cannot depend on the Request boundary (a dialect-owned
# bracket has no framework Request/Plug stack underneath it), so the logic is
# duplicated rather than shared. Processor stays untouched; this is parallel
# logic for the dialect path, not a refactor. Recorded as a deliberate
# duplication in the Task 21.6 core-exports report.
defmodule ImagePipe.Decode do
  @moduledoc """
  Core fetch-through-decode bracket for a dialect that owns its own request
  chain (no `ImagePipe.Request`/`ImagePipe.Plan` underneath it).

  `with_image/4` duplicates `ImagePipe.Request.Processor`'s two-open decode
  flow (header open for stored dims + EXIF orientation, then a sequential
  re-open with shrink-on-load options) as a bracket: it fetches through
  `ImagePipe.Source.with_fetched/3`, builds an `ImagePipe.Transform.SourceGeometry`
  from the header open, asks the caller for a `DecodePlanner.Request.t()` via
  `decode_request_fun`, re-opens sequentially with the planned options, seeds
  a `Transform.State` the same way `ImagePipe.Transform.Executor` does, and
  hands both to `fun`. `Request.Processor` itself is untouched — this is
  parallel logic for the dialect path, not a refactor of the framework path.
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
  (stored header dimensions exceed `opts[:max_input_pixels]`) — the same
  taxonomy `Request.Processor` produces, so a dialect's status mapping can
  reuse `Response.ErrorStatus`. `fun`'s own return value passes through
  unchanged (its own errors, e.g. a transform failure, are the caller's to
  classify).
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

    Source.with_fetched(resolved, opts, fn %Source.Response{} = response ->
      decode_and_run(response, opts, auto_rotate?, decode_request_fun, fun)
    end)
  end

  defp decode_and_run(response, opts, auto_rotate?, decode_request_fun, fun) do
    with {:ok, input} <- seekable_input(response),
         {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- gate_detected(detected) |> wrap_decode_error(),
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         {:ok, source_format, _resolution} <-
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
           source_format: source_format
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
      fun.(state, geometry)
    end
  end

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

  # Mirrors Request.Processor.shrink_source_dimensions/2: the residual resize
  # sizes against the exact original extent, but only when the decode was
  # actually shrunk (a shrink/scale load option was emitted).
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
end
