defmodule ImagePipe.Cache.FileSystem.MetadataDecodeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  @moduletag :tmp_dir

  # A fresh VM loads code slowly while the rest of the suite runs.
  @peer_timeout 60_000

  # Atoms can't be removed from this VM, so a fresh peer that loads code
  # lazily, as `mix run` and IEx do, reads entries this VM wrote.
  test "a VM that loads code lazily reads entries another VM wrote", %{tmp_dir: root} do
    key = write_entry(root, %ImagePipe.Debug.Info{output_negotiated?: true, source_icc?: false})

    assert {:ok, %{debug: %ImagePipe.Debug.Info{output_negotiated?: true}}} =
             read_in_fresh_vm(key, root)
  end

  test "metadata naming an atom no module defines is still refused", %{tmp_dir: root} do
    unknown = String.to_atom("image_pipe_test_unknown_#{System.unique_integer([:positive])}")
    key = write_entry(root, %ImagePipe.Debug.Info{source_color_space: unknown})

    assert read_in_fresh_vm(key, root) == {:error, {:invalid_metadata, :decode_failed}}
  end

  defp write_entry(root, debug) do
    key = %Key{hash: String.duplicate("c", 64), data: []}

    metadata = %Entry.Metadata{
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-10-05 10:00:00Z],
      output_format: :webp,
      debug: debug
    }

    {:ok, sink} = FileSystem.open_sink(key, metadata, root: root)
    {:ok, sink} = FileSystem.write_chunk(sink, "body", root: root)
    :ok = FileSystem.commit_sink(sink, root: root)
    key
  end

  defp read_in_fresh_vm(key, root) do
    peer =
      start_supervised!(%{
        id: :peer,
        start:
          {:peer, :start_link,
           [
             %{
               connection: :standard_io,
               exec: String.to_charlist(Path.join([:code.root_dir(), "bin", "erl"])),
               args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
             }
           ]}
      })

    for app <- [:elixir, :image_pipe_url, :vix, :image_pipe],
        do: :ok = :peer.call(peer, :application, :load, [app], @peer_timeout)

    :peer.call(peer, FileSystem.Store, :metadata, [key, [root: root]], @peer_timeout)
  end
end
