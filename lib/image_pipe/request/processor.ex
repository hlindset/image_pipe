defmodule ImagePipe.Request.Processor do
  @moduledoc false

  alias Image.Options.Open, as: ImageOpenOptions
  alias ImagePipe.Error
  alias ImagePipe.Format.Detector
  alias ImagePipe.Plan
  alias ImagePipe.Request.Options
  alias ImagePipe.Request.SourceFormat
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VixMutableImage

  @type source_format() :: SourceFormat.source_format()
  @type decoded() :: %{
          required(:decode_options) => keyword(),
          required(:image) => VipsImage.t(),
          required(:source_format) => source_format(),
          optional(:source_dimensions) => {pos_integer(), pos_integer()} | nil,
          optional(:original_dims) => {pos_integer(), pos_integer()},
          optional(:achieved_shrink) => %{w: float(), h: float()} | nil,
          optional(:detected_source_format) => Detector.detected(),
          optional(:source_format_resolution) => :detected | :libvips_codec | :libvips_fallback,
          optional(:source_bytes) => non_neg_integer() | nil,
          optional(:source_color_space) => atom() | nil,
          optional(:source_icc?) => boolean() | nil,
          optional(:source_bit_depth) => pos_integer() | nil,
          optional(:source_alpha?) => boolean() | nil,
          optional(:source_orientation) => 1..8 | nil
        }

  @peek_bytes 32 * 1024
  @reject_families [:gif, :bmp, :ico, :svg]
  @authoritative_formats [:jpeg, :png, :webp, :tiff, :jpeg2000, :jpeg_xl]

  @spec process_source(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_source(%Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
    with {:ok, decoded} <-
           fetch_decode_validate_source_with_source_format(plan, resolved_source, opts),
         {:ok, %State{} = state} <- process_decoded_source(decoded, plan, opts) do
      materialize_for_delivery(state, opts)
    end
  end

  @spec fetch_decode_validate_source_with_source_format(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, decoded()} | {:error, term()}
  def fetch_decode_validate_source_with_source_format(
        %Plan{} = plan,
        %Source.Resolved{} = resolved_source,
        opts
      ) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    Telemetry.span(telemetry_opts, [:source, :fetch_decode], %{}, fn ->
      result =
        with {:ok, %Source.Response{} = source_response} <-
               Source.fetch(resolved_source, opts, Options.source_runtime_opts(opts)) do
          decode_validate_source_response(source_response, plan, opts)
        end

      {result, fetch_decode_stop_metadata(result)}
    end)
  end

  @spec decode_validate_source_response(Source.Response.t(), Plan.t(), keyword()) ::
          {:ok, decoded()} | {:error, term()}
  def decode_validate_source_response(%Source.Response{} = source_response, %Plan{} = plan, opts) do
    operations = first_pipeline_operations(plan)

    with {:ok, input} <- seekable_input(source_response),
         {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- gate_detected(detected),
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         {:ok, source_format, resolution} <- resolve_source_format(detected, header_image),
         original_dims = {Image.width(header_image), Image.height(header_image)},
         :ok <- validate_original_pixels(original_dims, opts) |> wrap_input_limit_error(),
         decode_options =
           DecodePlanner.open_options(
             operations,
             source_format,
             original_dims,
             exif_quarter_turn?(header_image),
             plan.auto_rotate
           ),
         {:ok, image} <-
           open_seekable_input(input, decode_options, opts)
           |> wrap_decode_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format,
         detected_source_format: detected,
         source_format_resolution: resolution,
         source_dimensions: shrink_source_dimensions(decode_options, original_dims),
         original_dims: original_dims,
         achieved_shrink: compute_achieved_shrink(original_dims, image),
         source_bytes: source_byte_size(input),
         source_color_space: source_interpretation(header_image),
         source_icc?: source_has_icc?(header_image),
         source_bit_depth: source_bit_depth(header_image),
         source_alpha?: Image.has_alpha?(header_image),
         source_orientation: source_orientation(header_image)
       }}
    end
  end

  # The residual resize sizes against the exact original extent — but only when the
  # decode was actually shrunk. With no shrink the transform layer reads the live
  # image dims instead (which also keeps a crop-before-resize correct), so we leave
  # it `nil`. These are the stored (pre-orientation) dims, which stay in the storage
  # frame (orientation is deferred and flushed after the resize). They are scoped to
  # the pipeline whose decode produced them: a preceding crop and the residual resize
  # each clear them (alongside `decode_shrink`), so they never leak into a later
  # pipeline.
  defp shrink_source_dimensions(decode_options, original_dims) do
    if Keyword.has_key?(decode_options, :shrink) or Keyword.has_key?(decode_options, :scale) do
      original_dims
    else
      nil
    end
  end

  @spec process_decoded_source(decoded(), Plan.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_decoded_source(
        %{image: image} = decoded,
        %Plan{} = plan,
        opts
      ) do
    source_dimensions = Map.get(decoded, :source_dimensions)

    # The realized shrink is only meaningful when shrink-on-load actually fired;
    # `source_dimensions` is the same gate (set iff a shrink/scale load option was
    # emitted). A crop preceding the resize uses it to rescale absolute coords.
    decode_shrink = if source_dimensions, do: Map.get(decoded, :achieved_shrink), else: nil

    initial_state = %State{
      image: image,
      source_dimensions: source_dimensions,
      decode_shrink: decode_shrink
    }

    operation_names = Plan.operation_names(plan)

    execute_start_meta = %{
      operations: operation_names,
      operation_count: length(operation_names)
    }

    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:transform, :execute],
      execute_start_meta,
      fn ->
        result = execute_transform_plan(initial_state, plan, opts)
        {result, transform_stop_metadata(result)}
      end
    )
  end

  # PlanExecutor owns the pipeline loop: it seeds the EXIF orientation once
  # (seed_orientation), iterates all pipelines, and resolves any still-pending
  # orientation at each pipeline boundary (a backstop — within a pipeline the flush
  # usually fires earlier, at the first materializing op or after a resize). The
  # request layer adds the delivery backstop afterward (materialize_for_delivery) —
  # materializing any chain that never materialized mid-pipeline before delivery.
  defp execute_transform_plan(%State{} = state, %Plan{} = plan, opts) do
    Transform.execute_plan(plan, state, Keyword.put(opts, :seed_orientation, true))
    |> classify_materialize_error()
  end

  defp classify_materialize_error({:error, {:materialize_error, reason}}),
    do: {:error, {:decode, reason}}

  defp classify_materialize_error(result), do: result

  defp first_pipeline_operations(%Plan{
         pipelines: [%ImagePipe.Plan.Pipeline{operations: operations} | _rest]
       }),
       do: operations

  defp first_pipeline_operations(%Plan{pipelines: []}), do: []

  defp seekable_input(%Source.Response{path: path, stream: nil}) when is_binary(path),
    do: {:ok, {:path, path}}

  # The drained value is a host-implementable Source adapter stream (a boundary we
  # don't control). A StreamError carries a classified source reason; any other
  # exception/throw/exit raised while draining the source is normalized to a safe
  # {:source, :stream_exception} (→ 422) rather than crashing the request.
  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
    _exception -> {:error, {:source, :stream_exception}}
  catch
    _kind, _reason -> {:error, {:source, :stream_exception}}
  end

  defp seekable_input(%Source.Response{}), do: {:error, {:source, :invalid_adapter_result}}

  # The bounded header peek that feeds format detection. For a drained buffer this
  # is a zero-copy sub-binary; for a path it reads at most @peek_bytes without
  # consuming or seeking the independent libvips open (so the seekable-decode path
  # is untouched).
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

  # Reject known-unsupported formats before libvips touches the bytes. The error
  # shape matches SourceFormat's, which the response sender already handles.
  defp gate_detected(detected) when detected in @reject_families,
    do: {:error, {:unsupported_source_format, detected}}

  defp gate_detected(_detected), do: :ok

  # Authoritative where magic is confident; libvips supplies the avif-vs-heif codec
  # split and the :unknown fallback (the header is opened anyway, and libvips stays
  # the validator).
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

  # A file path opens through `Image.open/2`, which routes to the libvips file loader and
  # preserves loader options (including `:access`).
  defp open_seekable_input({:path, path}, decode_options, opts) do
    case Keyword.get(opts, :image_open_module) do
      nil -> Image.open(path, decode_options)
      module -> module.open(path, decode_options)
    end
  end

  # A drained buffer opens through the libvips buffer loader directly via `new_from_buffer/2`.
  # We do NOT use `Image.open/2` (a binary matching no image signature is misrouted as a
  # filesystem path) nor `Image.from_binary/2` (it strips `:access`, silently downgrading the
  # planner's `:sequential` selection to libvips' random default). Validating the open options
  # the same way the `image` library does, then calling `new_from_buffer/2`, detects the format
  # from the bytes for any supported format AND carries `:access`/`fail_on:` through to libvips.
  # The buffer loader is injectable so tests can observe the options libvips actually receives.
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

  @doc """
  Called by `process_source/3` after transform execution and by the producer after
  `Output.Clamp`, to materialize the lazy vips state before encoding. Returns
  `{:ok, state}` unchanged if an op already materialized mid-pipeline; maps a
  materialize failure to a decode error (→ 415).
  """
  @spec materialize_for_delivery(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize_for_delivery(%State{} = state, opts) do
    result =
      if state.materialized? do
        {:ok, state}
      else
        materialize_state(state, opts)
      end

    with {:ok, %State{} = materialized} <- classify_delivery_materialize_result(result) do
      {:ok, stamp_color_carry(materialized)}
    end
  end

  # Carry the imported source ICC profile onto private image metadata so the
  # encoder's colorspace-to-result step can re-embed it. Only when an import ran.
  defp stamp_color_carry(%State{color_imported?: false} = state), do: state

  defp stamp_color_carry(%State{source_color_profile: profile} = state)
       when is_binary(profile) do
    {:ok, image} =
      VipsImage.mutate(state.image, fn mut ->
        :ok = VixMutableImage.set(mut, "imagepipe-icc-backup", :VipsBlob, profile)
        :ok = VixMutableImage.set(mut, "imagepipe-icc-imported", :gint, 1)
      end)

    State.set_image(state, image)
  end

  defp stamp_color_carry(%State{} = state), do: state

  defp materialize_state(%State{} = state, opts) do
    materializer = Keyword.get(opts, :image_materializer, Materializer)
    materializer.materialize(state, opts)
  end

  defp classify_delivery_materialize_result({:ok, %State{} = state}), do: {:ok, state}
  defp classify_delivery_materialize_result({:error, reason}), do: {:error, {:decode, reason}}

  defp wrap_decode_error({:error, {:source, _reason}} = error), do: error
  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  # Whether the source's EXIF orientation implies a 90°/270° turn. The decode
  # planner uses this (together with the `auto_rotate` flag) to decide whether the
  # shrink axes must be swapped. Reading the header
  # value stays here because only the Request layer holds the decoded image; the
  # orientation *policy* lives in the planner.
  defp exif_quarter_turn?(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, v} when v in [5, 6, 7, 8] -> true
      _ -> false
    end
  end

  defp validate_original_pixels({w, h}, opts) do
    max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
    pixel_count = w * h

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp compute_achieved_shrink({orig_w, orig_h}, image) do
    loaded_w = Image.width(image)
    loaded_h = Image.height(image)
    %{w: max(1.0, orig_w / loaded_w), h: max(1.0, orig_h / loaded_h)}
  end

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

  # Best-effort debug facts captured from the source input and header image.
  # Any failure returns nil; these must never break decoding.

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
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp source_has_icc?(image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, blob} when is_binary(blob) and byte_size(blob) > 0 -> true
      _ -> false
    end
  rescue
    _ -> nil
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
  rescue
    _ -> nil
  end

  defp source_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fetch_decode_stop_metadata(
         {:ok, %{image: image, decode_options: decode_options} = decoded}
       ) do
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
      achieved_shrink: Map.get(decoded, :achieved_shrink),
      original_dims: Map.get(decoded, :original_dims),
      loaded_dims: {Image.width(image), Image.height(image)},
      detected_source_format: Map.get(decoded, :detected_source_format),
      source_format_resolution: Map.get(decoded, :source_format_resolution)
    }
  end

  defp fetch_decode_stop_metadata({:error, {:unsupported_source_format, family} = error}),
    do: %{result: :processing_error, error: Error.tag(error), detected_source_format: family}

  defp fetch_decode_stop_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}

  defp fetch_decode_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}
end
