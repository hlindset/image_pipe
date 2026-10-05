defmodule ImagePipe.PresetLookupTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]

  alias ImagePipe, as: IP
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PresetLookup

  @prefix [:image_pipe_preset_lookup_test]

  setup do
    body = Image.new!(60, 40, color: [80, 120, 160]) |> Image.write!(:memory, suffix: ".png")
    %{body: body}
  end

  defp lookup(options), do: {PresetLookup, Keyword.put(options, :test_pid, self())}

  defp config(body, options) do
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    IP.config(
      [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              byte_identity: :strong,
              req_options: [plug: origin]
            ]
          ]
        ]
      ] ++ options
    )
  end

  defp get(config, path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, conn ->
      Plug.Conn.put_req_header(conn, k, v)
    end)
    |> IP.Plug.call(IP.Plug.init(config))
  end

  defp dimensions(response) do
    image = Image.from_binary!(response.resp_body)
    {Image.width(image), Image.height(image)}
  end

  test "a looked-up preset applies identically through Plug and direct execution", %{body: body} do
    config = config(body, preset_lookup: lookup(presets: %{"card" => "w=30/format=png"}))
    builder = IP.URL.new(IP.url_config(config)) |> IP.URL.group(presets: ["card"])

    assert :ok = IP.URL.validate(builder)
    url = IP.URL.url!(builder, "photo.png")
    refute_received {:preset_fetch, _names}

    response = get(config, url)
    assert response.status == 200
    assert dimensions(response) == {30, 20}
    assert_received {:preset_fetch, ["card"]}

    assert {:ok, result} = IP.run(config, builder, {:binary, body})
    assert result.data == response.resp_body
    assert_received {:preset_fetch, ["card"]}
  end

  test "static presets shadow the lookup and static-only requests never call it", %{body: body} do
    config =
      config(body,
        request_defaults: "format=png",
        presets: %{"card" => "w=30"},
        preset_lookup: lookup(presets: %{"card" => "w=10"})
      )

    response = get(config, "/preset=card/src/photo.png")
    assert response.status == 200
    assert dimensions(response) == {30, 20}

    [etag] = Plug.Conn.get_resp_header(response, "etag")
    conditional = get(config, "/preset=card/src/photo.png", [{"if-none-match", etag}])
    assert conditional.status == 304

    assert get(config, "/w=30/src/photo.png").status == 200
    refute_received {:preset_fetch, _names}
  end

  test "nested references resolve in batches across looked-up and static presets",
       %{body: body} do
    config =
      config(body,
        presets: %{"framed" => "pad=2/format=png"},
        preset_lookup: lookup(presets: %{"poster" => "preset=base,framed", "base" => "w=30"})
      )

    response = get(config, "/preset=poster/src/photo.png")
    assert response.status == 200
    assert dimensions(response) == {34, 24}
    assert_received {:preset_fetch, ["poster"]}
    assert_received {:preset_fetch, ["base"]}
    refute_received {:preset_fetch, _names}
  end

  test "a retired name returning an empty fragment serves the plain request", %{body: body} do
    config = config(body, preset_lookup: lookup(presets: %{"promo" => ""}))

    retired = get(config, "/preset=promo/w=30/format=png/src/photo.png")
    plain = get(config, "/w=30/format=png/src/photo.png")
    assert retired.status == 200
    assert retired.resp_body == plain.resp_body
    assert Plug.Conn.get_resp_header(retired, "etag") == Plug.Conn.get_resp_header(plain, "etag")
  end

  test "a static preset cannot reference a name only the lookup could define", %{body: body} do
    assert_raise ArgumentError, ~r/unknown preset: remote/, fn ->
      config(body, presets: %{"card" => "preset=remote"}, preset_lookup: lookup([]))
    end
  end

  test "lookup failures are rejected before source fetch or cache access", %{body: body} do
    cases = [
      {[presets: %{}], 400},
      {[fail: true], 503},
      {[raise: true], 503},
      {[reply: :nonsense], 503},
      {[reply: {:ok, %{"card" => 42}}], 503},
      {[presets: %{"card" => "w=nope"}], 500},
      {[presets: %{"card" => "w=400\n"}], 500},
      {[presets: %{"card" => "pad=1\n"}], 500},
      {[presets: %{"card" => "preset=missing"}], 500},
      {[presets: %{"card" => "preset=loop", "loop" => "preset=card"}], 500}
    ]

    for {lookup_options, status} <- cases do
      config = config(body, preset_lookup: lookup(lookup_options), cache: {CacheProbe, []})
      response = get(config, "/preset=card/src/photo.png")
      assert response.status == status, inspect(lookup_options)
      refute_received :source_fetch
      refute_received :cache_lookup
    end
  end

  test "max_preset_lookups caps the distinct names one request may look up", %{body: body} do
    lookup = lookup(presets: %{"card" => "preset=base", "base" => "w=30/format=png"})

    assert get(
             config(body, preset_lookup: lookup, max_preset_lookups: 1),
             "/preset=card/src/photo.png"
           ).status ==
             500

    assert get(
             config(body, preset_lookup: lookup, max_preset_lookups: 2),
             "/preset=card/src/photo.png"
           ).status ==
             200
  end

  test "a URL naming more presets than max_preset_lookups is a 400 before any lookup",
       %{body: body} do
    config =
      config(body,
        presets: %{"static" => "format=png"},
        preset_lookup: lookup(presets: %{"a" => "w=30", "b" => "blur=1"}),
        max_preset_lookups: 1,
        cache: {CacheProbe, []}
      )

    response = get(config, "/preset=a,b,static/src/photo.png")
    assert response.status == 400
    refute_received {:preset_fetch, _names}
    refute_received :source_fetch
    refute_received :cache_lookup

    assert IP.validate(config, IP.URL.new() |> IP.URL.group(presets: ["a", "b"])) ==
             {:error, {:preset, :too_many_presets}}

    assert get(config, "/preset=a,static/src/photo.png").status == 200
  end

  test "an option unset next to a missing looked-up preset is a 400", %{body: body} do
    config = config(body, preset_lookup: lookup(presets: %{}), cache: {CacheProbe, []})

    for path <- [
          "/extend=unset/preset=gone/src/photo.png",
          "/preset=gone/wm-tile=unset/src/photo.png"
        ] do
      assert get(config, path).status == 400, path
      refute_received :source_fetch
      refute_received :cache_lookup
    end
  end

  test "lookup options are validated at init", %{body: body} do
    assert_raise ArgumentError, ~r/requires preset_lookup/, fn ->
      config(body, max_preset_lookups: 4)
    end

    for value <- [0, -1, "4"] do
      assert_raise ArgumentError, fn ->
        config(body, preset_lookup: lookup([]), max_preset_lookups: value)
      end
    end

    assert_raise ArgumentError, ~r/preset_lookup/, fn ->
      config(body, preset_lookup: PresetLookup)
    end

    for module <- [MissingPresetLookup, String] do
      assert_raise ArgumentError, ~r/does not implement ImagePipe.PresetLookup/, fn ->
        config(body, preset_lookup: {module, []})
      end
    end

    assert_raise ArgumentError, ~r/options are invalid: :bad/, fn ->
      config(body, preset_lookup: lookup(validate_reply: {:error, :bad}))
    end

    assert_raise ArgumentError, ~r/must return/, fn ->
      config(body, preset_lookup: lookup(validate_reply: :nonsense))
    end
  end

  test "changing a looked-up definition changes the ETag", %{body: body} do
    etag = fn presets ->
      response =
        get(config(body, preset_lookup: lookup(presets: presets)), "/preset=card/src/photo.png")

      assert response.status == 200
      Plug.Conn.get_resp_header(response, "etag")
    end

    assert [_] = narrow = etag.(%{"card" => "w=30/format=png"})
    refute etag.(%{"card" => "w=20/format=png"}) == narrow
    assert etag.(%{"card" => "w=30/format=png"}) == narrow
  end

  test "the mount's URL config defers looked-up names and checks static ones", %{body: body} do
    with_lookup =
      config(body,
        presets: %{"card" => "w=30", "pipeline" => "w=30/-/gray"},
        preset_lookup: lookup([])
      )

    without = config(body, presets: %{"card" => "w=30"})

    assert :ok =
             IP.URL.validate(
               IP.URL.new(IP.url_config(with_lookup))
               |> IP.URL.group(presets: ["remote"])
             )

    assert {:error, [_ | _]} =
             IP.URL.validate(
               IP.URL.new(IP.url_config(without))
               |> IP.URL.group(presets: ["remote"])
             )

    assert {:error, [_ | _]} =
             IP.URL.validate(
               IP.URL.new(IP.url_config(with_lookup))
               |> IP.URL.group(presets: ["pipeline"], blur: 1)
             )

    refute_received {:preset_fetch, _names}
  end

  test "ImagePipe.validate/2 runs the lookup and matches the mount", %{body: body} do
    config =
      config(body,
        presets: %{"pipeline" => "w=30/-/gray"},
        preset_lookup: lookup(presets: %{"card" => "w=30"})
      )

    assert :ok = IP.validate(config, IP.URL.new() |> IP.URL.group(presets: ["card"]))
    assert_received {:preset_fetch, ["card"]}

    assert {:error, {:invalid_request, _issues}} =
             IP.validate(config, IP.URL.new() |> IP.URL.group(presets: ["nope"]))

    assert {:error, {:invalid_request, _issues}} =
             IP.validate(config, IP.URL.new() |> IP.URL.group(presets: ["pipeline"], blur: 1))

    failing = config(body, preset_lookup: lookup(fail: true))

    assert IP.validate(failing, IP.URL.new() |> IP.URL.group(presets: ["card"])) ==
             {:error, {:preset, :lookup_unavailable}}

    assert get(failing, "/preset=card/src/photo.png").status == 503
    refute_received :source_fetch
  end

  test "the lookup span reports names, counts, and failures", %{body: body} do
    handler = {__MODULE__, make_ref()}
    events = for suffix <- [:start, :stop], do: @prefix ++ [:preset, :lookup, suffix]

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, pid -> send(pid, {:span, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    presets = %{"card" => "preset=base", "base" => "w=30/format=png"}
    config = config(body, preset_lookup: lookup(presets: presets), telemetry_prefix: @prefix)
    assert get(config, "/preset=card/src/photo.png").status == 200

    assert_received {:span, @prefix ++ [:preset, :lookup, :start], %{names: ["card"]}}

    assert_received {:span, @prefix ++ [:preset, :lookup, :stop],
                     %{result: :ok, fetched: 2, batches: 2}}

    config = config(body, preset_lookup: lookup(fail: true), telemetry_prefix: @prefix)
    assert get(config, "/preset=card/src/photo.png").status == 503

    assert_received {:span, @prefix ++ [:preset, :lookup, :stop],
                     %{result: :error, reason: :lookup_unavailable}}
  end
end
