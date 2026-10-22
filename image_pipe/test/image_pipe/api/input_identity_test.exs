defmodule ImagePipe.API.InputIdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.MaterialDigest
  alias ImagePipe.Plug.Request, as: ParsedRequest
  alias ImagePipe.Processing
  alias ImagePipe.Representation

  @fetch_digest MaterialDigest.of([])

  defp identity(path, headers \\ []) do
    config = ImagePipe.Plug.init(allow_unsigned: true, vary_on: [{:header, "x-tenant"}])

    conn =
      Enum.reduce(headers, Plug.Test.conn(:get, path), fn {key, value}, conn ->
        Plug.Conn.put_req_header(conn, key, value)
      end)

    {{:ok, request, _source}, _metadata} = ParsedRequest.parse(conn, config)
    {:ok, policy} = Processing.prepare(request, config, "image/webp")
    conn = Plug.Conn.fetch_cookies(conn)
    inputs = %ImagePipe.Execution.Inputs{headers: conn.req_headers, cookies: conn.req_cookies}
    ImagePipe.Execution.identity_material(request, policy, inputs, config)
  end

  test "output operations and content negotiation do not fragment the input key" do
    a = identity("/w=20/format=jpeg/src/cat.jpg")
    b = identity("/w=200/format=webp/src/cat.jpg")

    assert Representation.input_key([source: "cat"], a, @fetch_digest) ==
             Representation.input_key([source: "cat"], b, @fetch_digest)

    refute Representation.build([source: "cat"], a, {:strong, "bytes"}).cache_key ==
             Representation.build([source: "cat"], b, {:strong, "bytes"}).cache_key
  end

  test "fetch context partitions input storage without retaining credentials in key data" do
    material = identity("/src/cat.jpg")

    a =
      Representation.input_key(
        [source: "cat"],
        material,
        MaterialDigest.of(headers: [{"authorization", "secret-a"}])
      )

    b =
      Representation.input_key(
        [source: "cat"],
        material,
        MaterialDigest.of(headers: [{"authorization", "secret-b"}])
      )

    refute a.hash == b.hash
    refute inspect(a.data) =~ "secret-a"
  end

  test "cachebusters bypass both pools while preserving byte validators" do
    a = identity("/cb=one/src/cat.jpg")
    b = identity("/cb=two/src/cat.jpg")

    refute Representation.input_key([source: "cat"], a, @fetch_digest).hash ==
             Representation.input_key([source: "cat"], b, @fetch_digest).hash

    output_a = Representation.build([source: "cat"], a, {:strong, "bytes"})
    output_b = Representation.build([source: "cat"], b, {:strong, "bytes"})
    refute output_a.cache_key == output_b.cache_key
    assert output_a.etag == output_b.etag
  end

  property "vary_on values select processed copies but share one original, keeping the ETag" do
    check all tenant <- string(:alphanumeric, min_length: 1) do
      a = identity("/src/cat.jpg", [{"x-tenant", tenant}])
      b = identity("/src/cat.jpg", [{"x-tenant", tenant <> "x"}])

      assert Representation.input_key([source: "cat"], a, @fetch_digest).hash ==
               Representation.input_key([source: "cat"], b, @fetch_digest).hash

      output_a = Representation.build([source: "cat"], a, {:strong, "bytes"})
      output_b = Representation.build([source: "cat"], b, {:strong, "bytes"})
      refute output_a.cache_key == output_b.cache_key
      assert output_a.etag == output_b.etag
    end
  end
end
