defmodule ImagePipe.ClientPresetsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches

  @key Base.encode16(:binary.copy(<<71>>, 32))
  @presets %{
    "poster" => "w=30/h=30/fit=stretch/format=png",
    "internal" => "w=10/format=png",
    "lookup-shadow" => "w=20/format=png"
  }

  setup do
    body = Image.new!(60, 40, color: [80, 120, 160]) |> Image.write!(:memory, suffix: ".png")
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end

    sources = [
      path: [
        adapter: RootHTTPAdapter,
        match: :path,
        options: [root_url: "http://origin.test", req_options: [plug: origin]]
      ]
    ]

    url_config = IP.URL.config(keys: [@key])
    mount = Caches.plug(CacheObserver.observe(options(sources)))
    %{sources: sources, url_config: url_config, mount: mount}
  end

  defp options(sources) do
    [keys: [@key], presets: @presets, client_presets: ["poster"], sources: sources]
  end

  defp get(path, mount), do: conn(:get, path) |> IP.Plug.call(mount)

  defp size(response) do
    output = Image.from_binary!(response.resp_body)
    {Image.width(output), Image.height(output)}
  end

  test "an allowlisted preset written before the signature applies to the signed path", %{
    url_config: url_config,
    mount: mount
  } do
    signed = IP.URL.sign_path("/src/photo.png", url_config)

    response = get("/preset=poster" <> signed, mount)
    assert response.status == 200
    assert size(response) == {30, 30}
    assert_received {:cache_lookup, _entry, prefixed_key}

    # The signer writing the same preset produces the same plan and cache key.
    response = get(IP.URL.sign_path("/preset=poster/src/photo.png", url_config), mount)
    assert response.status == 200
    assert_received {:cache_lookup, _entry, ^prefixed_key}

    # Without the prefix, the signed URL still serves the source.
    assert size(get(signed, mount)) == {60, 40}
  end

  test "options the signer wrote override the client preset", %{
    url_config: url_config,
    mount: mount
  } do
    response = get("/preset=poster" <> IP.URL.sign_path("/h=20/src/photo.png", url_config), mount)

    assert response.status == 200
    assert size(response) == {30, 20}
  end

  test "an allowlisted preset may be named twice", %{url_config: url_config, mount: mount} do
    response =
      get("/preset=poster,poster" <> IP.URL.sign_path("/src/photo.png", url_config), mount)

    assert response.status == 200
    assert size(response) == {30, 30}
  end

  test "a client preset joins the signer's presets, which win", %{
    url_config: url_config,
    mount: mount
  } do
    response =
      get(
        "/preset=poster" <> IP.URL.sign_path("/preset=internal/src/photo.png", url_config),
        mount
      )

    assert response.status == 200
    assert size(response) == {10, 30}
    assert_received {:cache_lookup, _entry, key}

    # The same plan and cache key as the signer writing both names.
    signer = get(IP.URL.sign_path("/preset=poster,internal/src/photo.png", url_config), mount)
    assert size(signer) == {10, 30}
    assert_received {:cache_lookup, _entry, ^key}
  end

  test "the client preset doesn't count toward the option segment limit", %{
    url_config: url_config,
    mount: mount
  } do
    options = Enum.map_join(1..64, "/", fn _i -> "pad=1" end)
    # Repeated pad options give a 400 for duplicates, so only the lexer's
    # segment limit is under test here.
    signed = IP.URL.sign_path("/" <> options <> "/src/photo.png", url_config)

    response = get("/preset=poster" <> signed, mount)
    assert response.status == 400
    refute response.resp_body =~ "too many option segments"
  end

  test "a signer-written leading preset still verifies", %{url_config: url_config, mount: mount} do
    response = get(IP.URL.sign_path("/preset=internal/src/photo.png", url_config), mount)

    assert response.status == 200
    assert size(response) == {10, 7}
  end

  test "presets outside the allowlist fail before source or cache access", %{
    url_config: url_config,
    mount: mount
  } do
    signed = IP.URL.sign_path("/src/photo.png", url_config)

    for prefix <- ["/preset=internal", "/preset=poster,internal", "/preset=unknown", "/preset="] do
      response = get(prefix <> signed, mount)
      assert response.status == 403
      assert response.resp_body == "invalid signature"
    end

    refute_received :source_fetch
    refute_received {:cache_lookup, _, _}
  end

  test "an unsigned preset never reaches the preset lookup", %{
    sources: sources,
    url_config: url_config
  } do
    defmodule Lookup do
      @behaviour ImagePipe.PresetLookup

      @impl true
      def validate_options(options), do: {:ok, options}

      @impl true
      def fetch(names, options) do
        send(Keyword.fetch!(options, :test), {:lookup, names})
        {:ok, Map.new(names, &{&1, "w=5"})}
      end
    end

    mount =
      IP.Plug.init(IP.config(options(sources) ++ [preset_lookup: {Lookup, test: self()}]))

    response = get("/preset=looked-up" <> IP.URL.sign_path("/src/photo.png", url_config), mount)

    assert response.status == 403
    refute_received {:lookup, _}
  end

  test "a second segment before the signature isn't a client prefix", %{
    url_config: url_config,
    mount: mount
  } do
    signed = IP.URL.sign_path("/src/photo.png", url_config)

    assert get("/preset=poster/preset=poster" <> signed, mount).status == 403
    assert get("/w=30" <> signed, mount).status == 403
    refute_received :source_fetch
  end

  describe "configuration" do
    test "names outside the static presets raise", %{sources: sources} do
      assert_raise ArgumentError, ~r/client_presets.*"missing"/, fn ->
        IP.config(Keyword.put(options(sources), :client_presets, ["poster", "missing"]))
      end
    end

    test "pipeline presets can't be client presets", %{sources: sources} do
      presets = Map.put(@presets, "pipe", "w=20/-/blur=1")

      assert_raise ArgumentError, ~r/client_presets.*"pipe".*pipeline/, fn ->
        IP.config(
          Keyword.merge(options(sources), presets: presets, client_presets: ["poster", "pipe"])
        )
      end
    end

    test "client presets need signing keys", %{sources: sources} do
      assert_raise ArgumentError, ~r/client_presets.*:keys/, fn ->
        IP.config(
          presets: @presets,
          client_presets: ["poster"],
          allow_unsigned: true,
          sources: sources
        )
      end
    end
  end
end
