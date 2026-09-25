defmodule ImagePipe.API.SharedCacheWireTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.SharedFileSystem
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.{Lifecycle, Locations, Partition, Runtime}

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_wire_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    state =
      start_supervised!(
        {Agent, fn -> %{now: 1_000, version: 1, control: "public, max-age=60"} end}
      )

    red = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")
    blue = Image.new!(24, 16, color: :blue) |> Image.write!(:memory, suffix: ".png")
    parent = self()

    origin = fn conn ->
      current = Agent.get(state, & &1)
      validator = get_req_header(conn, "if-none-match")
      send(parent, {:origin, validator})
      tag = ~s("v#{current.version}")

      conn =
        conn
        |> put_resp_header("etag", tag)
        |> put_resp_header("cache-control", current.control)
        |> put_resp_header(
          "date",
          Calendar.strftime(DateTime.from_unix!(current.now), "%a, %d %b %Y %H:%M:%S GMT")
        )

      if validator == [tag],
        do: send_resp(conn, 304, ""),
        else:
          conn
          |> put_resp_content_type("image/png")
          |> send_resp(200, if(current.version == 1, do: red, else: blue))
    end

    clock = fn -> Agent.get(state, & &1.now) end

    for name <- [__MODULE__.A, __MODULE__.B] do
      start_supervised!(
        {SharedFileSystem,
         name: name,
         root: Path.join(root, "shared"),
         local_root: Path.join(root, Atom.to_string(name)),
         clock: clock}
      )
    end

    %{root: root, state: state, origin: origin, clock: clock}
  end

  test "output-only nodes share encoded bytes and source evidence", ctx do
    a = config(ctx, __MODULE__.A, false)
    b = config(ctx, __MODULE__.B, false)
    first = request(a, 12)
    assert first.status == 200
    assert_receive {:origin, []}
    second = request(b, 12)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    refute_received {:origin, _}
    assert dimensions(second) == {12, 8}
    assert Path.wildcard(Path.join(ctx.root, "shared/partitions/*/originals/*/*/*/body")) == []
    assert request(b, 12, [{"if-none-match", hd(get_resp_header(second, "etag"))}]).status == 304
    refute_received {:origin, _}
  end

  test "shared originals generate another node's new variant without refetching", ctx do
    first = request(config(ctx, __MODULE__.A), 12)
    assert first.status == 200
    assert_receive {:origin, []}
    second = request(config(ctx, __MODULE__.B), 6)
    assert second.status == 200
    assert dimensions(second) == {6, 4}
    assert Image.get_pixel!(Image.from_binary!(second.resp_body), 0, 0) == [255, 0, 0]
    refute_received {:origin, _}
  end

  test "expired evidence revalidates and missing originals cause an unconditional fetch", ctx do
    a = config(ctx, __MODULE__.A)
    assert request(a, 12).status == 200
    assert_receive {:origin, []}

    for path <- Path.wildcard(Path.join(ctx.root, "shared/partitions/*/originals/*/*/*/body")),
        do: File.rm!(path)

    Agent.update(ctx.state, &%{&1 | now: 1_061})
    refreshed = request(a, 6)
    assert refreshed.status == 200
    assert_receive {:origin, [~s("v1")]}
    assert_receive {:origin, []}
    assert Image.get_pixel!(Image.from_binary!(refreshed.resp_body), 0, 0) == [255, 0, 0]
  end

  test "nodes keep independently fresh revisions when another node learns changed pixels", ctx do
    Agent.update(ctx.state, &%{&1 | control: "public, max-age=10"})
    a = config(ctx, __MODULE__.A)
    b = config(ctx, __MODULE__.B)
    assert request(a, 12).status == 200
    assert_receive {:origin, []}

    for path <- Path.wildcard(Path.join(ctx.root, "shared/partitions/*/sources/*/*/*/meta")),
        do: File.rm!(path)

    Agent.update(ctx.state, &%{&1 | control: "public, max-age=60"})
    old = request(b, 12)
    assert old.status == 200
    assert_receive {:origin, []}
    Agent.update(ctx.state, &%{&1 | now: 1_011, version: 2})
    changed = request(a, 12)
    assert_receive {:origin, [~s("v1")]}
    assert Image.get_pixel!(Image.from_binary!(changed.resp_body), 0, 0) == [0, 0, 255]
    retained = request(b, 12)
    assert retained.resp_body == old.resp_body
    assert Image.get_pixel!(Image.from_binary!(retained.resp_body), 0, 0) == [255, 0, 0]
    refute_received {:origin, _}
  end

  test "lookup worker restart renews runtime handles", ctx do
    a = config(ctx, __MODULE__.A)
    first = request(a, 12)
    assert_receive {:origin, []}
    :ok = Supervisor.terminate_child(__MODULE__.A, Locations)
    {:ok, _pid} = Supervisor.restart_child(__MODULE__.A, Locations)
    assert request(a, 12).resp_body == first.resp_body
    refute_received {:origin, _}
  end

  @tag capture_log: true
  test "helper failure bypasses caching and still delivers correct generated pixels", ctx do
    {:ok, context} = Runtime.context(__MODULE__.A)
    assert {:error, _} = CacheIO.run(context.pool, {:erlang, :halt, []}, 0, 1_000)
    result = request(config(ctx, __MODULE__.A), 12)
    assert result.status == 200
    assert dimensions(result) == {12, 8}
    assert Image.get_pixel!(Image.from_binary!(result.resp_body), 0, 0) == [255, 0, 0]
    assert_receive {:origin, []}
  end

  test "retirement rotates the writer without replacing source coordination", _ctx do
    {:ok, before} = Runtime.context(__MODULE__.A)

    assert {:ok, {:ok, _}} =
             CacheIO.run(before.pool, {Partition, :retire, [before.partition]}, 0, 1_000)

    :ok = Supervisor.terminate_child(__MODULE__.A, Lifecycle)
    {:ok, _pid} = Supervisor.restart_child(__MODULE__.A, Lifecycle)
    assert {:ok, after_rotation} = Runtime.context(__MODULE__.A)
    refute after_rotation.partition.id == before.partition.id
    assert after_rotation.sources == before.sources
    refute File.exists?(before.partition.path)
  end

  test "invalid adapter options fail before creating any cache directories", ctx do
    assert {:error, _} = SharedFileSystem.validate_options(runtime: __MODULE__.A, unknown: true)

    assert_raise NimbleOptions.ValidationError, fn ->
      Runtime.start_link(
        name: __MODULE__.Invalid,
        root: Path.join(ctx.root, "invalid"),
        local_root: ctx.root,
        max_attempts: 0
      )
    end

    refute File.exists?(Path.join(ctx.root, "invalid"))
  end

  defp config(ctx, name, originals \\ true) do
    opts = [
      cache: {SharedFileSystem, runtime: name},
      clock: ctx.clock,
      sources: [
        url:
          {ImagePipe.Source.HTTP,
           allowed_hosts: ["origin.test"],
           address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
           req_options: [plug: ctx.origin]}
      ]
    ]

    opts =
      if originals,
        do: Keyword.put(opts, :input_cache, {SharedFileSystem, runtime: name}),
        else: opts

    ImagePipe.Plug.init(opts)
  end

  defp request(config, width, headers \\ []) do
    conn = conn(:get, "/w=#{width}/format=png/src/https://origin.test/image.png")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)

    ImagePipe.Plug.call(conn, config)
  end

  defp dimensions(conn) do
    image = Image.from_binary!(conn.resp_body)
    {Image.width(image), Image.height(image)}
  end
end
