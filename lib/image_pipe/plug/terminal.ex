defmodule ImagePipe.Plug.Terminal do
  @moduledoc false

  alias ImagePipe.Decode
  alias ImagePipe.Format
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Output.Terminal.LqipCss
  alias ImagePipe.Plan.Request
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias Vix.Vips.Image, as: VipsImage

  @spec render(Source.Resolved.t(), Request.t(), keyword()) ::
          {:ok, String.t(), iodata()} | {:error, term()}
  def render(source, %Request{} = request, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:output, :terminal],
      %{terminal: request.output.terminal},
      fn ->
        result =
          Decode.with_image(source, request, config, fn state, geometry ->
            render_body(state, geometry, request, config)
          end)

        {result, %{result: terminal_result(result)}}
      end
    )
  end

  defp render_body(state, _geometry, %Request{output: %{terminal: :blurhash}} = request, config) do
    with {:ok, state} <- Executor.execute(state, request, config),
         {:ok, state} <- Executor.reduce_terminal(state, request.output, config) do
      case Blurhash.compute(state.image) do
        {:ok, hash} -> {:ok, "text/plain", hash}
        {:error, reason} -> {:error, {:transform, {:blurhash_encode, reason}}}
      end
    end
  end

  defp render_body(state, geometry, %Request{output: %{terminal: :info}}, _config) do
    orientation = exif_orientation(state.image)

    {width, height} =
      PendingOrientation.display_dims(
        geometry.storage_dimensions,
        PendingOrientation.from_exif(orientation, true)
      )

    body =
      %{
        "format" => Atom.to_string(geometry.source_format),
        "mime_type" => Format.mime_type!(geometry.source_format),
        "width" => width,
        "height" => height,
        "orientation" => orientation
      }
      |> put_size(Map.get(geometry.debug_facts, :source_bytes))
      |> JSON.encode_to_iodata!()

    {:ok, "application/json", body}
  end

  defp render_body(state, _geometry, %Request{output: %{terminal: :lqip_css}} = request, config) do
    with {:ok, state} <- Executor.execute(state, request, config),
         {:ok, state} <- Executor.reduce_terminal(state, request.output, config) do
      case LqipCss.compute(state.image) do
        {:ok, value} -> {:ok, "text/plain", value}
        {:error, reason} -> {:error, {:transform, {:lqip_css_encode, reason}}}
      end
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

  defp terminal_result({:ok, _content_type, _body}), do: :ok
  defp terminal_result({:error, reason}), do: Telemetry.request_result({:error, reason})
end
