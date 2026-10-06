defmodule ImagePipe.API.WatermarkStorageWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Test.PlugFixture.CacheProbe

  @path "/wm=logo/format=png/src/https://origin.test/image.png"

  setup do
    store = :ets.new(:watermark_storage, [:public, :set])
    %{store: store}
  end

  for {label, control, options, vary} <- [
        {"origin no-store", "no-store", [], nil},
        {"origin private", "private, max-age=60", [], nil},
        {"storage denial", "public, max-age=60", [cache_policy: [storage: :deny]], nil},
        {"disabled internal caching", "public, max-age=60", [internal_cache: :disabled], nil},
        {"Vary star despite storage allowance", "public, max-age=60",
         [cache_policy: [storage: :allow]], "*"}
      ] do
    test "#{label} on a watermark prevents output storage and lookup", %{store: store} do
      config = config(store, unquote(control), unquote(options), unquote(vary))

      for _ <- 1..2 do
        assert_image(get(config))
        assert output_entries(store) == []
        assert output_lookups() == []
        assert output_writes() == []
      end
    end
  end

  for options <- [[cache_policy: [storage: :deny]], [internal_cache: :disabled]] do
    test "watermark #{inspect(options)} bypasses an existing output", %{store: store} do
      allowed = config(store, "public, max-age=60")
      first = get(allowed)
      assert_image(first)
      assert [_entry] = output_entries(store)
      output_lookups()
      assert [_key] = output_writes()

      response = get(config(store, "public, max-age=60", unquote(options)))

      assert_image(response)
      assert response.resp_body == first.resp_body
      assert output_lookups() == []
      assert output_writes() == []
      assert [_entry] = output_entries(store)
    end
  end

  for {control, options} <- [
        {"public, max-age=60", []},
        {"no-store", [cache_policy: [storage: :allow]]}
      ] do
    test "watermark #{inspect({control, options})} permits output reuse", %{store: store} do
      config = config(store, unquote(control), unquote(options))
      first = get(config)
      assert_image(first)
      assert [_entry] = output_entries(store)
      assert [key] = output_lookups()
      assert output_writes() == [key]

      second = get(config)

      assert second.resp_body == first.resp_body
      assert output_lookups() == [key]
      assert output_writes() == []
      assert [_entry] = output_entries(store)
    end
  end

  for options <- [[cache_policy: [storage: :deny]], [internal_cache: :disabled]] do
    test "immutable local watermark #{inspect(options)} prevents output storage", %{store: store} do
      root =
        Path.join(System.tmp_dir!(), "watermark-storage-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      File.write!(Path.join(root, "mark.png"), png(:red))
      on_exit(fn -> File.rm_rf!(root) end)

      config =
        IP.Plug.init(
          sources: [
            url: http_source("https", "public, max-age=60", [], nil),
            marks: [
              adapter: ImagePipe.Source.File,
              match: [prefix: "marks"],
              options: [root: root, root_id: root, stable: :immutable] ++ unquote(options)
            ]
          ],
          cache: {CacheProbe, store: store},
          clock: fn -> 1_000 end,
          watermarks: %{logo: [source: "marks/mark.png"]}
        )

      for _ <- 1..2 do
        assert_image(get(config))
        assert output_entries(store) == []
        assert output_lookups() == []
        assert output_writes() == []
      end
    end
  end

  defp config(store, mark_control, mark_options \\ [], vary \\ nil) do
    IP.Plug.init(
      sources: [
        url: http_source("https", "public, max-age=60", [cache_policy: [storage: :allow]], nil),
        marks: http_source("http", mark_control, mark_options, vary)
      ],
      cache: {CacheProbe, store: store},
      clock: fn -> 1_000 end,
      watermarks: %{logo: [source: "http://origin.test/mark.png"]}
    )
  end

  defp http_source(scheme, control, options, vary) do
    origin = fn conn ->
      color = if conn.request_path == "/mark.png", do: :red, else: :blue

      conn =
        conn
        |> put_resp_header("etag", ~s("#{conn.request_path}"))
        |> put_resp_header("cache-control", control)
        |> put_resp_header("date", "Thu, 01 Jan 1970 00:16:40 GMT")

      conn = if vary, do: put_resp_header(conn, "vary", vary), else: conn

      conn |> put_resp_content_type("image/png") |> send_resp(200, png(color))
    end

    [
      adapter: ImagePipe.Source.HTTP,
      match: [scheme: scheme],
      options:
        [
          allowed_hosts: ["origin.test"],
          address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
          req_options: [plug: origin]
        ] ++ options
    ]
  end

  defp get(config), do: conn(:get, @path) |> IP.Plug.call(config)

  defp assert_image(response) do
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/png"]
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {8, 8}
    assert {:ok, [255, 0, 0]} = Image.get_pixel(image, 4, 4)
  end

  defp output_entries(store) do
    for {_key, %{content_type: "image/png"} = entry} <- :ets.tab2list(store), do: entry
  end

  defp output_lookups do
    CacheProbe.lookup_keys() |> Enum.reject(&(&1.data == [])) |> Enum.uniq()
  end

  defp output_writes do
    receive do
      {:cache_put, key, _body} ->
        keys = output_writes()
        if key.data == [], do: keys, else: [key | keys]
    after
      0 -> []
    end
  end

  defp png(color), do: Image.new!(8, 8, color: color) |> Image.write!(:memory, suffix: ".png")
end
