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

  defp url_config(lookup_options, extra \\ []) do
    IP.URL.config(
      [preset_lookup: {PresetLookup, Keyword.put(lookup_options, :test_pid, self())}] ++ extra
    )
  end

  defp config(url_config, body, extra \\ []) do
    pid = self()

    origin = fn conn ->
      send(pid, :source_fetch)
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end

    IP.config(
      [
        url: url_config,
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
      ] ++ extra
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
    url_config = url_config(presets: %{"card" => "w=30/format=png"})
    config = config(url_config, body)
    builder = IP.URL.new(url_config, presets: ["card"])

    assert :ok = IP.URL.validate(builder)
    url = IP.URL.url!(builder, "photo.png")
    refute_received {:preset_fetch, _names}

    response = get(config, url)
    assert response.status == 200
    assert dimensions(response) == {30, 20}
    assert_received {:preset_fetch, ["default", "card"]}

    assert {:ok, result} = IP.run(config, builder, {:binary, body})
    assert result.data == response.resp_body
    assert_received {:preset_fetch, ["default", "card"]}
  end

  test "static presets shadow the lookup and static-only requests never call it", %{body: body} do
    url_config =
      url_config([presets: %{"card" => "w=10", "default" => "w=10"}],
        presets: %{"card" => "w=30/format=png", "default" => "format=png"}
      )

    config = config(url_config, body)

    response = get(config, "/preset=card/src/photo.png")
    assert response.status == 200
    assert dimensions(response) == {30, 20}

    [etag] = Plug.Conn.get_resp_header(response, "etag")
    conditional = get(config, "/preset=card/src/photo.png", [{"if-none-match", etag}])
    assert conditional.status == 304

    refute_received {:preset_fetch, _names}
  end

  test "nested references resolve in batches across looked-up and static presets",
       %{body: body} do
    url_config =
      url_config(
        [presets: %{"poster" => "preset=base,framed", "base" => "w=30"}],
        presets: %{"framed" => "pad=2/format=png"}
      )

    response = get(config(url_config, body), "/preset=poster/src/photo.png")
    assert response.status == 200
    assert dimensions(response) == {34, 24}
    assert_received {:preset_fetch, ["default", "poster"]}
    assert_received {:preset_fetch, ["base"]}
    refute_received {:preset_fetch, _names}
  end

  test "a static preset cannot reference a name only the lookup could define" do
    assert_raise ArgumentError, ~r/unknown preset: remote/, fn ->
      url_config([], presets: %{"card" => "preset=remote"})
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
      {[presets: %{"card" => "preset=missing"}], 500},
      {[presets: %{"card" => "preset=loop", "loop" => "preset=card"}], 500}
    ]

    for {lookup_options, status} <- cases do
      config = config(url_config(lookup_options), body, cache: {CacheProbe, []})
      response = get(config, "/preset=card/src/photo.png")
      assert response.status == status, inspect(lookup_options)
      refute_received :source_fetch
      refute_received :cache_lookup
    end
  end

  test "max_preset_lookups caps the distinct names one request may look up", %{body: body} do
    presets = %{"card" => "preset=base", "base" => "w=30/format=png"}

    assert get(
             config(url_config([presets: presets], max_preset_lookups: 2), body),
             "/preset=card/src/photo.png"
           ).status ==
             500

    assert get(
             config(url_config([presets: presets], max_preset_lookups: 3), body),
             "/preset=card/src/photo.png"
           ).status ==
             200
  end

  test "max_preset_lookups requires a lookup and a positive integer" do
    assert_raise ArgumentError, ~r/requires preset_lookup/, fn ->
      IP.URL.config(max_preset_lookups: 4)
    end

    for value <- [0, -1, "4"] do
      assert_raise ArgumentError, fn -> url_config([], max_preset_lookups: value) end
    end

    assert_raise ArgumentError, ~r/preset_lookup/, fn ->
      IP.URL.config(preset_lookup: PresetLookup)
    end
  end

  test "changing a looked-up definition changes the ETag", %{body: body} do
    etag = fn presets ->
      response = get(config(url_config(presets: presets), body), "/preset=card/src/photo.png")
      assert response.status == 200
      Plug.Conn.get_resp_header(response, "etag")
    end

    assert [_] = narrow = etag.(%{"card" => "w=30/format=png"})
    refute etag.(%{"card" => "w=20/format=png"}) == narrow
    assert etag.(%{"card" => "w=30/format=png"}) == narrow
  end

  test "the builder defers names the static map does not define to the mount" do
    with_lookup = url_config([], presets: %{"card" => "w=30", "pipeline" => "w=30/-/gray"})
    without = IP.URL.config(presets: %{"card" => "w=30"})

    assert :ok = IP.URL.validate(IP.URL.new(with_lookup, presets: ["remote"]))
    assert {:error, [_ | _]} = IP.URL.validate(IP.URL.new(without, presets: ["remote"]))

    assert {:error, [_ | _]} =
             IP.URL.validate(
               IP.URL.new(with_lookup, presets: ["pipeline"])
               |> IP.URL.group(blur: 1)
             )

    refute_received {:preset_fetch, _names}
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
    config = config(url_config(presets: presets), body, telemetry_prefix: @prefix)
    assert get(config, "/preset=card/src/photo.png").status == 200

    assert_received {:span, @prefix ++ [:preset, :lookup, :start], %{names: ["default", "card"]}}

    assert_received {:span, @prefix ++ [:preset, :lookup, :stop],
                     %{result: :ok, fetched: 2, batches: 2}}

    config = config(url_config(fail: true), body, telemetry_prefix: @prefix)
    assert get(config, "/preset=card/src/photo.png").status == 503

    assert_received {:span, @prefix ++ [:preset, :lookup, :stop],
                     %{result: :error, reason: :lookup_unavailable}}
  end
end
