defmodule ImagePipe.API.SourceWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.S3
  alias ImagePipe.SourceTest.CredentialProvider
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
          https: [
            adapter: HTTP,
            match: [scheme: "https"],
            options: [
              allowed_hosts: ["assets.example.com"],
              address_resolver: public_resolver(),
              req_options: [plug: origin]
            ]
          ]
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

      conn
      |> put_resp_header("x-amz-version-id", "v1")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          s3: [
            adapter: S3,
            match: [scheme: "s3"],
            options: [
              default: [
                endpoint: "https://objects.example.com",
                region: "eu-west-1",
                credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                req_options: [plug: origin]
              ]
            ]
          ]
        ]
      )

    response = request("format=jpeg", "s3://bucket/images/my%20photo.jpg?v1", config)

    assert response.status == 200
    assert_receive {:s3_request, "/bucket/images/my%20photo.jpg", "versionId=v1"}
  end

  test "an S3 cache hit does not fetch credentials or object bytes" do
    store = :ets.new(:api_s3_source_cache, [:set, :public])
    owner = self()

    origin = fn conn ->
      send(owner, :object_fetch)

      conn
      |> put_resp_header("x-amz-version-id", "v1")
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          s3: [
            adapter: S3,
            match: [scheme: "s3"],
            options: [
              default: [
                endpoint: "https://objects.example.com",
                region: "eu-west-1",
                credentials: {:provider, CredentialProvider, report_to: self()},
                req_options: [plug: origin]
              ]
            ]
          ]
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

  defmodule RotatingProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def validate_options(_opts), do: :ok

    # Hands out the next token on every fetch, as a temporary-credential
    # provider does after each rotation.
    @impl true
    def fetch_credentials(_scope, opts, _runtime_opts) do
      token =
        Agent.get_and_update(Keyword.fetch!(opts, :tokens), fn [next | rest] -> {next, rest} end)

      send(Keyword.fetch!(opts, :report_to), {:credentials_token, token})
      {:ok, [access_key_id: "AKIA_TEST", secret_access_key: "SECRET_TEST", token: token], :never}
    end
  end

  # Stops the cached provider results, so the next request fetches new
  # credentials.
  defp rotate_credentials do
    supervisor = ImagePipe.Source.S3.RefreshCache.DynamicSupervisor

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor) do
      ref = Process.monitor(pid)
      :ok = DynamicSupervisor.terminate_child(supervisor, pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    end
  end

  test "rotated S3 credentials keep cached results and the ETag" do
    store = :ets.new(:api_s3_rotation_cache, [:set, :public])
    tokens = start_supervised!({Agent, fn -> ["TOKEN_1", "TOKEN_2"] end})
    owner = self()

    origin = fn conn ->
      send(owner, :object_fetch)

      conn
      |> put_resp_header("x-amz-version-id", "v1")
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, @image)
    end

    config =
      mount(
        sources: [
          s3: [
            adapter: S3,
            match: [scheme: "s3"],
            options: [
              default: [
                endpoint: "https://objects.example.com",
                region: "eu-west-1",
                credentials: {:provider, RotatingProvider, tokens: tokens, report_to: owner},
                req_options: [plug: origin]
              ]
            ]
          ]
        ],
        cache: {CacheProbe, store: store}
      )

    first = request("format=jpeg", "s3://bucket/images/cat.jpg?v1", config)
    assert first.status == 200
    assert_receive {:credentials_token, "TOKEN_1"}
    assert_receive :object_fetch

    rotate_credentials()
    second = request("format=jpeg", "s3://bucket/images/cat.jpg?v1", config)
    assert second.status == 200
    assert_receive {:credentials_token, "TOKEN_2"}
    refute_receive :object_fetch
    assert get_resp_header(second, "etag") == get_resp_header(first, "etag")
    assert second.resp_body == first.resp_body
  end

  test "S3 mounts with different configured credentials keep separate cached results" do
    store = :ets.new(:api_s3_partition_cache, [:set, :public])
    owner = self()

    origin = fn conn ->
      send(owner, :object_fetch)

      conn
      |> put_resp_header("x-amz-version-id", "v1")
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, @image)
    end

    configs =
      for key_id <- ["AKIA_ONE", "AKIA_TWO"] do
        mount(
          sources: [
            s3: [
              adapter: S3,
              match: [scheme: "s3"],
              options: [
                default: [
                  endpoint: "https://objects.example.com",
                  region: "eu-west-1",
                  credentials: {:static, access_key_id: key_id, secret_access_key: "S"},
                  req_options: [plug: origin]
                ]
              ]
            ]
          ],
          cache: {CacheProbe, store: store}
        )
      end

    for config <- configs do
      assert request("format=jpeg", "s3://bucket/images/cat.jpg?v1", config).status == 200
      assert_receive :object_fetch
    end
  end

  test "malformed URL sources reject before source resolution or cache access" do
    config =
      mount(
        sources: [
          https: [
            adapter: HTTP,
            match: [scheme: "https"],
            options: [
              allowed_hosts: ["assets.example.com"],
              address_resolver: public_resolver(),
              req_options: [plug: fn _conn -> flunk("invalid URL fetched its source") end]
            ]
          ]
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
