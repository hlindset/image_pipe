defmodule ImagePipe.Source.File do
  @behaviour ImagePipe.Source

  alias ImagePipe.MaterialDigest
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSettings
  alias ImagePipe.Source.Origin
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @options_schema NimbleOptions.new!(
                    [
                      root: [
                        type: :string,
                        required: true,
                        doc: """
                        Directory the source serves. A relative path is expanded \
                        against the working directory when the configuration is built.
                        """
                      ],
                      root_id: [
                        type: :string,
                        required: true,
                        doc: """
                        Stable name for the directory. Caches identify the source's \
                        files by `:root_id` and path instead of by `:root`, so keep \
                        the name when the directory moves, and change it when the \
                        directory holds different files.
                        """
                      ],
                      verify: [
                        type: {:in, [:stat, :hash]},
                        type_doc: "`:stat` or `:hash`",
                        default: :stat,
                        doc: """
                        How a file that can change is checked. `:stat` reuses the \
                        file's hash while its size, timestamps, inode, and device \
                        are unchanged. \
                        `:hash` reads and hashes the file on every check, for \
                        filesystems whose times can't be trusted, such as a network \
                        filesystem whose server clock can lag behind this host's.
                        """
                      ],
                      copy: [
                        type: {:in, [:none, :keep]},
                        type_doc: "`:none` or `:keep`",
                        default: :none,
                        doc: """
                        `:keep` stores a copy of each original in the \
                        [originals cache](cache.md#originals-cache), so other sizes \
                        and formats don't read the file again. Use it on network \
                        filesystems such as EFS or NFS. Needs `:input_cache` configured.
                        """
                      ]
                    ] ++ CacheSettings.schema()
                  )

  @moduledoc """
  Source adapter for image files below a directory.

      media: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: "/srv/images", root_id: "media"]
      ]

  It resolves path sources, so `photos/beach.jpg` and `/photos/beach.jpg` both
  read `/srv/images/photos/beach.jpg`. Paths can't leave the root. A path that
  names no regular file is not found. Setting up a mount is covered in
  [Serving images from local files](serving-local-files.md).

  A file that isn't `stable: :immutable` is identified by the SHA-256 of its
  bytes. After hashing, its size, mtime, ctime, inode, and device are kept,
  and a later request whose stat matches reuses the hash without reading the
  file. Stat times have one-second resolution, so a file whose mtime or ctime
  falls in the second it was hashed is hashed again on the next request. On
  a network filesystem the times come from the server's clock.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  @doc false
  def options_schema, do: @options_schema.schema

  @impl Source
  def identifiers(_options), do: [SourcePath]

  @impl Source
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} ->
        validated =
          Keyword.update!(validated, :root, &Path.expand/1)

        CacheSettings.validate(validated)

      {:error, error} ->
        {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @impl Source
  def resolve(%SourcePath{segments: segments}, opts, _runtime_opts) do
    with :ok <- validate_segments(segments),
         {:ok, _path} <- safe_path(opts, segments) do
      identity = [
        kind: :path,
        adapter: :path,
        root: Keyword.fetch!(opts, :root_id),
        path: segments
      ]

      cache =
        CacheSettings.fields(opts,
          stable?: CacheSettings.immutable?(opts),
          seed: identity,
          copy?: Keyword.fetch!(opts, :copy) == :keep
        )

      {:ok,
       struct!(
         Resolved,
         [
           identity: identity,
           fetch: [segments: segments]
         ] ++ cache
       )}
    end
  end

  @impl Source
  def fetch(%Resolved{fetch: fetch}, opts, runtime_opts) do
    with {:ok, path} <- safe_path(opts, fetch[:segments]),
         {:ok, stat} <- regular_file(path),
         :ok <- within_limit(stat, runtime_opts),
         :ok <- readable(path) do
      now = Keyword.get(runtime_opts, :clock, &now/0).()
      evidence = evidence(Keyword.fetch!(opts, :verify), path, stat, now)

      previous = Keyword.get(runtime_opts, :source_validation)

      if unchanged?(previous, evidence),
        do: {:not_modified, %{previous | requested_at: now, received_at: now}},
        else: {:ok, %Response{path: path, origin: evidence}}
    end
  end

  defp unchanged?(%Origin{headers: %{"etag" => same}}, %Origin{headers: %{"etag" => same}}),
    do: true

  defp unchanged?(_previous, _evidence), do: false

  defp now, do: System.os_time(:second)

  # Stat evidence, shaped as origin evidence so revalidation and freshness work
  # as for HTTP. A file touched in the current second could change again
  # without its stat changing, so it keeps no evidence.
  defp evidence(:hash, _path, _stat, _now), do: nil

  defp evidence(:stat, _path, %File.Stat{mtime: mtime, ctime: ctime}, now)
       when mtime >= now or ctime >= now,
       do: nil

  defp evidence(:stat, path, %File.Stat{} = stat, now) do
    validator =
      ~s(W/"#{stat.size}-#{stat.mtime}-#{stat.ctime}-#{stat.inode}-#{stat.major_device}")

    %Origin{
      status: 200,
      headers: %{"etag" => [validator]},
      requested_at: now,
      received_at: now,
      resource: MaterialDigest.of(path),
      vary: %{}
    }
  end

  defp validate_segments(segments) when is_list(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      :ok
    else
      {:error, {:source, :denied_path}}
    end
  end

  defp validate_segments(_segments), do: {:error, {:source, :denied_path}}

  defp valid_segment?(segment) when is_binary(segment) do
    segment != "" and segment != "." and segment != ".." and
      not String.contains?(segment, ["/", "\\"])
  end

  defp valid_segment?(_segment), do: false

  defp safe_path(opts, segments) when is_list(opts) do
    safe_path(Keyword.fetch!(opts, :root), segments)
  end

  defp safe_path(root, segments) do
    relative = Path.join(segments)

    case Path.safe_relative(relative, root) do
      {:ok, safe_relative} -> {:ok, Path.join(root, safe_relative)}
      :error -> {:error, {:source, :denied_path}}
    end
  end

  defp within_limit(%File.Stat{size: size}, runtime_opts) do
    case Keyword.get(runtime_opts, :max_body_bytes) do
      limit when is_integer(limit) and size > limit -> {:error, {:source, :body_too_large}}
      _within -> :ok
    end
  end

  # The bytes are read later, during staging, where a failure would read as an
  # incomplete body. Opening the file here reports it as unreadable.
  defp readable(path) do
    case File.open(path, [:read]) do
      {:ok, device} -> File.close(device)
      {:error, _reason} -> {:error, {:source, :unreadable}}
    end
  end

  defp regular_file(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {:ok, stat}

      {:ok, _stat} ->
        {:error, {:source, :not_found}}

      {:error, reason} when reason in [:enoent, :enotdir, :enametoolong] ->
        {:error, {:source, :not_found}}

      {:error, _reason} ->
        {:error, {:source, :unreadable}}
    end
  end
end
