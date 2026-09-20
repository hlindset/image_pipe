defmodule ImagePipe.API.SourceEncryptionWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.API
  alias ImagePipe.Security.Signature
  alias ImagePipe.Security.SourceEncryption.{CBC, HKDF}
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe

  @signing_key String.duplicate("a1", 32)
  @encryption_key :binary.copy(<<42, 73>>, 16)
  @old_key :binary.copy(<<19>>, 32)
  @source "private-customer-image.jpg"
  @prefix [:api_source_encryption_wire]

  test "plain, base64, and fresh concealed sources share bytes, cache, and ETag" do
    config = mount()
    plain = request("/w=12/format=png/src/#{@source}", config)
    assert plain.status == 200
    assert_received :origin_fetch
    assert_received {:cache_lookup, plain_key}
    assert_received {:cache_put, _key, _entry}
    assert [etag] = get_resp_header(plain, "etag")

    tokens =
      for options <- [[], [iv: :random], [iv: :random], [iv: <<7::128>>]] do
        assert {:ok, token} = API.encrypt_source(@source, config, options)
        token
      end

    assert length(Enum.uniq(tokens)) == 4

    tails =
      ["src64/" <> Base.url_encode64(@source, padding: false)] ++
        Enum.map(tokens, &("enc/" <> &1))

    for tail <- tails do
      response = request("/format=png/w=12/#{tail}", config)
      assert response.status == 200
      assert response.resp_body == plain.resp_body
      assert get_resp_header(response, "etag") == [etag]
      assert_received {:cache_lookup, key}
      assert key.hash == plain_key.hash
      refute_received :origin_fetch
      refute_received {:cache_put, _key, _entry}
    end

    conditional =
      conn(:get, signed("/w=12/format=png/enc/#{hd(tokens)}", config))
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(config)

    assert conditional.status == 304
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
  end

  test "rotation accepts earlier encryption keys and first-key tokens" do
    old_config = mount(source_encryption_keys: [@old_key])
    rotated = mount(source_encryption_keys: [@encryption_key, @old_key])
    token = encrypt_source(@source, old_config)
    assert request("/format=png/enc/#{token}", rotated).status == 200

    current_token = encrypt_source(@source, rotated)
    assert request("/format=png/enc/#{current_token}", mount()).status == 200
    assert request("/format=png/enc/#{current_token}", old_config).status == 404
  end

  test "all malformed or unauthenticated tokens fail before source and cache access" do
    config = mount()
    token = encrypt_source(@source, config)
    <<version, payload::binary>> = Base.url_decode64!(token, padding: false)

    invalid = [
      "",
      "not*a*token",
      token <> "=",
      token <> "/extra",
      Base.url_encode64(<<version>>, padding: false),
      Base.url_encode64(<<2, payload::binary>>, padding: false),
      Base.url_encode64(<<version, 0::96, 0::128>>, padding: false),
      encrypt_source(@source, mount(source_encryption_keys: [@old_key])),
      invalid_utf8_token()
    ]

    for value <- invalid do
      response = request("/format=png/enc/#{value}", config)
      assert response.status == 404, value
      assert response.resp_body == "not found"
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _entry}
    end

    disabled = mount(source_encryption_keys: [])
    assert request("/format=png/enc/#{token}", disabled).status == 404
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
  end

  test "signature verification precedes malformed token handling and binds options" do
    config = mount()

    for path <- ["/format=png/enc/invalid*", "/format=png/enc/"] do
      response = conn(:get, "/sig=invalid#{path}") |> ImagePipe.Plug.call(config)
      assert response.status == 403
      assert response.resp_body == "invalid signature"
    end

    token = encrypt_source(@source, config)
    url = signed("/w=12/format=png/enc/#{token}", config)
    response = conn(:get, String.replace(url, "/w=12/", "/w=13/")) |> ImagePipe.Plug.call(config)
    assert response.status == 403
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
  end

  test "authenticated plaintext uses ordinary source validation" do
    config = mount()
    token = encrypt_source("unconfigured://private/asset", config)
    response = request("/format=png/enc/#{token}", config)
    assert response.status == 400
    assert response.resp_body == "invalid source"
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
  end

  test "diagnostics, debug headers, and telemetry do not reveal concealed source material" do
    config = mount(allow_debug_headers: true)
    token = encrypt_source(@source, config)
    pid = self()
    handler = {__MODULE__, make_ref()}

    events =
      for stage <- [
            [:request],
            [:parse],
            [:source, :resolve],
            [:source, :fetch],
            [:transform, :execute]
          ],
          phase <- [:start, :stop, :exception],
          do: @prefix ++ stage ++ [phase]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn _, _, meta, _ -> send(pid, {:telemetry, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    invalid_path = "/w=oops/enc/#{token}"
    invalid_signature = Signature.sign(invalid_path, config)
    invalid = request(invalid_path, config)
    assert invalid.status == 400
    valid = request("/w=12/format=png/debug/enc/#{token}", config)
    assert valid.status == 200

    unsigned_config = mount(keys: [], source_encryption_keys: [])

    unsigned =
      conn(:get, "/sig=unexpected/w=12/enc/#{token}") |> ImagePipe.Plug.call(unsigned_config)

    assert unsigned.status == 400

    misplaced =
      conn(:get, "/w=oops/sig=#{invalid_signature}/enc/#{token}")
      |> ImagePipe.Plug.call(unsigned_config)

    assert misplaced.status == 400

    metadata = collect_telemetry([])
    refute metadata == []

    observable =
      inspect(
        {invalid.resp_body, unsigned.resp_body, misplaced.resp_body, valid.resp_headers,
         metadata},
        limit: :infinity
      )

    for secret <- [@source, token, invalid_signature, @signing_key, @encryption_key] do
      refute String.contains?(observable, secret)
    end
  end

  defp collect_telemetry(acc) do
    receive do
      {:telemetry, metadata} -> collect_telemetry([metadata | acc])
    after
      0 -> acc
    end
  end

  defp invalid_utf8_token do
    aad = "image-pipe:source:v1"

    <<key::binary-size(64), _::binary>> =
      HKDF.derive(@encryption_key, aad, "A256CBC-HS512+IV", 96)

    {ciphertext, tag} =
      CBC.encrypt(<<255>>, key, <<0::128>>, aad)

    Base.url_encode64(<<1, 0::128, ciphertext::binary, tag::binary>>, padding: false)
  end

  defp request(path, config), do: conn(:get, signed(path, config)) |> ImagePipe.Plug.call(config)
  defp signed(path, config), do: "/sig=#{Signature.sign(path, config)}#{path}"

  defp encrypt_source(source, config) do
    assert {:ok, token} = API.encrypt_source(source, config)
    token
  end

  defp mount(overrides \\ []) do
    body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")
    pid = self()
    table = :ets.new(:api_source_encryption_cache, [:set, :public])

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end

    [
      keys: [@signing_key],
      source_encryption_keys: [@encryption_key],
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      cache: {CacheProbe, store: table},
      http_cache: [mode: :enabled],
      telemetry_prefix: @prefix
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end
end
