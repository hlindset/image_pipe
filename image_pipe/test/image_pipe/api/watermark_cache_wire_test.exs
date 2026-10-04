defmodule ImagePipe.API.WatermarkCacheWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias ImagePipe.Cache.FileSystem

  @path "/wm=logo/format=png/src/https://origin.test/image.png"

  setup do
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

    # Paths the origin doesn't hold answer 404.
    plug = fn conn ->
      case Map.has_key?(Agent.get(state, & &1.versions), Enum.join(conn.path_info, "/")) do
        true -> serve.(conn)
        false -> send_resp(conn, 404, "")
      end
    end

    shared =
      IP.config(
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
        cache: {FileSystem, root: Path.join(root, "output")},
        input_cache: {FileSystem, root: Path.join(root, "input")},
        clock: fn -> Agent.get(state, & &1.now) end,
        watermarks: %{
          logo: [source: "https://origin.test/mark.png"],
          missing: [source: "https://origin.test/missing.png"]
        }
      )

    %{config: IP.Plug.init(config: shared, http_cache: :auto), state: state}
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
      conn(:get, @path) |> put_req_header("if-none-match", etag) |> IP.Plug.call(config)

    assert conditional.status == 304
    refute_received {:origin, _path, _validator}
  end

  test "an asset revision changes the cache key and ETag", %{config: config, state: state} do
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

  test "a stale asset revalidates and keeps identity when unchanged", %{
    config: config,
    state: state
  } do
    [etag] = get_resp_header(get(@path, config), "etag")
    Agent.update(state, &%{&1 | now: &1.now + 120})
    flush()

    again = get(@path, config)
    assert again.status == 200
    assert_received {:origin, "mark.png", [~s("mark.png-v1")]}
    assert get_resp_header(again, "etag") == [etag]
  end

  test "a failed watermark releases the staged main source", %{config: config} do
    response = get("/wm=missing/format=png/src/https://origin.test/image.png", config)

    assert response.status >= 400
    assert_received {:origin, "image.png", []}
    assert leased_paths() == []
  end

  defp get(path, config), do: conn(:get, path) |> IP.Plug.call(config)

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
