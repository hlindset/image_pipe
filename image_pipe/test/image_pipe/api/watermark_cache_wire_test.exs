defmodule ImagePipe.API.WatermarkCacheWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Test.Caches

  @path "/wm=logo/format=png/src/https://origin.test/image.png"

  setup context do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-watermark-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    bodies = %{
      {"image.png", 1} => png(:blue),
      {"mark.png", 1} => png(:red),
      {"mark.png", 2} => png(:green)
    }

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{now: 1_000, block_main: false, versions: %{"image.png" => 1, "mark.png" => 1}}
         end}
      )

    test_pid = self()

    serve = fn conn ->
      current = Agent.get(state, & &1)
      path = Enum.join(conn.path_info, "/")
      version = Map.fetch!(current.versions, path)
      validator = get_req_header(conn, "if-none-match")
      send(test_pid, {:origin, path, validator})
      tag = ~s("#{path}-v#{version}")

      if path == "image.png" and current.block_main do
        send(test_pid, {:main_blocked, self()})

        receive do
          :continue -> :ok
        end
      end

      conn =
        conn
        |> put_resp_header("etag", tag)
        |> put_resp_header("cache-control", "public, max-age=60")
        |> put_resp_header(
          "date",
          Calendar.strftime(DateTime.from_unix!(current.now), "%a, %d %b %Y %H:%M:%S GMT")
        )

      case validator == [tag] do
        true ->
          send_resp(conn, 304, "")

        false ->
          conn
          |> put_resp_content_type("image/png")
          |> send_resp(200, Map.fetch!(bodies, {path, version}))
      end
    end

    # Paths the origin doesn't hold answer 404, and crash.png crashes the
    # fetch.
    plug = fn conn ->
      path = Enum.join(conn.path_info, "/")

      cond do
        path == "crash.png" -> raise "origin crashed"
        Map.has_key?(Agent.get(state, & &1.versions), path) -> serve.(conn)
        true -> send_resp(conn, 404, "")
      end
    end

    config =
      [
        sources: [
          url: [
            adapter: ImagePipe.Source.HTTP,
            match: [scheme: ["http", "https"]],
            options: [
              allowed_hosts: ["origin.test"],
              address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
              req_options: [plug: plug]
            ]
          ]
        ],
        cache: [root: Path.join(root, "output")],
        clock: fn -> Agent.get(state, & &1.now) end,
        watermarks: %{
          logo: [source: "https://origin.test/mark.png"],
          missing: [source: "https://origin.test/missing.png"],
          crash: [source: "https://origin.test/crash.png"]
        },
        http_cache: :auto
      ]
      |> Keyword.merge(input_cache(context, root))
      |> Caches.start!()

    %{config: {Caches.plug(config), config}, state: state, root: root}
  end

  test "input-cached assets serve later requests without refetching", %{config: config} do
    first = get(@path, config)
    assert first.status == 200
    assert center(first) == [255, 0, 0]
    assert_received {:origin, "image.png", []}
    assert_received {:origin, "mark.png", []}

    variant = get("/w=30/wm=logo/format=png/src/https://origin.test/image.png", config)
    assert variant.status == 200
    refute_received {:origin, _path, _validator}
  end

  @tag input_cache: false
  test "without an originals cache, later requests reuse an asset's bytes", %{config: config} do
    assert get(@path, config).status == 200
    flush()

    variant = get("/w=30/wm=logo/format=png/src/https://origin.test/image.png", config)
    assert variant.status == 200
    assert center(variant) == [255, 0, 0]
    assert_received {:origin, "image.png", []}
    refute_received {:origin, "mark.png", _validator}
  end

  test "a stored asset whose bytes are corrupt is discarded after a decode failure", %{
    config: config,
    root: root
  } do
    assert get(@path, config).status == 200
    flush()
    mark = png(:red)

    [body] =
      root
      |> Path.join("input/**/*.body")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) == mark))

    File.write!(body, :binary.copy(<<0>>, byte_size(mark)))

    assert get("/w=30/wm=logo/format=png/src/https://origin.test/image.png", config).status ==
             415

    refute_received {:origin, "mark.png", _validator}

    assert get("/w=20/wm=logo/format=png/src/https://origin.test/image.png", config).status ==
             200

    assert_received {:origin, "mark.png", []}
  end

  test "assets are fetched while the main source downloads", %{config: config, state: state} do
    Agent.update(state, &%{&1 | block_main: true})
    request = Task.async(fn -> get(@path, config) end)

    assert_receive {:main_blocked, main}
    assert_receive {:origin, "mark.png", []}
    send(main, :continue)
    assert Task.await(request).status == 200
  end

  test "a conditional GET answers 304 before fetching either source", %{config: config} do
    [etag] = get_resp_header(get(@path, config), "etag")
    flush()

    conditional =
      conn(:get, @path) |> put_req_header("if-none-match", etag) |> call(config)

    assert conditional.status == 304
    refute_received {:origin, _path, _validator}
  end

  for input_cache <- [true, false] do
    @tag input_cache: input_cache
    test "an asset revision changes the cache key and ETag (originals cache: #{input_cache})",
         %{config: config, state: state} do
      first = get(@path, config)
      [first_etag] = get_resp_header(first, "etag")

      Agent.update(state, fn current ->
        %{current | now: current.now + 120, versions: %{current.versions | "mark.png" => 2}}
      end)

      flush()
      second = get(@path, config)
      assert second.status == 200
      assert_received {:origin, "mark.png", [~s("mark.png-v1")]}
      assert center(second) == [0, 128, 0]
      refute get_resp_header(second, "etag") == [first_etag]
    end

    @tag input_cache: input_cache
    test "a stale asset revalidates and keeps identity when unchanged (originals cache: #{input_cache})",
         %{config: config, state: state} do
      [etag] = get_resp_header(get(@path, config), "etag")
      Agent.update(state, &%{&1 | now: &1.now + 120})
      flush()

      again = get(@path, config)
      assert again.status == 200
      assert_received {:origin, "mark.png", [~s("mark.png-v1")]}
      assert get_resp_header(again, "etag") == [etag]
    end
  end

  test "a failed watermark releases the staged main source", %{config: config} do
    response = get("/wm=missing/format=png/src/https://origin.test/image.png", config)

    assert response.status >= 400
    assert_received {:origin, "image.png", []}
    assert leased_paths() == []
  end

  @tag capture_log: true
  test "a watermark that crashes releases the staged main source", %{config: config} do
    # The request's process outlives the request, as on a kept-alive
    # connection, so it must release what it leased.
    catch_exit(get("/wm=crash/format=png/src/https://origin.test/image.png", config))

    assert_received {:origin, "image.png", []}
    assert leased_paths() == []
  end

  defp get(path, config), do: conn(:get, path) |> call(config)

  defp input_cache(context, root) do
    case Map.get(context, :input_cache, true) do
      true -> [input_cache: [root: Path.join(root, "input")]]
      false -> []
    end
  end

  # Cache writes finish after the response, so wait for them before the next
  # request or a look at what was stored.
  defp call(conn, {plug, options}) do
    conn = IP.Plug.call(conn, plug)
    Caches.await_writes(options)
    conn
  end

  # Files leased by this process, which is the request's owner: a staged
  # source stays leased until the request releases it.
  defp leased_paths do
    %{table: table} = :sys.get_state(ImagePipe.Cache.Resources)
    :ets.match(table, {:_, self(), :"$1", :_})
  end

  defp center(response) do
    image = Image.from_binary!(response.resp_body)

    image
    |> Image.get_pixel!(div(Image.width(image), 2), div(Image.height(image), 2))
    |> Enum.map(&round/1)
  end

  defp flush do
    receive do
      {:origin, _path, _validator} -> flush()
    after
      0 -> :ok
    end
  end

  defp png(color), do: Image.new!(24, 16, color: color) |> Image.write!(:memory, suffix: ".png")
end
