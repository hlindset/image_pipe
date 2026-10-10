# Run from image_pipe/, one entry count per VM:
# mise exec -- mix run bench/admission_hits.exs 20000
#
# Writes N bounded-pool entries, times Admission's boot directory scan, then
# times a burst of hit casts spread over the tracked keys.
defmodule AdmissionHitsBench do
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key

  @hits 5_000

  def run(count) do
    root = Path.join(System.tmp_dir!(), "admission-bench-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      descriptors = Enum.map(1..count, &put_entry(root, &1))
      registry = FileSystem.registry_name(root)
      {:ok, _} = Registry.start_link(keys: :unique, name: registry)

      {:ok, pid} =
        Admission.start_link(
          Store.admission_options(
            [
              root: root,
              max_size_bytes: count * 1_000,
              sketch_width: 4_096,
              doorkeeper_cardinality: count
            ],
            registry
          )
        )

      {scan_us, :ok} = :timer.tc(fn -> Admission.await_scan(pid, :infinity) end)
      sample = descriptors |> Enum.shuffle() |> Stream.cycle() |> Enum.take(@hits)

      {hits_us, _state} =
        :timer.tc(fn ->
          Enum.each(sample, &Admission.hit(pid, &1))
          :sys.get_state(pid, :infinity)
        end)

      IO.puts(
        JSON.encode!(%{
          entries: count,
          scan_ms: scan_us / 1_000,
          hits: @hits,
          hits_ms: hits_us / 1_000,
          us_per_hit: hits_us / @hits
        })
      )
    after
      File.rm_rf!(root)
    end
  end

  defp put_entry(root, n) do
    hash = :crypto.hash(:sha256, Integer.to_string(n)) |> Base.encode16(case: :lower)
    key = %Key{hash: hash, data: [schema_version: 1]}

    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-04-29 10:15:00Z],
        output_format: :webp
      )

    opts = [root: root]
    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, "body-#{n}", opts)
    :ok = FileSystem.commit_sink(sink, opts)
    {:ok, paths} = FileSystem.paths_from_hash(hash, opts)
    {:ok, descriptor, _mtime} = FileSystem.read_descriptor(paths.meta_path)
    descriptor
  end
end

[count] = System.argv()
AdmissionHitsBench.run(String.to_integer(count))
