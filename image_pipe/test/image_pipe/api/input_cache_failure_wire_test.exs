defmodule ImagePipe.API.InputCacheFailureWireTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission

  setup do
    root = Path.join(System.tmp_dir!(), "input_failure_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = [root: root, node_id: "test", max_size_bytes: 1_000_000]
    tasks = start_supervised!(Task.Supervisor)
    origin_status = start_supervised!({Agent, fn -> 200 end}, id: :origin_status)

    cache_control =
      start_supervised!({Agent, fn -> "public, max-age=0" end}, id: :cache_control)

    body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")

    origin = fn conn ->
      status = Agent.get(origin_status, & &1)
      conditional? = get_req_header(conn, "if-none-match") == [~s("source")]

      conn =
        conn
        |> put_resp_header("etag", ~s("source"))
        |> put_resp_header("cache-control", Agent.get(cache_control, & &1))
        |> put_resp_content_type("image/png")

      cond do
        status != 200 -> send_resp(conn, status, "source unavailable")
        conditional? -> send_resp(conn, 304, "")
        true -> send_resp(conn, 200, body)
      end
    end

    name = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")

    start_supervised!(
      {ImagePipe,
       name: name,
       sources: [
         url: [
           adapter: ImagePipe.Source.HTTP,
           match: [scheme: ["http", "https"]],
           options: [
             allowed_hosts: ["origin.test"],
             address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
             req_options: [plug: origin]
           ]
         ]
       ],
       input_cache: {FileSystem, pool}}
    )

    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    config = ImagePipe.Plug.init(instance: name)

    %{
      config: config,
      admission: admission,
      tasks: tasks,
      origin_status: origin_status,
      cache_control: cache_control
    }
  end

  @tag capture_log: true
  test "input publication failure still delivers the generated image", ctx do
    result = fail_admission(ctx, :commit)
    assert %Plug.Conn{status: 200} = result
    image = Image.from_binary!(result.resp_body)
    assert {Image.width(image), Image.height(image)} == {12, 8}
  end

  @tag capture_log: true
  test "input metadata refresh failure still delivers revalidated bytes", ctx do
    assert %{status: 200, resp_body: original} = request(ctx.config)
    Agent.update(ctx.cache_control, fn _ -> "public, max-age=0, must-revalidate" end)
    result = fail_admission(ctx, :refresh_source_record)
    assert %Plug.Conn{status: 200, resp_body: ^original} = result
  end

  test "a revalidation that changes nothing leaves the stored metadata alone", ctx do
    assert %{status: 200, resp_body: original} = request(ctx.config)
    :erlang.trace(ctx.admission, true, [:receive])
    assert %{status: 200, resp_body: ^original} = request(ctx.config)
    _ = :sys.get_state(ctx.admission)
    :erlang.trace(ctx.admission, false, [:receive])

    refute_received {:trace, _, :receive, {:"$gen_call", _, {:refresh_source_record, _, _, _}}}
    refute_received {:trace, _, :receive, {:"$gen_call", _, {:commit, _, _}}}
  end

  @tag capture_log: true
  test "invalidation failure preserves the origin error response", ctx do
    assert %{status: 200} = request(ctx.config)
    Agent.update(ctx.origin_status, fn _ -> 404 end)
    assert %Plug.Conn{status: 404} = fail_admission(ctx, :delete)
  end

  defp fail_admission(ctx, operation) do
    parent = self()
    admission = ctx.admission
    monitor = Process.monitor(admission)
    :sys.suspend(admission)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        :erlang.trace(self(), true, [:send, {:tracer, parent}])

        try do
          request(ctx.config)
        catch
          :exit, reason -> {:request_exit, reason}
        end
      end)

    try do
      assert_receive {:trace, _, :send, {:"$gen_call", _, message}, ^admission}, 5_000
      assert elem(message, 0) == operation
    after
      Process.exit(admission, :kill)
    end

    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}
    Task.await(task)
  end

  defp request(config) do
    :get
    |> conn("/w=12/format=png/src/https://origin.test/image.png")
    |> ImagePipe.Plug.call(config)
  end
end
