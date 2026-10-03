defmodule ImagePipe.Processing.Terminal do
  @moduledoc false

  alias ImagePipe.Decode
  alias ImagePipe.Format
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Output.Terminal.LqipCss
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Output
  alias ImagePipe.Processing
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias Vix.Vips.Image, as: VipsImage

  # The last element is true when a crop fell back after a detection error, so
  # the result must not be stored.
  @spec render(Decode.input(), Spec.t(), keyword()) ::
          {:ok, String.t(), binary() | map(), boolean()} | {:error, term()}
  def render(source, %Spec{} = request, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:output, :terminal],
      start_metadata(request.output),
      fn ->
        result = Processing.with_watermarks(config, &render_terminal(source, request, &1))
        {result, %{result: terminal_result(result)}}
      end
    )
  end

  defp start_metadata(%Output{terminal: :info, placeholders: placeholders}),
    do: %{terminal: :info, placeholders: placeholders}

  defp start_metadata(%Output{terminal: terminal}), do: %{terminal: terminal}

  defp render_terminal(source, %Spec{output: %{terminal: :info}} = request, config) do
    Decode.with_seekable(source, config, &render_info(&1, request, config))
  end

  defp render_terminal(source, %Spec{output: %{terminal: terminal}} = request, config) do
    Decode.with_image(source, request, config, fn state, _geometry ->
      with {:ok, config} <- Processing.watermark_opts(config),
           {:ok, value, degraded?} <- placeholder(terminal, state, request, config) do
        {:ok, "text/plain", value, degraded?}
      end
    end)
  end

  defp render_info(input, request, config) do
    with {:ok, config} <- Processing.watermark_opts(config),
         {:ok, body, degraded?} <-
           Decode.with_image(input, request, config, &describe(&1, &2, request, config)),
         {:ok, body, blurhash_degraded?} <- put_blurhash(body, input, request, config) do
      {:ok, "application/json", body, degraded? or blurhash_degraded?}
    end
  end

  defp describe(state, geometry, request, config) do
    with {:ok, result, degraded?} <- result_facts(state, geometry, request, config) do
      {:ok, %{"source" => source_facts(state, geometry), "result" => result}, degraded?}
    end
  end

  defp source_facts(state, geometry) do
    orientation = exif_orientation(state.image)

    {width, height} =
      PendingOrientation.display_dims(
        geometry.storage_dimensions,
        PendingOrientation.from_exif(orientation, true)
      )

    %{
      "format" => Atom.to_string(geometry.source_format),
      "mime_type" => Format.mime_type!(geometry.source_format),
      "width" => width,
      "height" => height,
      "orientation" => orientation,
      "pages" => geometry.pages
    }
    |> put_size(Map.get(geometry.debug_facts, :source_bytes))
  end

  # Without operations or a placeholder drawn from this decode, the result is
  # the source in the request's orientation, known from the header alone.
  defp result_facts(state, geometry, request, config) do
    if header_only?(request) do
      {width, height} = geometry.display_dimensions

      {:ok, %{"width" => width, "height" => height, "dpr" => List.last(request.groups).dpr},
       false}
    else
      executed_facts(state, request, config)
    end
  end

  defp header_only?(%Spec{output: %{placeholders: placeholders}} = request),
    do: :lqip_css not in placeholders and Executor.operation_names(request) == []

  defp executed_facts(state, request, config) do
    with {:ok, state} <- Executor.execute(state, request, config) do
      result = %{
        "width" => Image.width(state.image),
        "height" => Image.height(state.image),
        "dpr" => state.dpr
      }

      with {:ok, result} <- put_lqip_css(result, state, request, config),
           do: {:ok, result, state.degraded?}
    end
  end

  defp put_lqip_css(result, state, %Spec{output: output} = request, config) do
    if :lqip_css in output.placeholders do
      with {:ok, value, _degraded?} <- placeholder(:lqip_css, state, request, config, :executed),
           do: {:ok, Map.put(result, "lqip_css", value)}
    else
      {:ok, result}
    end
  end

  # BlurHash decodes again with its own plan, so its decode hint applies and the
  # hash equals the standalone output for the same URL.
  defp put_blurhash(body, input, %Spec{output: output} = request, config) do
    if :blurhash in output.placeholders do
      with {:ok, hash, degraded?} <- standalone_blurhash(input, request, config),
           do: {:ok, put_in(body, ["result", "blurhash"], hash), degraded?}
    else
      {:ok, body, false}
    end
  end

  defp standalone_blurhash(input, %Spec{} = request, config) do
    request = %Spec{request | output: %Output{terminal: :blurhash}}

    Decode.with_image(input, request, config, fn state, _geometry ->
      placeholder(:blurhash, state, request, config)
    end)
  end

  defp placeholder(terminal, state, request, config) do
    with {:ok, state} <- Executor.execute(state, request, config),
         do: placeholder(terminal, state, request, config, :executed)
  end

  defp placeholder(terminal, state, _request, config, :executed) do
    with {:ok, state} <- Executor.reduce_terminal(state, %Output{terminal: terminal}, config),
         {:ok, value} <- compute(terminal, state.image),
         do: {:ok, value, state.degraded?}
  end

  defp compute(:blurhash, image) do
    case Blurhash.compute(image) do
      {:ok, hash} -> {:ok, hash}
      {:error, reason} -> {:error, {:transform, {:blurhash_encode, reason}}}
    end
  end

  defp compute(:lqip_css, image) do
    case LqipCss.compute(image) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:transform, {:lqip_css_encode, reason}}}
    end
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _absent_or_invalid -> 1
    end
  end

  defp put_size(body, nil), do: body
  defp put_size(body, size), do: Map.put(body, "size", size)

  defp terminal_result({:ok, _content_type, _body, _degraded?}), do: :ok
  defp terminal_result({:error, reason}), do: Telemetry.request_result({:error, reason})
end
