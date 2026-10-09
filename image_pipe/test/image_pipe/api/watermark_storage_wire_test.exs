defmodule ImagePipe.API.WatermarkStorageWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Test.CacheObserver

  @path "/wm=logo/format=png/debug/src/https://origin.test/image.png"

  setup do
    %{cache: CacheObserver.observe([])}
  end

  for {label, control, options, vary} <- [
        {"origin no-store", "no-store", [], nil},
        {"origin private", "private, max-age=60", [], nil},
        {"storage denial", "public, max-age=60", [cache_policy: [storage: :deny]], nil},
        {"disabled internal caching", "public, max-age=60", [internal_cache: :disabled], nil},
        {"Vary star despite storage allowance", "public, max-age=60",
         [cache_policy: [storage: :allow]], "*"}
      ] do
    test "#{label} on a watermark prevents output storage and lookup", %{cache: cache} do
      config = config(cache, unquote(control), unquote(options), unquote(vary))

      for _ <- 1..2 do
        response = get(config)
        assert_image(response)
        assert output_entries(cache) == []
        assert output_lookups() == []
        assert output_writes() == []
      end
    end
  end

  for options <- [[cache_policy: [storage: :deny]], [internal_cache: :disabled]] do
    test "watermark #{inspect(options)} bypasses an existing output", %{cache: cache} do
      allowed = config(cache, "public, max-age=60")
      first = get(allowed)
      assert_image(first)
      assert [_entry] = output_entries(cache)
      assert [hash] = output_lookups()
      assert output_writes() == [hash]

      response = get(config(cache, "public, max-age=60", unquote(options)))

      assert_image(response)
      assert response.resp_body == first.resp_body
      refute hash in CacheObserver.lookup_hashes()
      assert get_resp_header(response, "x-imagepipe-cache") == ["miss"]
      assert output_writes() == []
      assert [_entry] = output_entries(cache)
    end
  end

  for {control, options} <- [
        {"public, max-age=60", []},
        {"no-store", [cache_policy: [storage: :allow]]}
      ] do
    test "watermark #{inspect({control, options})} permits output reuse", %{cache: cache} do
      config = config(cache, unquote(control), unquote(options))
      first = get(config)
      assert_image(first)
      assert [_entry] = output_entries(cache)
      assert [hash] = output_lookups()
      assert output_writes() == [hash]

      second = get(config)

      assert second.resp_body == first.resp_body
      assert output_lookups() == [hash]
      assert output_writes() == []
      assert [_entry] = output_entries(cache)
    end
  end

  for options <- [[cache_policy: [storage: :deny]], [internal_cache: :disabled]] do
    test "immutable local watermark #{inspect(options)} prevents output storage", %{cache: cache} do
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
          cache: cache[:cache],
          telemetry_prefix: cache[:telemetry_prefix],
          allow_debug_headers: true,
          clock: fn -> 1_000 end,
          watermarks: %{logo: [source: "marks/mark.png"]}
        )

      for _ <- 1..2 do
        response = get(config)
        assert_image(response)
        assert output_entries(cache) == []
        assert output_lookups() == []
        assert output_writes() == []
      end
    end
  end

  defp config(cache, mark_control, mark_options \\ [], vary \\ nil) do
    IP.Plug.init(
      sources: [
        url: http_source("https", "public, max-age=60", [cache_policy: [storage: :allow]], nil),
        marks: http_source("http", mark_control, mark_options, vary)
      ],
      cache: cache[:cache],
      telemetry_prefix: cache[:telemetry_prefix],
      allow_debug_headers: true,
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

  # Source-index records share the output cache, so only PNG bodies are outputs.
  defp output_entries(cache) do
    root = cache |> Keyword.fetch!(:cache) |> Keyword.fetch!(:root)

    for meta <- Path.wildcard(Path.join(root, "**/*.meta")),
        body = CacheObserver.stored_body(cache, Path.basename(meta, ".meta")),
        png?(body),
        do: body
  end

  defp output_lookups, do: CacheObserver.lookup_hashes() |> Enum.uniq()

  defp output_writes do
    receive do
      {:cache_put, hash, body} ->
        hashes = output_writes()
        if png?(body), do: [hash | hashes], else: hashes
    after
      0 -> []
    end
  end

  defp png?(body), do: match?(<<137, "PNG", _rest::binary>>, body)

  defp png(color), do: Image.new!(8, 8, color: color) |> Image.write!(:memory, suffix: ".png")
end
