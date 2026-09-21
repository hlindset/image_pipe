defmodule ImagePipe.API.SourceWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.S3
  alias ImagePipe.SourceTest.CredentialProvider
  alias ImagePipe.SourceTest.FoobarTranslator
  alias ImagePipe.SourceTest.PlugCustomAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe

  @image File.read!("priv/static/images/beach.jpg")

  test "HTTP source decodes the inner path once and preserves its query" do
    pid = self()

    origin = fn conn ->
      send(pid, {:origin_request, conn.request_path, conn.query_string})
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          https:
            {HTTP,
             allowed_hosts: ["assets.example.com"],
             address_resolver: public_resolver(),
             req_options: [plug: origin]}
        ]
      )

    source = "https://assets.example.com/images//my%20photo.jpg?token=a%26b%3Dc"
    response = request("format=jpeg", source, config)

    assert response.status == 200
    assert_receive {:origin_request, "/images//my%20photo.jpg", "token=a%26b%3Dc"}
  end

  test "S3 objects route through the core adapter with revision semantics" do
    pid = self()

    origin = fn conn ->
      send(pid, {:s3_request, conn.request_path, conn.query_string})
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          s3:
            {S3,
             default: [
               endpoint: "https://objects.example.com",
               region: "eu-west-1",
               credentials: {:static, access_key_id: "A", secret_access_key: "S"},
               req_options: [plug: origin]
             ]}
        ]
      )

    response = request("format=jpeg", "s3://bucket/images/my%20photo.jpg?v1", config)

    assert response.status == 200
    assert_receive {:s3_request, "/bucket/images/my%20photo.jpg", "versionId=v1"}
  end

  test "a configured custom scheme reaches its translator and source adapter" do
    config =
      mount(
        source_schemes: %{"foobar" => {FoobarTranslator, []}},
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}]
      )

    source = "foobar://asset/cat%20one.jpg"
    response = request("w=40/format=jpeg", source, config)

    assert response.status == 200
    assert_receive {:foobar_translate, ^source}
    assert_receive {:custom_resolve, _source}
    assert_receive {:custom_fetch, :cat}
  end

  test "a custom scheme keeps stable storage identity across real cache reuse" do
    store = :ets.new(:api_custom_source_cache, [:set, :public])

    config =
      mount(
        source_schemes: %{"foobar" => {FoobarTranslator, []}},
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar, stable: true}],
        cache: {CacheProbe, store: store}
      )

    source = "foobar://asset/cat%20one.jpg"
    first = request("w=40/format=jpeg", source, config)

    assert first.status == 200
    assert_receive {:foobar_translate, ^source}
    assert_receive {:custom_resolve, _source}
    assert_receive {:cache_lookup, _source_key}
    assert_receive {:custom_fetch, :cat}
    assert_receive {:cache_put, _key, _body}

    second = request("w=40/format=jpeg", source, config)

    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert_receive {:foobar_translate, ^source}
    assert_receive {:custom_resolve, _source}
    assert_receive {:cache_lookup, _key}
    refute_receive {:custom_fetch, _fetch}
  end

  test "an S3 cache hit does not fetch credentials or object bytes" do
    store = :ets.new(:api_s3_source_cache, [:set, :public])
    owner = self()

    origin = fn conn ->
      send(owner, :object_fetch)

      conn
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          s3:
            {S3,
             default: [
               endpoint: "https://objects.example.com",
               region: "eu-west-1",
               credentials: {:provider, CredentialProvider, report_to: self()},
               req_options: [plug: origin]
             ]}
        ],
        cache: {CacheProbe, store: store}
      )

    response = request("format=jpeg", "s3://bucket/images/cat.jpg?v1", config)

    assert response.status == 200
    assert_receive {:fetch_credentials, _, _, _}
    assert_receive :object_fetch
    second = request("format=jpeg", "s3://bucket/images/cat.jpg?v1", config)
    assert second.status == 200
    assert second.resp_body == response.resp_body
    assert_receive {:cache_lookup, _key}
    refute_receive {:fetch_credentials, _, _, _}
    refute_receive :object_fetch
  end

  test "malformed URL sources reject before source resolution or cache access" do
    config =
      mount(
        sources: [
          https:
            {HTTP,
             allowed_hosts: ["assets.example.com"],
             address_resolver: public_resolver(),
             req_options: [plug: fn _conn -> flunk("invalid URL fetched its source") end]}
        ],
        cache: {CacheProbe, []}
      )

    for source <- [
          "https://assets.example.com:0/cat.jpg",
          "https://assets.example.com:65536/cat.jpg",
          "https://assets.example.com:abc/cat.jpg",
          "https://user@assets.example.com/cat.jpg",
          "https://assets.example.com/cat.jpg#fragment"
        ] do
      assert request("format=jpeg", source, config).status == 400, source
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  defp request(options, source, config) do
    conn(:get, "/#{options}/src/#{percent_encode_source(source)}")
    |> ImagePipe.Plug.call(config)
  end

  defp percent_encode_source(source) do
    source
    |> :binary.bin_to_list()
    |> Enum.map_join(&encode_source_byte/1)
  end

  defp encode_source_byte(byte)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9,
       do: <<byte>>

  defp encode_source_byte(byte) when byte in [?-, ?., ?_, ?~, ?/], do: <<byte>>

  defp encode_source_byte(byte) do
    "%" <> (byte |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
  end

  defp public_resolver, do: fn "assets.example.com" -> {:ok, [{93, 184, 216, 34}]} end

  defp mount(overrides) do
    [max_body_bytes: 10_000_000, max_input_pixels: 40_000_000]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end
end
