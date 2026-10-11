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

    # About a second of rendering at the rates measured in the render budget
    # spike (image_pipe/docs/plans/svg-rasterize.md, Render budget).
    @max_work 250_000_000
    # Pixmap pixels alive at once, as a multiple of `max_input_pixels`.
    @peak_factor 4
    @max_elements 200_000

    @fonts_key {__MODULE__, :fonts}

    @spec decode(Decode.seekable(), Spec.t(), keyword()) ::
            {:ok, State.t(), SourceGeometry.t(), map()} | {:error, Decode.error()}
    def decode(input, %Spec{} = request, opts) do
      max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)

      with {:ok, data} <- read(input),
           {:ok, document} <- parse(data, max_input_pixels),
           storage = {max(1, round(document.width)), max(1, round(document.height))},
           pending = PendingOrientation.from_exif(1, request.orient == :auto),
           geometry = %SourceGeometry{
             storage_dimensions: storage,
             display_dimensions: storage,
             pending_orientation: pending,
             source_format: :svg,
             debug_facts: %{source_bytes: byte_size(data)}
           },
           decode_options = Executor.decode_options(request, geometry),
           scale = Keyword.get(decode_options, :scale),
           {width, height} = render_size(document, scale),
           :ok <- check_pixels(width * height, max_input_pixels),
           :ok <- check_budget(SVG.cost(document, width, height), max_input_pixels),
           {:ok, image} <- image(SVG.render(document, width, height), width, height) do
        state = %State{
          image: image,
          source_dimensions: if(scale, do: storage),
          decode_shrink:
            if(scale, do: %{w: elem(storage, 0) / width, h: elem(storage, 1) / height}),
          vector?: true,
          materialized?: true,
          pending_orientation: pending,
          telemetry_opts: Telemetry.telemetry_opts(opts)
        }

        {:ok, state, geometry,
         %{
           result: :ok,
           load_option: if(scale, do: {:scale, scale}),
           achieved_shrink: state.decode_shrink,
           original_dims: storage,
           loaded_dims: {width, height},
           detected_source_format: :svg,
           source_format_resolution: :detected,
           source_frames: 1
         }}
      end
    end

    defp read({:buffer, data}), do: {:ok, data}

    defp read({:path, path}) do
      case File.read(path) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, {:decode, {:peek_failed, reason}}}
      end
    end

    defp parse(data, max_input_pixels) do
      case SVG.parse(data, fonts(),
             max_elements: @max_elements,
             max_image_pixels: max_input_pixels
           ) do
        {:ok, document} ->
          {:ok, document}

        {:error, {:parse, message}} ->
          {:error, {:decode, {:invalid_svg, message}}}

        {:error, {:too_many_elements, count}} ->
          {:error, {:input_limit, {:too_many_svg_elements, count, @max_elements}}}

        {:error, {:image_too_large, pixels}} ->
          {:error, {:input_limit, {:too_many_input_pixels, pixels, max_input_pixels}}}

        {:error, :nesting_too_deep} ->
          {:error, {:input_limit, :svg_nesting_too_deep}}
      end
    end

    # Text renders only in fonts the host configures. Until it can, SVGs render
    # with no fonts, so their text is left out.
    defp fonts do
      case :persistent_term.get(@fonts_key, nil) do
        nil ->
          {:ok, fonts} = SVG.load_fonts([])
          :persistent_term.put(@fonts_key, fonts)
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

    defp check_budget(%{work: work}, _max_input_pixels) when work > @max_work,
      do: {:error, {:input_limit, {:svg_render_budget, :work, work, @max_work}}}

    defp check_budget(%{peak: peak}, max_input_pixels)
         when peak > @peak_factor * max_input_pixels,
         do:
           {:error,
            {:input_limit, {:svg_render_budget, :peak, peak, @peak_factor * max_input_pixels}}}

    defp check_budget(_cost, _max_input_pixels), do: :ok

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
