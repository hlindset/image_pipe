defmodule ImagePipe.Cache.FileSystemPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key
  alias ImagePipe.Format

  property "generated cache paths stay under the configured root" do
    check all hash <- sha256_hex(),
              prefix <- safe_prefix(),
              max_runs: 100 do
      root = unique_root()

      assert {:ok, paths} = FileSystem.paths(key(hash), root: root, path_prefix: prefix)

      assert Enum.all?(
               Map.values(Map.take(paths, [:dir, :meta_path])),
               &under_root?(&1, root)
             )
    end
  end

  property "unsafe path prefixes are rejected" do
    check all prefix <- unsafe_prefix(),
              max_runs: 100 do
      assert {:error, {:invalid_path_prefix, ^prefix}} =
               FileSystem.paths(key(), root: unique_root(), path_prefix: prefix)
    end
  end

  property "put followed by get round-trips valid entries" do
    check all hash <- sha256_hex(),
              body <- binary(max_length: 2_048),
              content_type <- member_of(["image/avif", "image/webp", "image/jpeg", "image/png"]),
              headers <- list_of(allowed_header(), max_length: 6),
              max_runs: 50 do
      root = unique_root()
      File.rm_rf!(root)

      try do
        cache_key = key(hash)

        {:ok, cached_headers} = Entry.cacheable_headers(headers)

        entry = %Entry{
          body: body,
          content_type: content_type,
          headers: cached_headers,
          created_at: ~U[2026-04-29 10:15:00Z]
        }

        assert :ok = seed_entry(cache_key, entry, root: root)
        assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
        assert cached_entry == entry
      after
        File.rm_rf!(root)
      end
    end
  end

  property "arbitrary metadata bytes do not crash get" do
    check all metadata_bytes <- binary(max_length: 2_048),
              body <- binary(max_length: 128),
              max_runs: 100 do
      root = unique_root()
      File.rm_rf!(root)

      try do
        cache_key = key()
        assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
        File.mkdir_p!(paths.dir)
        File.write!(Path.join(paths.dir, body_filename(cache_key, body)), body)
        File.write!(paths.meta_path, metadata_bytes)

        assert {:error, _reason} =
                 FileSystem.get(cache_key, root: root)
      after
        File.rm_rf!(root)
      end
    end
  end

  # Seed an entry through the FileSystem adapter's own sink callbacks
  # (open_sink -> write_chunk -> commit_sink) — the same path the request
  # lifecycle uses to stage a cache entry.
  defp seed_entry(cache_key, %Entry{} = entry, opts) do
    {:ok, output_format} = Format.format_from_mime_type(entry.content_type)

    metadata = %Entry.Metadata{
      content_type: entry.content_type,
      headers: entry.headers,
      created_at: entry.created_at,
      output_format: output_format
    }

    with {:ok, state} <- FileSystem.open_sink(cache_key, metadata, opts),
         {:ok, state} <- FileSystem.write_chunk(state, entry.body, opts) do
      FileSystem.commit_sink(state, opts)
    end
  end

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      data: [schema_version: 1]
    }
  end

  defp sha256_hex do
    map(binary(length: 32), &Base.encode16(&1, case: :lower))
  end

  defp body_sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp body_filename(cache_key, body), do: "#{cache_key.hash}.#{body_sha256(body)}.body"

  defp safe_prefix do
    one_of([
      constant(""),
      map(list_of(path_segment(), min_length: 1, max_length: 4), &Enum.join(&1, "/"))
    ])
  end

  defp unsafe_prefix do
    one_of([
      constant("../outside"),
      constant("processed/../outside"),
      constant("processed/./images"),
      constant("processed//images"),
      constant("/absolute")
    ])
  end

  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)

  defp allowed_header do
    map(
      {member_of(["vary", "Vary", "cache-control", "Cache-Control"]),
       string(:alphanumeric, max_length: 24)},
      fn {name, value} -> {name, value} end
    )
  end

  defp unique_root do
    Path.join(
      System.tmp_dir!(),
      "image_pipe_fs_cache_prop_#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp under_root?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end
end
