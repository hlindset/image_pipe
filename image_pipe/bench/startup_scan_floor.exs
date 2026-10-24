# A floor for the startup scan's counting: lists and parses each first-level
# partition group in its own task and inserts compact rows, as Admission keeps
# them, straight into a public ETS table. It doesn't pair bodies with their
# metadata files or sweep. Run on a cache `startup_scan.exs` generated:
#
#   mise exec -- mix run bench/startup_scan_floor.exs DIR
alias ImagePipe.Cache.FileSystem.Store
[dir] = System.argv()
groups = for a <- File.ls!(dir), byte_size(a) == 2, do: Path.join(dir, a)

row = fn name ->
  case Store.parse_body_filename(name) do
    {:ok, e} ->
      [
        {Base.decode16!(e.key_hash, case: :lower), e.size_bytes, e.cost_us,
         Base.decode16!(e.body_sha256, case: :lower)}
      ]

    _ ->
      []
  end
end

{us, table} =
  :timer.tc(fn ->
    table = :ets.new(:entries, [:ordered_set, :public, write_concurrency: true])

    groups
    |> Task.async_stream(
      fn g ->
        for b <- File.ls!(g) do
          {:ok, names} = ImagePipe.RawFile.list_dir(Path.join(g, b))
          :ets.insert(table, Enum.flat_map(names, row))
        end

        :ok
      end, max_concurrency: System.schedulers_online(), ordered: false, timeout: :infinity)
    |> Stream.run()

    table
  end)

IO.puts(JSON.encode!(%{floor_ms: us / 1000, rows: :ets.info(table, :size)}))
