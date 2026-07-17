defmodule ImagePipe.Dialect.Imgproxy.RequestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Dialect.Imgproxy.Request

  test "the canonical request is pure data (no pid/ref/function leaves)" do
    request = %Request{
      signature: "unsafe",
      source_kind: :plain,
      source_path: "images/x.jpg",
      pipelines: [%PipelineRequest{}]
    }

    assert pure_data?(request)
  end

  defp pure_data?(%_{} = struct), do: struct |> Map.from_struct() |> pure_data?()
  defp pure_data?(%{} = map), do: map |> Map.to_list() |> pure_data?()
  defp pure_data?(list) when is_list(list), do: Enum.all?(list, &pure_data?/1)
  defp pure_data?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> pure_data?()

  defp pure_data?(term),
    do: not (is_pid(term) or is_reference(term) or is_function(term) or is_port(term))
end
