defmodule ImagePipe.Processing.Terminal do
  @moduledoc false

  alias ImagePipe.Decode
  alias ImagePipe.Format
  alias ImagePipe.Output.Clamp
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
  @spec render(Decode.input(), Spec.t(), keyword(), term()) ::
          {:ok, String.t(), binary() | map(), boolean()} | {:error, term()}
  def render(source, %Spec{} = request, config, watermark_inputs) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:output, :terminal],
      start_metadata(request.output),
      fn ->
        result =
          Processing.with_watermarks(
            watermark_inputs,
            &render_terminal(source, request, config, &1)
          )

        {result, %{result: terminal_result(result)}}
      end
    )
  end

  defp start_metadata(%Output{terminal: :info, placeholders: placeholders}),
    do: %{terminal: :info, placeholders: placeholders}

  defp start_metadata(%Output{terminal: terminal}), do: %{terminal: terminal}

  defp render_terminal(source, %Spec{output: %{terminal: :info}} = request, config, inputs) do
    Decode.with_seekable(source, config, &render_info(&1, request, config, inputs))
  end

  defp render_terminal(source, %Spec{output: %{terminal: terminal}} = request, config, inputs) do
    Decode.with_image(source, request, config, fn state, _geometry ->
      with {:ok, config} <- Processing.watermark_opts(config, inputs),
           {:ok, value, degraded?} <- placeholder(terminal, state, request, config) do
        {:ok, "text/plain", value, degraded?}
      end
    end)
  end

  defp render_info(input, request, config, inputs) do
    with {:ok, config} <- Processing.watermark_opts(config, inputs),
         {:ok, {body, reduced}, degraded?} <-
           Decode.with_image(input, request, config, &describe(&1, &2, request, config)),
         {:ok, body, reduced_degraded?} <- put_reduced(body, reduced, input, request, config) do
      {:ok, "application/json", body, degraded? or reduced_degraded?}
    end
  end

  # Returns the body and the placeholders still to compute from their own
  # smaller decode.
  defp describe(state, geometry, request, config) do
    lqip_css = lqip_css_source(request, geometry)

    with {:ok, result, degraded?} <- result_facts(state, geometry, request, config, lqip_css) do
      body = %{"source" => source_facts(state, geometry), "result" => result}
      {:ok, {body, reduced_placeholders(request, lqip_css)}, degraded?}
    end
  end

  # A standalone placeholder may decode smaller than the info request does. Its
  # value then comes from that decode, so it equals the standalone output;
  # otherwise the info decode gives the same pixels.
  defp lqip_css_source(%Spec{output: output} = request, geometry) do
    standalone = %Spec{request | output: %Output{terminal: :lqip_css}}

    cond do
      :lqip_css not in output.placeholders ->
        :none

      Executor.decode_options(standalone, geometry) == Executor.decode_options(request, geometry) ->
        :executed

      true ->
        :reduced
    end
  end

  defp reduced_placeholders(%Spec{output: output}, lqip_css) do
    for terminal <- [:blurhash, :lqip_css],
        terminal in output.placeholders,
        terminal == :blurhash or lqip_css == :reduced,
        do: terminal
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

  # Without operations, a placeholder drawn from this decode, or a binding
  # result limit, the result is the source in the request's orientation, known
  # from the header alone.
  defp result_facts(state, geometry, request, config, lqip_css) do
    header_only? =
      lqip_css != :executed and Executor.operation_names(request) == [] and
        not Clamp.binds?(geometry.display_dimensions, result_limits(request, config))

    if header_only? do
      {width, height} = geometry.display_dimensions

      {:ok, %{"width" => width, "height" => height, "dpr" => List.last(request.groups).dpr},
       false}
    else
      executed_facts(state, request, config, lqip_css)
    end
  end

  # The image path scales a result down to the result limits after executing,
  # lazily, so the clamped header has the dimensions it would deliver.
  defp executed_facts(state, request, config, lqip_css) do
    with {:ok, state} <- Executor.execute(state, request, config),
         {:ok, clamped, _info} <- Clamp.clamp(state.image, result_limits(request, config), config) do
      result = %{
        "width" => Image.width(clamped),
        "height" => Image.height(clamped),
        "dpr" => state.dpr
      }

      with {:ok, result} <- put_lqip_css(result, state, request, config, lqip_css),
           do: {:ok, result, state.degraded?}
    end
  end

  # Without an explicit format the delivered format depends on Accept, which
  # info doesn't negotiate, so only the server's limits apply.
  defp result_limits(%Spec{output: %Output{format: format}}, config),
    do: Processing.result_limits(format, config)

  defp put_lqip_css(result, state, request, config, :executed) do
    with {:ok, value, _degraded?} <- placeholder(:lqip_css, state, request, config, :executed),
         do: {:ok, Map.put(result, "lqip_css", value)}
  end

  defp put_lqip_css(result, _state, _request, _config, _source), do: {:ok, result}

  # BlurHash and LQIP CSS plan the same smaller decode, so one decode serves
  # both, and each equals its standalone output for the same URL.
  defp put_reduced(body, [], _input, _request, _config), do: {:ok, body, false}

  defp put_reduced(body, [terminal | _] = terminals, input, %Spec{} = request, config) do
    request = %Spec{request | output: %Output{terminal: terminal}}

    Decode.with_image(input, request, config, fn state, _geometry ->
      with {:ok, state} <- Executor.execute(state, request, config),
           {:ok, state} <- readable_for(state, terminals) do
        put_placeholders(body, terminals, state, request, config)
      end
    end)
  end

  defp put_placeholders(body, terminals, state, request, config) do
    Enum.reduce_while(terminals, {:ok, body, false}, fn terminal, {:ok, body, degraded?} ->
      case placeholder(terminal, state, request, config, :executed) do
        {:ok, value, placeholder_degraded?} ->
          body = put_in(body, ["result", key(terminal)], value)
          {:cont, {:ok, body, degraded? or placeholder_degraded?}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # The decode streams, so a frame read by more than one placeholder is
  # buffered first.
  defp readable_for(state, [_terminal]), do: {:ok, state}
  defp readable_for(state, _terminals), do: Executor.materialize(state)

  defp key(:blurhash), do: "blurhash"
  defp key(:lqip_css), do: "lqip_css"

  defp placeholder(terminal, state, request, config) do
    with {:ok, state} <- Executor.execute(state, request, config),
         do: placeholder(terminal, state, request, config, :executed)
  end

  defp placeholder(terminal, state, _request, config, :executed) do
    with {:ok, state} <- Executor.reduce_terminal(state, %Output{terminal: terminal}, config),
         :ok <- Executor.check_evaluation(state),
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
