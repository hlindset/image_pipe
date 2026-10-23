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
    alias ImagePipe.RawFile
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
    # Pixels from the canvas drawn geometry may reach (ImagePipe.SVG.render/3).
    @max_extent 32_767

    @doc """
    Resolves the validated `svg` options for `max_input_pixels`, and loads
    the fonts, failing on a bad font file or fallback family. The result is
    plain data: a router may build the configuration at compile time, where
    a loaded font set can't be stored. The fonts loaded here stay loaded for
    rendering, unless the configuration was built in another VM, which loads
    them on first use.
    """
    @spec config!(keyword(), pos_integer()) :: map()
    def config!(options, max_input_pixels) do
      config = %{
        font_dirs: Keyword.fetch!(options, :font_dirs),
        fallback_family: options[:fallback_family],
        max_bytes: Keyword.fetch!(options, :max_bytes),
        max_render_work: Keyword.fetch!(options, :max_render_work),
        max_render_pixels: options[:max_render_pixels] || 4 * max_input_pixels
      }

      case :persistent_term.get(fonts_key(config), nil) do
        nil ->
          case SVG.load_fonts(config.font_dirs, fallback_family: config.fallback_family) do
            {:ok, fonts} ->
              :persistent_term.put(fonts_key(config), fonts)

            {:error, message} ->
              raise ArgumentError, "invalid ImagePipe configuration: svg: #{message}"
          end

        _fonts ->
          :ok
      end

      config
    end

    @doc """
    Everything that can change how the same SVG renders: the resvg version,
    the render revision, and the fonts, as loaded for rendering, with the
    fallback family. It enters the cache key and ETag.
    """
    @spec identity(map()) :: map()
    def identity(config) do
      config
      |> fonts()
      |> then(&%{fonts: &1.fingerprint, fallback_family: config.fallback_family})
      |> Map.merge(Map.take(SVG.versions(), [:resvg, :render]))
    end

    @spec decode(Decode.seekable(), Spec.t(), keyword()) ::
            {:ok, State.t(), SourceGeometry.t(), map()} | {:error, Decode.error()}
    def decode(input, %Spec{} = request, opts) do
      Telemetry.span(
        opts,
        [:source, :svg_render],
        %{asset: :original},
        fn ->
          traced_render(input, request, opts)
        end
      )
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

      Telemetry.span(opts, [:source, :svg_parse], %{asset: :watermark}, fn ->
        with {:ok, data} <- read({:buffer, data}, config.max_bytes),
             {:ok, document} <-
               parse(data, fonts(config), Keyword.fetch!(opts, :max_input_pixels)) do
          dims = {max(1, round(document.width)), max(1, round(document.height))}
          render = &render_watermark(document, dims, config, opts, &1, &2)
          {{:ok, %{dims: dims, render: render}}, %{result: :ok, intrinsic_dims: dims}}
        else
          {:error, reason} = error -> {error, error_metadata(reason)}
        end
      end)
    end

    defp render_watermark(document, dims, config, opts, width, height) do
      Telemetry.span(
        opts,
        [:source, :svg_render],
        %{asset: :watermark},
        fn ->
          cost = SVG.cost(document, width, height)

          with :ok <- check_budget(cost, config),
               {:ok, rgba} <- draw(document, width, height),
               {:ok, image} <- image(rgba, width, height) do
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
        end
      )
    end

    defp traced_render(input, request, opts) do
      case render(input, request, opts) do
        {:ok, rendered} -> {decoded(rendered, opts), render_metadata(rendered)}
        {:error, reason} = error -> {error, error_metadata(reason)}
      end
    end

    defp render(input, request, opts) do
      max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
      config = Keyword.fetch!(opts, :svg)

      with {:ok, data} <- read(input, config.max_bytes),
           {:ok, document} <- parse(data, fonts(config), max_input_pixels),
           storage = {max(1, round(document.width)), max(1, round(document.height))},
           geometry = %SourceGeometry{
             storage_dimensions: storage,
             display_dimensions: storage,
             pending_orientation: PendingOrientation.from_exif(1, request.orient == :auto),
             source_format: :svg,
             debug_facts: %{source_bytes: byte_size(data)}
           },
           scale =
             request
             |> Executor.decode_options(
               geometry,
               Keyword.take(opts, [:detector, :detector_required])
             )
             |> Keyword.get(:scale)
             |> fit_scale(storage, max_input_pixels),
           {width, height} = render_size(storage, scale),
           :ok <- check_pixels(width * height, max_input_pixels),
           cost = SVG.cost(document, width, height),
           :ok <- check_budget(cost, config),
           {:ok, rgba} <- draw(document, width, height),
           {:ok, image} <- image(rgba, width, height) do
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
        vector?: scale != nil,
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
    defp limit({:svg_render_budget, :extent, _extent, _max}), do: :svg_render_extent
    defp limit(_reason), do: nil

    # A staged body is measured before it's read into memory.
    defp read({:buffer, data}, max_bytes) do
      with :ok <- check_bytes(byte_size(data), max_bytes), do: {:ok, data}
    end

    defp read({:path, path}, max_bytes) do
      with {:ok, %File.Stat{size: size}} <- RawFile.stat(path),
           :ok <- check_bytes(size, max_bytes),
           {:ok, data} <- RawFile.read(path) do
        {:ok, data}
      else
        {:error, {:input_limit, _reason}} = error -> error
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

    # The fonts load with the configuration, or on first use when it was built
    # in another VM, and stay loaded for the life of the VM. The cache key
    # takes its fingerprint from this same set, so it always matches the
    # fonts that render. One process loads them: replacing a persistent term
    # makes every process scan its heap.
    defp fonts(config) do
      key = fonts_key(config)

      case :persistent_term.get(key, nil) do
        nil -> :global.trans({key, self()}, fn -> load_fonts(key) end, [node()])
        fonts -> fonts
      end
    end

    defp fonts_key(%{font_dirs: dirs, fallback_family: fallback}),
      do: {__MODULE__, :fonts, dirs, fallback}

    defp load_fonts({_module, :fonts, dirs, fallback} = key) do
      with nil <- :persistent_term.get(key, nil) do
        case SVG.load_fonts(dirs, fallback_family: fallback) do
          {:ok, fonts} ->
            :persistent_term.put(key, fonts)
            fonts

          {:error, message} ->
            raise "svg: can't load the fonts in #{inspect(dirs)}: #{message}"
        end
      end
    end

    # Renders larger than the source's intrinsic size are capped at
    # `max_input_pixels`, and the rest of the resize enlarges the raster. A
    # crop then zoom renders the whole document at the zoomed scale, which
    # would otherwise reject an SVG whose raster twin succeeds.
    # The margin covers rounding the render size up.
    defp fit_scale(scale, {width, height}, max_input_pixels)
         when is_float(scale) and scale > 1.0 do
      fitting = :math.sqrt(max_input_pixels / ((width + 1) * (height + 1)))
      min(scale, max(1.0, fitting))
    end

    defp fit_scale(scale, _storage, _max_input_pixels), do: scale

    # The SVG's own size is its intrinsic size rounded to whole pixels, which
    # the request's geometry resolves against, so the render scales that
    # size: a fractional width would otherwise render a pixel off the
    # requested size and be resampled to it.
    defp render_size(storage, nil), do: storage

    defp render_size({width, height}, scale),
      do: {max(1, round(width * scale)), max(1, round(height * scale))}

    defp check_pixels(pixels, max) when pixels <= max, do: :ok

    defp check_pixels(pixels, max),
      do: {:error, {:input_limit, {:too_many_input_pixels, pixels, max}}}

    defp check_budget(%{work: work}, %{max_render_work: max}) when work > max,
      do: {:error, {:input_limit, {:svg_render_budget, :work, work, max}}}

    defp check_budget(%{peak: peak}, %{max_render_pixels: max}) when peak > max,
      do: {:error, {:input_limit, {:svg_render_budget, :peak, peak, max}}}

    defp check_budget(_cost, _config), do: :ok

    defp draw(document, width, height) do
      case SVG.render(document, width, height) do
        {:ok, rgba} ->
          {:ok, rgba}

        {:error, {:out_of_range, extent}} ->
          {:error, {:input_limit, {:svg_render_budget, :extent, extent, @max_extent}}}
      end
    end

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
