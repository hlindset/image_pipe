defmodule ImagePipe.API.SourceIntegrityFaultWireTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Test.ProcessingSource

  setup do
    root = Path.join(System.tmp_dir!(), "source-integrity-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    tasks = start_supervised!(Task.Supervisor)
    %{root: root, tasks: tasks, body: File.read!("priv/static/images/waterfall.jpg")}
  end

  for corruption <- [:truncate, :extend] do
    test "a staged #{corruption} is rejected before cache publication", context do
      observer = self()

      stream =
        Stream.resource(
          fn -> :body end,
          fn
            :body ->
              {[context.body], :finish}

            :finish ->
              send(observer, {:staged, self()})
              receive do: (:finish -> {:halt, :finish})
          end,
          fn _ -> :ok end
        )

      config =
        ImagePipe.Plug.init(
          sources: [
            path: [
              adapter: ProcessingSource,
              match: :path,
              options: [test: observer, bytes: context.body, stream: stream, copy?: true]
            ]
          ],
          cache: {FileSystem, root: Path.join(context.root, "output")},
          input_cache: {FileSystem, root: Path.join(context.root, "input")},
          max_body_bytes: 20_000_000,
          max_input_pixels: 60_000_000
        )

      Code.ensure_loaded!(File)
      :erlang.trace_pattern({File, :open, 2}, true, [:local])

      try do
        task =
          Task.Supervisor.async_nolink(context.tasks, fn ->
            Plug.Test.conn(:get, "/w=100/format=png/src/blocked/image.jpg")
            |> ImagePipe.Plug.call(config)
          end)

        assert_receive {:fetch, ["blocked", "image.jpg"], producer}
        :erlang.trace(producer, true, [:call, {:tracer, observer}])
        send(producer, :continue)

        assert_receive {:trace, ^producer, :call,
                        {File, :open, [path, [:read, :write, :binary, :exclusive]]}},
                       2_000

        assert_receive {:staged, ^producer}, 2_000

        case unquote(corruption) do
          :truncate ->
            File.write!(path, binary_part(context.body, 0, byte_size(context.body) - 1))

          :extend ->
            File.write!(path, "extra", [:append])
        end

        send(producer, :finish)
        response = Task.await(task, 10_000)
        assert response.status == 502
        assert Path.wildcard(Path.join(context.root, "**/*.body")) == []
        refute File.exists?(path)
        assert_receive {:closed, ["blocked", "image.jpg"]}
      after
        :erlang.trace_pattern({File, :open, 2}, false, [:local])
      end
    end
  end
end
