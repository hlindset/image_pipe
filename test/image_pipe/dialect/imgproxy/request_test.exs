defmodule ImagePipe.Dialect.Imgproxy.RequestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Parser.Imgproxy.ParsedRequest

  # The phase-1 dialect copy of ParsedRequest must carry the framework
  # original's fields, defaults, and helper-constructor shapes exactly: Tasks
  # 12, 15, and 17 build on this struct, and any drift silently changes
  # dialect behavior against the frozen framework arm the dual-run suite
  # compares it to.

  test "Request copy carries identical fields and defaults" do
    attrs = [signature: "unsafe", source_kind: :plain, source_path: "images/x.jpg", pipelines: []]

    original = Map.from_struct(struct!(ParsedRequest, attrs))
    copy = Map.from_struct(struct!(Request, attrs))

    assert Map.keys(original) == Map.keys(copy)
    assert original == copy
  end

  test "output_request/1 default and override shapes match the framework original" do
    assert ParsedRequest.output_request() == Request.output_request()

    assert ParsedRequest.output_request(format: :webp, quality: 80) ==
             Request.output_request(format: :webp, quality: 80)
  end

  test "policy_request/1 default and override shapes match the framework original" do
    assert ParsedRequest.policy_request() == Request.policy_request()

    assert ParsedRequest.policy_request(expires: 60) == Request.policy_request(expires: 60)
  end

  test "cache_request/1 default and override shapes match the framework original" do
    assert ParsedRequest.cache_request() == Request.cache_request()

    assert ParsedRequest.cache_request(cachebuster: "v1") ==
             Request.cache_request(cachebuster: "v1")
  end

  test "response_request/1 default and override shapes match the framework original" do
    assert ParsedRequest.response_request() == Request.response_request()

    assert ParsedRequest.response_request(filename: "cat.jpg") ==
             Request.response_request(filename: "cat.jpg")
  end

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
