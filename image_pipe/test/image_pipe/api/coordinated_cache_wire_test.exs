defmodule ImagePipe.API.CoordinatedCacheWireTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias ImagePipe, as: IP
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Work
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  setup do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-coordinated-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    red = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")
    blue = Image.new!(24, 16, color: :blue) |> Image.write!(:memory, suffix: ".png")

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{now: 1_000, version: 1, control: "public, max-age=60", block: false, status: 200}
         end}
      )

    test_pid = self()

    plug = fn conn ->
      current = Agent.get(state, & &1)
      validator = get_req_header(conn, "if-none-match")
      send(test_pid, {:origin, self(), validator})

      if current.block do
        send(test_pid, {:blocked, self()})

        receive do
          :continue -> :ok
        end
      end

      tag = ~s("v#{current.version}")

      conn =
        conn
        |> put_resp_header("etag", tag)
        |> put_resp_header("cache-control", current.control)
        |> put_resp_header(
          "date",
          Calendar.strftime(DateTime.from_unix!(current.now), "%a, %d %b %Y %H:%M:%S GMT")
        )

      cond do
        current.status != 200 ->
          send_resp(conn, current.status, "failed")

        validator == [tag] ->
          send_resp(conn, 304, "")

        true ->
          conn
          |> put_resp_content_type("image/png")
          |> send_resp(200, if(current.version == 1, do: red, else: blue))
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
        clock: fn -> Agent.get(state, & &1.now) end
      )

    config = IP.Plug.init(config: shared, http_cache: :auto)
    %{config: config, shared: shared, state: state, root: root}
  end

  test "native and HTTP calls share output hits and input bytes across variants", %{
    shared: shared
  } do
    prefix = [__MODULE__, :native_reuse]
    shared = IP.config(Keyword.put(shared.raw, :telemetry_prefix, prefix))
    config = IP.Plug.init(config: shared, http_cache: :auto)
    observe_transforms(prefix)

    assert {:ok, native} = native(shared, 12)
    assert_receive {:origin, _, []}
    assert_receive :transformed
    assert {native.width, native.height} == {12, 8}
    assert request(config, 12).resp_body == native.data
    refute_received :transformed
    refute_received {:origin, _, _}

    http = request(config, 6)
    assert http.status == 200
    assert_receive :transformed
    refute_received {:origin, _, _}
    assert {:ok, cached} = native(shared, 6)
    assert cached.data == http.resp_body
    assert {cached.width, cached.height} == {6, 4}
    refute_received :transformed
    refute_received {:origin, _, _}
  end

  test "a fetch past the coordinator's key limit still stores the original", %{
    config: config
  } do
    test_pid = self()

    holders =
      for index <- 1..64 do
        Task.async(fn ->
          Work.run({:busy_test, index}, fn _coordination, _outcome ->
            send(test_pid, {:holding, index})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    for index <- 1..64, do: assert_receive({:holding, ^index})

    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}
    assert request(config, 6).status == 200
    refute_received {:origin, _, _}

    for holder <- holders, do: send(holder.pid, :release)
    Task.await_many(holders)
  end

  test "native cache hits revalidate origin freshness and observe changed bytes", %{
    shared: shared,
    config: config,
    state: state
  } do
    assert {:ok, first} = native(shared, 12)
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_061})
    assert {:ok, same} = native(shared, 12)
    assert same.data == first.data
    assert_receive {:origin, _, [~s("v1")]}
    Agent.update(state, &%{&1 | now: 1_122, version: 2})
    assert {:ok, changed} = native(shared, 12)
    refute changed.data == first.data
    assert_receive {:origin, _, [~s("v1")]}
    assert request(config, 12).resp_body == changed.data
    refute_received {:origin, _, _}
  end

  test "native storage inputs match HTTP headers and cookies", %{shared: shared} do
    shared =
      IP.config(
        Keyword.put(shared.raw, :storage_inputs, [{:header, "X-Tenant"}, {:cookie, "session"}])
      )

    config = IP.Plug.init(config: shared, http_cache: :auto)
    opts = [request_inputs: [headers: [{"X-Tenant", "one"}], cookies: %{"session" => "abc"}]]
    assert {:ok, first} = native(shared, 12, opts)
    assert_receive {:origin, _, []}
    same = request(config, 12, [{"x-tenant", "one"}, {"cookie", "session=abc"}])
    assert same.resp_body == first.data
    refute_received {:origin, _, _}
    other = request(config, 12, [{"x-tenant", "two"}, {"cookie", "session=abc"}])
    assert other.status == 200
    assert_receive {:origin, _, []}
    assert get_resp_header(other, "etag") == get_resp_header(same, "etag")
    assert {:ok, _} = native(shared, 12)
    assert_receive {:origin, _, []}
    assert request(config, 12).status == 200
    refute_received {:origin, _, _}
  end

  test "native Accept negotiation shares the corresponding HTTP variant", %{shared: shared} do
    prefix = [__MODULE__, :native_accept]
    shared = IP.config(Keyword.merge(shared.raw, auto_webp: true, telemetry_prefix: prefix))
    observe_transforms(prefix)
    client = IP.URL.new() |> IP.URL.group(resize: [width: 12])

    assert {:ok, result} =
             IP.run(shared, client, {:source, "https://origin.test/image.png"},
               accept: "image/webp"
             )

    assert result.format == :webp
    assert_receive :transformed
    assert_receive {:origin, _, []}

    conn =
      conn(:get, IP.URL.url!(client, "https://origin.test/image.png"))
      |> put_req_header("accept", "image/webp")

    http = IP.Plug.call(conn, IP.Plug.init(shared))
    assert http.status == 200
    assert http.resp_body == result.data
    assert get_resp_header(http, "vary") == ["Accept"]
    refute_received :transformed
    refute_received {:origin, _, _}
  end

  test "all native terminals share successful encoded output with HTTP", %{shared: shared} do
    for terminal <- [:info, :blurhash, :lqip_css] do
      client = IP.URL.new() |> IP.URL.output(terminal: terminal)

      assert {:ok, native} =
               IP.run(shared, client, {:source, "https://origin.test/image.png"})

      http =
        IP.Plug.call(
          conn(:get, IP.URL.url!(client, "https://origin.test/image.png")),
          IP.Plug.init(shared)
        )

      assert http.status == 200

      assert {:ok, again} =
               IP.run(shared, client, {:source, "https://origin.test/image.png"})

      assert again == native

      case terminal do
        :info -> assert JSON.decode!(http.resp_body) == native.data
        _ -> assert http.resp_body == native.data
      end
    end

    assert_receive {:origin, _, []}
    refute_received {:origin, _, _}
  end

  test "raw inputs stay uncached and invalid request inputs fail before source access", %{
    shared: shared,
    root: root
  } do
    file = "test/support/image_pipe/test/sources/small.png"

    for input <- [{:file, file}, {:binary, File.read!(file)}] do
      assert {:ok, _} = IP.run(shared, IP.URL.new(), input)
      assert {:ok, _} = IP.run(shared, IP.URL.new(), input)
    end

    refute File.exists?(root)

    for inputs <- [
          [unknown: "secret"],
          [headers: [{"x-tenant", "bad\nvalue"}]],
          [cookies: [session: "abc"]]
        ] do
      assert_raise ArgumentError, fn -> native(shared, 12, request_inputs: inputs) end
    end

    refute_received {:origin, _, _}
    refute File.exists?(root)
  end

  test "native execution honors no-store and rejects expiry before source or cache access", %{
    shared: shared,
    state: state,
    root: root
  } do
    assert {:error, :expired} =
             IP.run(
               shared,
               IP.URL.new(expires: 999),
               {:source, "https://origin.test/image.png"}
             )

    refute_received {:origin, _, _}
    refute File.exists?(root)
    Agent.update(state, &%{&1 | control: "no-store"})
    assert {:ok, _} = native(shared, 12)
    assert_receive {:origin, _, []}
    assert {:ok, _} = native(shared, 12)
    assert_receive {:origin, _, []}
    assert Path.wildcard(Path.join(root, "input/**/*.body")) == []
  end

  defp native(shared, width, options \\ []) do
    builder = IP.URL.new() |> IP.URL.group(resize: [width: width]) |> IP.URL.output(format: :png)
    IP.run(shared, builder, {:source, "https://origin.test/image.png"}, options)
  end

  defp observe_transforms(prefix) do
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:transform, :execute, :stop],
      fn _, _, _, pid -> send(pid, :transformed) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "native stale hits refresh output for HTTP in the background", %{
    shared: shared,
    config: config,
    state: state
  } do
    Agent.update(state, &%{&1 | control: "public, max-age=1, stale-while-revalidate=30"})
    assert {:ok, first} = native(shared, 12)
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_002, block: true, version: 2})
    assert {:ok, stale} = native(shared, 12)
    assert stale.data == first.data
    assert_receive {:blocked, worker}
    assert request(config, 12).resp_body == first.data
    refute_received {:blocked, _}
    monitor = Process.monitor(worker)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    Agent.update(state, &%{&1 | block: false})
    refreshed = request(config, 12)
    assert refreshed.status == 200
    refute refreshed.resp_body == first.data
    assert {:ok, current} = native(shared, 12)
    assert current.data == refreshed.resp_body
  end

  test "concurrent native and HTTP requests coordinate the same source fetch", %{
    shared: shared,
    config: config,
    state: state
  } do
    supervisor = start_supervised!(Task.Supervisor)
    Agent.update(state, &%{&1 | block: true})
    native = Task.Supervisor.async_nolink(supervisor, fn -> native(shared, 12) end)
    assert_receive {:blocked, worker}
    assert_receive {:origin, _, []}
    http = Task.Supervisor.async_nolink(supervisor, fn -> request(config, 12) end)
    send(worker, :continue)
    assert {:ok, result} = Task.await(native)
    response = Task.await(http)
    assert response.status == 200
    assert response.resp_body == result.data
    refute_received {:origin, _, _}
  end

  test "a request waiting behind a stalled download gives up after the fetch deadline", %{
    config: config,
    state: state
  } do
    config = update_url_mount(config, &Keyword.put(&1, :fetch_timeout, 100))
    supervisor = start_supervised!(Task.Supervisor)
    Agent.update(state, &%{&1 | block: true})
    leader = Task.Supervisor.async_nolink(supervisor, fn -> request(config, 12) end)
    assert_receive {:blocked, worker}
    assert_receive {:origin, _, []}

    waiter = request(config, 6)
    assert waiter.status == 504
    refute_received {:origin, _, _}

    send(worker, :continue)
    Task.await(leader)
  end

  test "a decode failure in one variant keeps the original other variants share", %{
    config: config
  } do
    # CMYK is imported through its embedded profile, so preserving a corrupt
    # one fails while stripping it succeeds.
    {:ok, cmyk} = Operation.black(16, 16, bands: 4)
    {:ok, cmyk} = Operation.linear(cmyk, [1.0], [60.0])
    {:ok, cmyk} = Operation.cast(cmyk, :VIPS_FORMAT_UCHAR)
    {:ok, cmyk} = Operation.copy(cmyk, interpretation: :VIPS_INTERPRETATION_CMYK)
    {:ok, <<0xFF, 0xD8, jpeg::binary>>} = VipsImage.write_to_buffer(cmyk, ".jpg")
    payload = <<"ICC_PROFILE", 0, 1, 1, 1, 2, 3, 4>>
    body = <<0xFF, 0xD8, 0xFF, 0xE2, byte_size(payload) + 2::16, payload::binary, jpeg::binary>>
    test_pid = self()

    origin = fn conn ->
      send(test_pid, :origin)

      conn
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, body)
    end

    config =
      update_url_mount(config, fn opts ->
        Keyword.update!(opts, :req_options, &Keyword.put(&1, :plug, origin))
      end)

    get = fn options ->
      ImagePipe.Plug.call(conn(:get, "/#{options}/src/https://origin.test/cmyk.jpg"), config)
    end

    assert get.("format=png/profile=strip").status == 200
    assert_receive :origin
    assert get.("format=png/profile=preserve").status == 415
    assert get.("w=8/format=png/profile=strip").status == 200
    refute_received :origin
  end

  test "a stored original whose bytes are corrupt is discarded after a decode failure", %{
    config: config,
    root: root
  } do
    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}
    [body] = Path.wildcard(Path.join([root, "input", "**", "*.body"]))
    File.write!(body, :binary.copy(<<0>>, File.stat!(body).size))

    assert request(config, 6).status == 415
    refute_received {:origin, _, _}
    assert request(config, 6).status == 200
    assert_receive {:origin, _, []}
  end

  test "variants reuse original bytes and fresh conditionals avoid origin work", %{config: config} do
    first = request(config, 12)
    assert first.status == 200
    assert_receive {:origin, _, []}
    assert [etag] = get_resp_header(first, "etag")
    assert request(config, 8).status == 200
    refute_received {:origin, _, _}
    assert request(config, 12).resp_body == first.resp_body
    assert request(config, 12, [{"if-none-match", etag}]).status == 304
    refute_received {:origin, _, _}
    assert get_resp_header(first, "cache-control") == ["public, max-age=60"]
  end

  test "input telemetry counts reused bytes without counting output-only hits", %{config: config} do
    prefix = [__MODULE__, :input_bytes]
    event = prefix ++ [:cache, :input, :stop]
    handler = make_ref()

    :telemetry.attach(
      handler,
      event,
      fn _, _, metadata, owner ->
        send(owner, {:input_read, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    config = Keyword.put(config, :telemetry_prefix, prefix)
    assert request(config, 12).status == 200
    assert request(config, 8).status == 200
    assert_receive {:input_read, %{cache: :hit, pool: :input, bytes: bytes}}
    assert bytes > 0
    assert request(config, 12).status == 200
    refute_received {:input_read, _}
  end

  test "304 refresh keeps the derived bytes and changed 200 changes pixels and validator", %{
    config: config,
    state: state
  } do
    first = request(config, 12)
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_061})
    unchanged = request(config, 12)
    assert unchanged.status == 200
    assert unchanged.resp_body == first.resp_body
    assert_receive {:origin, _, [~s("v1")]}
    Agent.update(state, &%{&1 | now: 1_122, version: 2})
    changed = request(config, 12, [{"if-none-match", hd(get_resp_header(first, "etag"))}])
    assert changed.status == 200
    refute changed.resp_body == first.resp_body
    refute get_resp_header(changed, "etag") == get_resp_header(first, "etag")
    assert_receive {:origin, _, [~s("v1")]}
  end

  test "origin no-store forbids both caches", %{config: config, state: state, root: root} do
    Agent.update(state, &%{&1 | control: "no-store, max-age=60"})
    first = request(config, 12)
    assert first.status == 200
    assert get_resp_header(first, "etag") == []
    assert get_resp_header(first, "cache-control") == ["no-store"]
    assert_receive {:origin, _, []}
    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}
    assert Path.wildcard(Path.join(root, "input/**/*.body")) == []
  end

  test "generation limits apply to input hits while successful output hits remain usable", %{
    config: config
  } do
    first = request(config, 12)
    assert first.status == 200
    assert_receive {:origin, _, []}
    constrained = Keyword.put(config, :max_body_bytes, 1)
    assert request(constrained, 12).status == 200
    assert request(constrained, 8).status == 413
    pixel_constrained = Keyword.put(config, :max_input_pixels, 1)
    assert request(pixel_constrained, 12).status == 200
    assert request(pixel_constrained, 8).status == 413
    refute_received {:origin, _, _}
  end

  test "SWR responds before a blocked refresh completes", %{config: config, state: state} do
    Agent.update(state, &%{&1 | control: "public, max-age=1, stale-while-revalidate=30"})
    first = request(config, 12)
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_002, block: true, version: 2})
    stale = request(config, 12)
    assert stale.status == 200
    assert stale.resp_body == first.resp_body
    assert get_resp_header(stale, "age") == ["2"]
    assert_receive {:blocked, worker}

    assert request(config, 12, [{"if-none-match", hd(get_resp_header(first, "etag"))}]).status ==
             304

    refute_received {:blocked, _other_worker}
    monitor = Process.monitor(worker)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    Agent.update(state, &%{&1 | block: false})
    refreshed = request(config, 12)
    assert refreshed.status == 200
    refute refreshed.resp_body == first.resp_body
  end

  test "origin restrictions can be overridden explicitly", %{config: config, state: state} do
    Agent.update(state, &%{&1 | control: "private, no-store, no-cache"})
    config = Keyword.put(config, :source_cache_policy, storage: :allow, freshness: {:force, 60})
    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}
    assert request(config, 8).status == 200
    refute_received {:origin, _, _}
  end

  test "immutable sources ignore elapsed time but still honor storage permission", %{
    config: config,
    state: state
  } do
    config = update_url_mount(config, &Keyword.put(&1, :stable, :immutable))

    first = request(config, 12)
    assert first.status == 200
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 5_000_000, version: 2})
    assert request(config, 12).resp_body == first.resp_body
    assert request(config, 8).status == 200
    refute_received {:origin, _, _}
  end

  test "input eviction leaves fresh output evidence available", %{config: config, root: root} do
    first = request(config, 12)
    assert_receive {:origin, _, []}
    File.rm_rf!(Path.join(root, "input"))
    assert request(config, 12).resp_body == first.resp_body
    refute_received {:origin, _, _}
    assert request(config, 8).status == 200
    assert_receive {:origin, _, []}
  end

  test "input admission rejection leaves independently bounded output storage usable", %{
    config: config,
    root: root
  } do
    {:ok, input} =
      FileSystem.validate_options(
        root: Path.join(root, "input"),
        pool: :input,
        max_size_bytes: 1,
        node_id: "input"
      )

    {:ok, output} =
      FileSystem.validate_options(
        root: Path.join(root, "output"),
        max_size_bytes: 100_000,
        node_id: "output"
      )

    start_supervised!(FileSystem.child_spec(input))
    start_supervised!(FileSystem.child_spec(output))

    config =
      config
      |> Keyword.put(:input_cache, {FileSystem, input})
      |> Keyword.put(:cache, {FileSystem, output})

    first = request(config, 12)
    assert first.status == 200
    assert_receive {:origin, _, []}
    assert Path.wildcard(Path.join(root, "input/**/*.body")) == []
    assert request(config, 12).resp_body == first.resp_body
    refute_received {:origin, _, _}
    assert request(config, 8).status == 200
    assert_receive {:origin, _, []}
  end

  test "a cachebuster bypasses both pools while preserving byte validators", %{config: config} do
    request_version = fn version ->
      conn(:get, "/cb=#{version}/w=12/format=png/src/https://origin.test/image.png")
      |> ImagePipe.Plug.call(config)
    end

    first = request_version.("one")
    assert first.status == 200
    assert_receive {:origin, _, []}
    second = request_version.("two")
    assert second.status == 200
    assert_receive {:origin, _, []}
    assert first.resp_body == second.resp_body
    assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
    assert request_version.("two").resp_body == second.resp_body
    refute_received {:origin, _, _}
  end

  test "simultaneous variants share a cold fetch", %{config: config, state: state} do
    Agent.update(state, &%{&1 | block: true})
    supervisor = start_supervised!(Task.Supervisor)
    first = Task.Supervisor.async_nolink(supervisor, fn -> request(config, 12) end)
    assert_receive {:blocked, worker}
    second = Task.Supervisor.async_nolink(supervisor, fn -> request(config, 8) end)
    Agent.update(state, &%{&1 | block: false})
    send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
    assert_receive {:origin, _, []}
    refute_received {:origin, _, _}
  end

  test "failed SWR refresh cannot extend the stale deadline", %{config: config, state: state} do
    Agent.update(state, &%{&1 | control: "public, max-age=1, stale-while-revalidate=3"})
    first = request(config, 12)
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_002, block: true, status: 503})
    assert request(config, 12).resp_body == first.resp_body
    assert_receive {:blocked, worker}
    monitor = Process.monitor(worker)
    send(worker, :continue)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    Agent.update(state, &%{&1 | now: 1_005, block: false})
    assert request(config, 12).status == 502
  end

  test "no-cache validates on every request without downloading unchanged bytes", %{
    config: config,
    state: state
  } do
    Agent.update(state, &%{&1 | control: "no-cache"})
    first = request(config, 12)
    assert hd(get_resp_header(first, "cache-control")) =~ "no-cache"
    assert_receive {:origin, _, []}
    assert request(config, 8).status == 200
    assert_receive {:origin, _, [~s("v1")]}
    assert request(config, 12).resp_body == first.resp_body
    assert_receive {:origin, _, [~s("v1")]}
    refute_received {:origin, _, _}
  end

  test "a revalidating warm hit reads the source record once", %{shared: shared, state: state} do
    prefix = [__MODULE__, :single_source_read]
    shared = IP.config(Keyword.put(shared.raw, :telemetry_prefix, prefix))
    config = IP.Plug.init(config: shared, http_cache: :auto)
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:cache, :lookup, :stop],
      fn _, _, meta, pid -> send(pid, {:lookup, meta.cache}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    Agent.update(state, &%{&1 | control: "no-cache"})
    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}
    flush_lookups()

    assert request(config, 12).status == 200
    assert_receive {:origin, _, [~s("v1")]}
    # One source-record read, then the output hit.
    assert_received {:lookup, :hit}
    assert_received {:lookup, :hit}
    refute_received {:lookup, _}
  end

  test "a request uses a fresh record another request wrote after its own read", %{
    shared: shared,
    state: state
  } do
    prefix = [__MODULE__, :publish_between_read_and_lock]
    shared = IP.config(Keyword.put(shared.raw, :telemetry_prefix, prefix))
    config = IP.Plug.init(config: shared, http_cache: :auto)
    assert request(config, 12).status == 200
    assert_receive {:origin, _, []}

    # Expired, so the next request revalidates. Another request refreshes the
    # record after this one read the expired copy but before it locks.
    Agent.update(state, &%{&1 | now: 1_070})
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:cache, :lookup, :stop],
      fn _, _, _, {handler, config} ->
        :telemetry.detach(handler)
        200 = request(config, 8).status
      end,
      {handler, config}
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert request(config, 12).status == 200
    assert_receive {:origin, _, [~s("v1")]}
    refute_received {:origin, _, _}
  end

  defp flush_lookups do
    receive do
      {:lookup, _} -> flush_lookups()
    after
      0 -> :ok
    end
  end

  test "dynamic credentials partition fresh cached originals and outputs", %{
    config: config,
    state: state
  } do
    test_pid = self()

    auth = fn ->
      token = Agent.get(state, &"principal-#{&1.version}")
      send(test_pid, {:auth_resolved, token})
      {:bearer, token}
    end

    config =
      update_url_mount(config, fn opts ->
        Keyword.update!(opts, :req_options, &Keyword.put(&1, :auth, auth))
      end)

    first = request(config, 12)
    assert first.status == 200
    assert_receive {:auth_resolved, "principal-1"}
    assert_receive {:origin, _, []}
    refute_received {:auth_resolved, _}
    Agent.update(state, &%{&1 | version: 2})
    second = request(config, 12)
    assert second.status == 200
    assert_receive {:auth_resolved, "principal-2"}
    assert_receive {:origin, _, []}
    refute second.resp_body == first.resp_body
    refute_received {:auth_resolved, _}
  end

  test "immutable source storage permission permits conditionals after both pools are removed", %{
    config: config,
    root: root
  } do
    config =
      config
      |> update_url_mount(&Keyword.put(&1, :stable, :immutable))
      |> Keyword.put(:source_cache_policy, storage: :allow)

    first = request(config, 12)
    assert first.status == 200
    assert_receive {:origin, _, []}
    File.rm_rf!(root)

    assert request(config, 12, [{"if-none-match", hd(get_resp_header(first, "etag"))}]).status ==
             304

    refute_received {:origin, _, _}
    refute File.exists?(root)
  end

  test "a truncated original fails open while a surviving output remains usable", %{
    config: config,
    root: root
  } do
    first = request(config, 12)
    assert_receive {:origin, _, []}
    [body] = Path.wildcard(Path.join(root, "input/**/*.body"))
    File.write!(body, binary_part(File.read!(body), 0, 100))
    assert request(config, 12).resp_body == first.resp_body
    refute_received {:origin, _, _}
    assert request(config, 8).status == 200
    assert_receive {:origin, _, []}
  end

  test "must-revalidate blocks stale reuse and survives downstream headers", %{
    config: config,
    state: state
  } do
    Agent.update(
      state,
      &%{&1 | control: "public, max-age=1, must-revalidate, stale-while-revalidate=30"}
    )

    first = request(config, 12)
    assert hd(get_resp_header(first, "cache-control")) =~ "must-revalidate"
    assert_receive {:origin, _, []}
    Agent.update(state, &%{&1 | now: 1_002, version: 2})
    changed = request(config, 12)
    assert changed.status == 200
    refute changed.resp_body == first.resp_body
    assert_receive {:origin, _, [~s("v1")]}
  end

  test "a fetch that lost its coordination lease cannot replace newer source evidence", %{
    config: config,
    state: state
  } do
    supervisor = start_supervised!(Task.Supervisor)
    Agent.update(state, &%{&1 | block: true})
    old = Task.Supervisor.async_nolink(supervisor, fn -> request(config, 12) end)
    assert_receive {:blocked, worker}
    assert_receive {:origin, _, []}
    :ok = Supervisor.terminate_child(ImagePipe.Supervisor, ImagePipe.Cache.Work)
    {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, ImagePipe.Cache.Work)
    Agent.update(state, &%{&1 | block: false, version: 2})
    newer = request(config, 12)
    assert newer.status == 200
    assert_receive {:origin, _, []}
    send(worker, :continue)
    assert Task.await(old).status == 200
    assert request(config, 12).resp_body == newer.resp_body
    refute_received {:origin, _, _}
  end

  describe "validators mode with headers set by the host" do
    setup %{shared: shared} do
      %{validators: IP.Plug.init(config: shared, http_cache: :validators)}
    end

    test "a changeable source carries its lifetime and an ETag", %{validators: config} do
      conn = request(config, 12)

      assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
      assert [_etag] = get_resp_header(conn, "etag")
    end

    test "a response cookie suppresses the ETag and the source lifetime", %{validators: config} do
      conn = host_request(config, &put_resp_cookie(&1, "session", "a"))

      assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
      assert get_resp_header(conn, "etag") == []
      assert get_resp_header(conn, "age") == []
    end

    test "a host no-store suppresses the ETag and the source lifetime", %{validators: config} do
      conn = host_request(config, &put_resp_header(&1, "cache-control", "no-store"))

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "etag") == []
    end

    test "a host Vary: * is kept and suppresses the ETag and the source lifetime", %{
      validators: config
    } do
      conn = host_request(config, &put_resp_header(&1, "vary", "*"))

      assert get_resp_header(conn, "vary") == ["*"]
      assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
      assert get_resp_header(conn, "etag") == []
    end

    test "a host Vary is merged with the negotiated Accept", %{validators: config} do
      conn =
        :get
        |> conn("/w=12/src/https://origin.test/image.png")
        |> put_req_header("accept", "image/webp")
        |> put_resp_header("vary", "Accept-Encoding")
        |> ImagePipe.Plug.call(config)

      assert conn.status == 200
      assert get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
    end
  end

  defp host_request(config, host_plug) do
    :get
    |> conn("/w=12/format=png/src/https://origin.test/image.png")
    |> host_plug.()
    |> ImagePipe.Plug.call(config)
  end

  defp request(config, width, headers \\ []) do
    conn = conn(:get, "/w=#{width}/format=png/src/https://origin.test/image.png")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    ImagePipe.Plug.call(conn, config)
  end

  # Changes the validated options of the `url` mount in place.
  defp update_url_mount(config, fun) do
    update_in(config, [:sources, Access.key!(:sources), :url], fn {module, opts} ->
      {module, fun.(opts)}
    end)
  end
end
