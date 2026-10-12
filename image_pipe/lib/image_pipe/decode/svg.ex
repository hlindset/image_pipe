if Code.ensure_loaded?(ImagePipe.SVG) do
  defmodule ImagePipe.Decode.SVG do
    # Decodes an SVG source by rendering it with `image_pipe_svg`, straight at
    # the size the request's first group needs. Compiled only when the
    # optional `image_pipe_svg` package is installed; without it, `Decode`
    # rejects SVG sources as unsupported.
    #
    # The intrinsic size plays the part of a raster's stored dimensions: crop
    # and region lengths resolve against it, and the render scale is recorded
    # as the decode shrink, which is below 1 when the SVG renders larger.
    @moduledoc false

    alias ImagePipe.Decode
    alias ImagePipe.Plan.Spec
    alias ImagePipe.SVG
    alias ImagePipe.Telemetry
    alias ImagePipe.Transform.Executor
    alias ImagePipe.Transform.PendingOrientation
    alias ImagePipe.Transform.SourceGeometry
    alias ImagePipe.Transform.State
    alias Vix.Vips.Image, as: VipsImage
    alias Vix.Vips.Operation

    # Elements after expanding `<use>`, estimated before usvg expands them.
    @max_elements 200_000
    # Characters entity references may expand to, estimated before parsing.
    @max_entity_expansion 1_000_000

    @doc """
    Resolves the validated `svg` options for `max_input_pixels`. Loads the
    fonts to fail on a bad font file or fallback family, but keeps only plain
    data: a router may build the configuration at compile time, where a
    loaded font set can't be stored. The identity covers everything that can
    change how the same SVG renders, so it enters the cache key and ETag.
    """
    @spec config!(keyword(), pos_integer()) :: map()
    def config!(options, max_input_pixels) do
      font_dirs = Keyword.fetch!(options, :font_dirs)
      fallback_family = options[:fallback_family]

      case SVG.load_fonts(font_dirs, fallback_family: fallback_family) do
        {:ok, fonts} ->
          %{
            font_dirs: font_dirs,
            fallback_family: fallback_family,
            max_bytes: Keyword.fetch!(options, :max_bytes),
            max_render_work: Keyword.fetch!(options, :max_render_work),
            max_render_pixels: options[:max_render_pixels] || 4 * max_input_pixels,
            identity: Map.put(SVG.versions(), :fonts, fonts.fingerprint)
          }

        {:error, message} ->
          raise ArgumentError, "invalid ImagePipe configuration: svg: #{message}"
      end
    end

    @spec decode(Decode.seekable(), Spec.t(), keyword()) ::
            {:ok, State.t(), SourceGeometry.t(), map()} | {:error, Decode.error()}
    def decode(input, %Spec{} = request, opts) do
      with {:ok, data} <- read(input) do
        Telemetry.span(Telemetry.telemetry_opts(opts), [:source, :svg_render], %{}, fn ->
          traced_render(data, request, opts)
        end)
      end
    end

    @doc """
    Parses an SVG watermark asset, returning its intrinsic size and a
    function that renders it at the size the watermark is drawn, within the
    render budget.
    """
    @spec watermark(binary(), keyword()) ::
            {:ok, Decode.watermark_asset()} | {:error, Decode.error()}
    def watermark(data, opts) do
      config = Keyword.fetch!(opts, :svg)

      with :ok <- check_bytes(byte_size(data), config.max_bytes),
           {:ok, document} <-
             parse(data, fonts(config), Keyword.fetch!(opts, :max_input_pixels)) do
        dims = {max(1, round(document.width)), max(1, round(document.height))}
        {:ok, %{dims: dims, render: &render_watermark(document, dims, config, opts, &1, &2)}}
      end
    end

    defp render_watermark(document, dims, config, opts, width, height) do
      Telemetry.span(Telemetry.telemetry_opts(opts), [:source, :svg_render], %{}, fn ->
        cost = SVG.cost(document, width, height)

        with :ok <- check_budget(cost, config),
             {:ok, image} <- image(SVG.render(document, width, height), width, height) do
          {{:ok, image},
           %{
             result: :ok,
             intrinsic_dims: dims,
             rendered_dims: {width, height},
             work: cost.work,
             peak: cost.peak,
             images: cost.images,
             image_pixels: cost.image_pixels
           }}
        else
          {:error, reason} = error -> {error, error_metadata(reason)}
        end
      end)
    end

    defp traced_render(data, request, opts) do
      case render(data, request, opts) do
        {:ok, rendered} -> {decoded(rendered, opts), render_metadata(rendered)}
        {:error, reason} = error -> {error, error_metadata(reason)}
      end
    end

    defp render(data, request, opts) do
      max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
      config = Keyword.fetch!(opts, :svg)

      with :ok <- check_bytes(byte_size(data), config.max_bytes),
           {:ok, document} <- parse(data, fonts(config), max_input_pixels),
           storage = {max(1, round(document.width)), max(1, round(document.height))},
           geometry = %SourceGeometry{
             storage_dimensions: storage,
             display_dimensions: storage,
             pending_orientation: PendingOrientation.from_exif(1, request.orient == :auto),
             source_format: :svg,
             debug_facts: %{source_bytes: byte_size(data)}
           },
           scale = Keyword.get(Executor.decode_options(request, geometry), :scale),
           {width, height} = render_size(document, scale),
           :ok <- check_pixels(width * height, max_input_pixels),
           cost = SVG.cost(document, width, height),
           :ok <- check_budget(cost, config),
           {:ok, image} <- image(SVG.render(document, width, height), width, height) do
        {:ok, %{image: image, geometry: geometry, scale: scale, cost: cost}}
      end
    end

    defp decoded(%{image: image, geometry: geometry, scale: scale}, opts) do
      {stored_width, stored_height} = storage = geometry.storage_dimensions
      {width, height} = {Image.width(image), Image.height(image)}
      decode_shrink = if scale, do: %{w: stored_width / width, h: stored_height / height}

      state = %State{
        image: image,
        source_dimensions: if(scale, do: storage),
        decode_shrink: decode_shrink,
        vector?: true,
        materialized?: true,
        pending_orientation: geometry.pending_orientation,
        telemetry_opts: Telemetry.telemetry_opts(opts)
      }

      {:ok, state, geometry,
       %{
         result: :ok,
         load_option: if(scale, do: {:scale, scale}),
         achieved_shrink: decode_shrink,
         original_dims: storage,
         loaded_dims: {width, height},
         detected_source_format: :svg,
         source_format_resolution: :detected,
         source_frames: 1
       }}
    end

    defp render_metadata(%{image: image, geometry: geometry, cost: cost}) do
      %{
        result: :ok,
        intrinsic_dims: geometry.storage_dimensions,
        rendered_dims: {Image.width(image), Image.height(image)},
        work: cost.work,
        peak: cost.peak,
        images: cost.images,
        image_pixels: cost.image_pixels
      }
    end

    defp error_metadata({tag, reason}),
      do: %{result: :processing_error, error: tag, limit: limit(reason)}

    defp limit({:too_many_svg_bytes, _bytes, _max}), do: :svg_bytes
    defp limit({:too_many_svg_elements, _count, _max}), do: :svg_elements
    defp limit({:svg_entity_expansion, _size, _max}), do: :svg_entities
    defp limit({:too_much_svg_text, _bytes}), do: :svg_text
    defp limit({:too_many_input_pixels, _pixels, _max}), do: :pixels
    defp limit(:svg_nesting_too_deep), do: :svg_nesting
    defp limit({:svg_render_budget, :work, _work, _max}), do: :svg_render_work
    defp limit({:svg_render_budget, :peak, _peak, _max}), do: :svg_render_pixels
    defp limit(_reason), do: nil

    defp read({:buffer, data}), do: {:ok, data}

    defp read({:path, path}) do
      case File.read(path) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, {:decode, {:peek_failed, reason}}}
      end
    end

    defp check_bytes(bytes, max) when bytes <= max, do: :ok
    defp check_bytes(bytes, max), do: {:error, {:input_limit, {:too_many_svg_bytes, bytes, max}}}

    defp parse(data, fonts, max_input_pixels) do
      case SVG.parse(data, fonts,
             max_elements: @max_elements,
             max_image_pixels: max_input_pixels,
             max_entity_expansion: @max_entity_expansion
           ) do
        {:ok, document} ->
          {:ok, document}

        {:error, {:parse, message}} ->
          {:error, {:decode, {:invalid_svg, message}}}

        {:error, {:too_many_elements, count}} ->
          {:error, {:input_limit, {:too_many_svg_elements, count, @max_elements}}}

        {:error, {:too_much_text, bytes}} ->
          {:error, {:input_limit, {:too_much_svg_text, bytes}}}

        {:error, {:entity_expansion, size}} ->
          {:error, {:input_limit, {:svg_entity_expansion, size, @max_entity_expansion}}}

        {:error, {:image_too_large, pixels}} ->
          {:error, {:input_limit, {:too_many_input_pixels, pixels, max_input_pixels}}}

        {:error, :nesting_too_deep} ->
          {:error, {:input_limit, :svg_nesting_too_deep}}
      end
    end

    # The fonts load on first use and stay loaded for the life of the VM, keyed
    # by the font set and its fingerprint taken at startup.
    defp fonts(%{font_dirs: dirs, fallback_family: fallback, identity: %{fonts: fingerprint}}) do
      key = {__MODULE__, :fonts, dirs, fallback, fingerprint}

      case :persistent_term.get(key, nil) do
        nil ->
          {:ok, fonts} = SVG.load_fonts(dirs, fallback_family: fallback)
          :persistent_term.put(key, fonts)
          fonts

        fonts ->
          fonts
      end
    end

    defp render_size(document, nil),
      do: {max(1, round(document.width)), max(1, round(document.height))}

    defp render_size(document, scale),
      do: {max(1, round(document.width * scale)), max(1, round(document.height * scale))}

    defp check_pixels(pixels, max) when pixels <= max, do: :ok

    defp check_pixels(pixels, max),
      do: {:error, {:input_limit, {:too_many_input_pixels, pixels, max}}}

    defp check_budget(%{work: work}, %{max_render_work: max}) when work > max,
      do: {:error, {:input_limit, {:svg_render_budget, :work, work, max}}}

    defp check_budget(%{peak: peak}, %{max_render_pixels: max}) when peak > max,
      do: {:error, {:input_limit, {:svg_render_budget, :peak, peak, max}}}

    defp check_budget(_cost, _config), do: :ok

    # The NIF renders straight-alpha sRGB, which libvips wraps without copying.
    defp image(rgba, width, height) do
      with {:ok, image} <- VipsImage.new_from_binary(rgba, width, height, 4, :VIPS_FORMAT_UCHAR),
           {:ok, image} <- Operation.copy(image, interpretation: :VIPS_INTERPRETATION_sRGB) do
        {:ok, image}
      else
        {:error, reason} -> {:error, {:decode, reason}}
      end
    end
  end
end
