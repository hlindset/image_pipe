defmodule ImagePipe.Cache.FileSystem.Store do
  @moduledoc false
  @dialyzer :no_match

  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.CheckedDirs
  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.Cache.FileSystem.Root
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Cache.Key
  alias ImagePipe.SafePath

  @metadata_version 1
  @commit_timeout 5_000
  @options_schema NimbleOptions.new!(
                    root: [
                      required: true,
                      type: {:custom, __MODULE__, :validate_root, []},
                      type_doc: "absolute path (`t:String.t/0`)",
                      doc: """
                      Directory that holds the cache files. Must be an absolute path. \
                      The `cache` and `input_cache` roots must be separate, neither \
                      inside the other. Plug initialization fails otherwise.
                      """
                    ],
                    pool: [
                      type: {:in, [:input, :output]},
                      type_doc: "`:input` or `:output`",
                      doc: """
                      Tags the cache's telemetry events with `pool`, so events from an \
                      originals cache can be told apart from the processed-image cache. \
                      Defaults to `:output`, or `:input` for a cache configured as \
                      `:input_cache`.
                      """
                    ],
                    max_size_bytes: [
                      required: true,
                      type: :pos_integer,
                      doc: """
                      Cap, in bytes, on the total size of stored bodies. Writes evict \
                      rarely requested entries to stay under it.
                      """
                    ]
                  )

  @doc false
  def options_schema, do: @options_schema.schema

  @doc "Returns the supervision tree an instance runs for a filesystem cache."
  def child_spec(opts), do: Root.child_spec(opts)

  @doc false
  def root_dir(opts), do: Keyword.fetch!(opts, :root)

  @doc false
  # The processes a cache runs on a root this node owns: Admission, the
  # registry it's found in, and the periodic sweep. Admission's startup scan
  # sweeps, so the periodic sweep's first run waits an interval.
  def cache_children(opts) do
    registry_name = registry_name(Keyword.fetch!(opts, :root))
    telemetry = Keyword.take(opts, [:telemetry_prefix])
    sweep = [root_dir(opts), Keyword.get(opts, :pool, :output), telemetry]

    [
      {Registry, keys: :unique, name: registry_name},
      {Admission, admission_options(opts, registry_name)},
      {PeriodicSweep,
       id: {Sweep, Keyword.fetch!(opts, :root)}, delay_first?: true, sweep: {Sweep, :run, sweep}}
    ]
  end

  @doc false
  # The options Admission.init/1 reads, from cache options: the policy's
  # tuning derived from `:max_size_bytes`, and the registry Admission
  # registers in. Tests and benchmarks that start Admission
  # directly go through this too, and may override the tuning.
  def admission_options(opts, registry_name) do
    opts = Keyword.merge(admission_defaults(opts), opts)

    Keyword.put(opts, :registry, registry_name)
  end

  # A 1% window: docs/plans/cache-admission-policy.md found 1%, 5% and 20%
  # windows within noise.
  defp admission_defaults(opts) do
    max_size_bytes = Keyword.fetch!(opts, :max_size_bytes)

    [
      window_ratio: 0.01,
      sketch_depth: 4,
      sketch_width: max(4096, div(max_size_bytes, 25_000)),
      aging_sample_size: max(81_920, div(max_size_bytes, 5_000)),
      doorkeeper_cardinality: max(8192, div(max_size_bytes, 12_500)),
      doorkeeper_fpr: 0.01,
      reconcile_batch: 64
    ]
  end

  # Each cache root runs one Registry and Admission. Deriving the Registry
  # name from the root (rather than one global name) lets multiple
  # FileSystem caches coexist in a single VM without clashing
  # on the Registry process name. Roots are static host configuration, so the
  # set of derived atoms is bounded and not driven by request input.
  @doc false
  def registry_name(root) when is_binary(root) do
    suffix =
      :crypto.hash(:sha256, root)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Module.concat(ImagePipe.Cache.FileSystem.Registry, suffix)
  end

  def get(%Key{} = key, opts) when is_list(opts) do
    case paths(key, opts) do
      {:ok, paths} ->
        case read_entry(paths) do
          {:hit, entry, meta} ->
            # read_entry already parsed/validated the meta payload; reuse its
            # fields rather than re-reading the file.
            maybe_cast_hit(opts, %{
              key_hash: key.hash,
              size_bytes: meta.body_byte_size,
              body_sha256: meta.body_sha256,
              cost_us: Map.get(meta, :cost_us, 0)
            })

            {:hit, entry, meta}

          other ->
            other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_cast_hit(opts, descriptor) do
    case lookup_admission(opts) do
      {:ok, pid} -> Admission.hit(pid, descriptor)
      _ -> :ok
    end
  end

  def open_sink(%Key{} = key, metadata, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts),
         :ok <- File.mkdir_p(paths.dir),
         temp_body_path = temp_path(paths),
         {:ok, body_io} <- File.open(temp_body_path, [:write, :binary, :exclusive]) do
      {:ok,
       %{
         paths: paths,
         temp_body_path: temp_body_path,
         temp_meta_path: nil,
         body_io: body_io,
         size: 0,
         hash_context: :crypto.hash_init(:sha256),
         metadata: metadata
       }}
    end
  end

  def write_chunk(state, chunk, _opts) when is_binary(chunk) do
    IO.binwrite(state.body_io, chunk)

    {:ok,
     %{
       state
       | size: state.size + byte_size(chunk),
         hash_context: :crypto.hash_update(state.hash_context, chunk)
     }}
  rescue
    exception in [ErlangError] -> {:error, exception.original, state}
  catch
    :exit, reason -> {:error, reason, state}
  end

  @doc false
  # Opens a sink over a complete file the caller already hashed, hard-linking it
  # instead of copying. The caller's file keeps its own name. Linking fails
  # across filesystems, and the caller then copies the bytes into a sink.
  def open_linked_sink(%Key{} = key, metadata, path, body_sha256, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts),
         :ok <- File.mkdir_p(paths.dir),
         temp_body_path = temp_path(paths),
         :ok <- :file.make_link(path, temp_body_path) do
      case open_linked_body(temp_body_path) do
        {:ok, body_io, size} ->
          {:ok,
           %{
             paths: paths,
             temp_body_path: temp_body_path,
             temp_meta_path: nil,
             body_io: body_io,
             size: size,
             body_sha256: Base.encode16(body_sha256, case: :lower),
             metadata: metadata
           }}

        {:error, reason} ->
          cleanup_temp_files([temp_body_path])
          {:error, reason}
      end
    end
  end

  # The descriptor is kept for the datasync before the commit's rename.
  defp open_linked_body(path) do
    with {:ok, body_io} <- :file.open(path, [:read, :raw, :binary]) do
      case :file.read_file_info(body_io) do
        {:ok, info} ->
          {:ok, body_io, File.Stat.from_record(info).size}

        {:error, reason} ->
          :file.close(body_io)
          {:error, reason}
      end
    end
  end

  def commit_sink(state, opts) when is_map(state) do
    case lookup_admission(opts) do
      {:ok, pid} ->
        commit_bounded(state, pid, opts)

      :unavailable ->
        # Without Admission a write can't be counted, and an uncounted entry
        # would grow the cache past its cap. Nothing has been renamed yet, so
        # clean the temp files and fail open.
        require Logger
        Logger.warning("Admission process unavailable; skipping cache write")
        cleanup_sink_state(state)
        :ok
    end
  end

  defp commit_bounded(state, pid, opts) do
    case prepare_sink_commit(state) do
      {:ok, prepared, body_filename} ->
        admit_commit(prepared, body_filename, pid, opts)

      {:error, reason, prepared} ->
        cleanup_sink_state(prepared)
        {:error, reason}
    end
  end

  # Admission owns the prepared files once the commit is sent, and publishes or
  # removes them even after this call times out. They are left here only when
  # Admission is gone. Tests shorten the wait with `:commit_timeout`.
  defp admit_commit(prepared, body_filename, pid, opts) do
    timeout = Keyword.get(opts, :commit_timeout, @commit_timeout)

    case Admission.commit(pid, prepared, body_filename, timeout) do
      {:error, :admission_unavailable} = error ->
        cleanup_sink_state(prepared)
        error

      result ->
        result
    end
  end

  @doc false
  # Admission's descriptor of a prepared write, before it's published.
  # prepare_sink_commit/1 encodes body_sha256 into body_filename
  # ("<hash>.<sha>.body"); recover it rather than recomputing the digest.
  def descriptor(prepared, body_filename) do
    {:ok, body_sha256} = body_sha256_from_filename(body_filename)

    %{
      key_hash: prepared.paths.hash,
      size_bytes: prepared.size,
      body_sha256: body_sha256,
      cost_us: prepared.metadata.cost_us,
      body_filename: body_filename
    }
  end

  @doc false
  def publish_prepared(prepared, body_filename),
    do: commit_prepared_sink(prepared, body_filename)

  @doc false
  def discard_prepared(prepared), do: cleanup_sink_state(prepared)

  defp lookup_admission(opts) do
    root = Keyword.fetch!(opts, :root)

    case Registry.lookup(registry_name(root), root) do
      [{pid, _}] -> {:ok, pid}
      [] -> :unavailable
    end
  rescue
    # No instance runs this cache, so its Registry isn't started either.
    ArgumentError -> :unavailable
  end

  # The body reaches the disk before its rename publishes it, so a crash can't
  # leave a published body at full length with lost blocks. Hits check only
  # the size, which wouldn't catch that.
  defp prepare_sink_commit(state) do
    with :ok <- refresh_body_time(state),
         :ok <- :file.datasync(state.body_io),
         :ok <- close_body_io(state),
         body_sha256 = sink_body_sha256(state),
         body_filename = body_filename(state.paths.hash, body_sha256),
         encoded_metadata = sink_metadata(state, body_sha256, body_filename),
         {:ok, temp_meta_path} <- write_sink_metadata(state.paths, encoded_metadata) do
      prepared = state |> Map.put(:temp_meta_path, temp_meta_path) |> Map.delete(:body_io)
      {:ok, prepared, body_filename}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # A linked body can carry an old mtime. Refresh it before publication so the
  # leftover sweep leaves it alone until its metadata has been installed.
  defp refresh_body_time(%{body_sha256: _} = state),
    do: :file.change_time(state.temp_body_path, :calendar.local_time())

  defp refresh_body_time(%{hash_context: _}), do: :ok

  defp commit_prepared_sink(state, body_filename) do
    commit_sink_files(state, body_filename)
  after
    cleanup_sink_state(state)
  end

  def abort_sink(state, _opts) when is_map(state) do
    cleanup_sink_state(state)
  end

  def validate_options(opts) when is_list(opts) do
    with {:ok, validated_opts} <- validate_known_options(opts),
         :ok <- validate_representative_cache_dir(validated_opts) do
      {:ok, validated_opts}
    end
  end

  defp validate_representative_cache_dir(validated_opts) do
    root = Keyword.fetch!(validated_opts, :root)
    # Probe the directory shape every cache key will use after hash partitioning.
    validate_under_root(root, Path.join([root, "00", "00"]))
  end

  defp validate_known_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated_opts} -> {:ok, validated_opts}
      {:error, error} -> {:error, options_validation_error(error)}
    end
  end

  @doc false
  def validate_root(root) when is_binary(root) do
    if Path.type(root) == :absolute do
      {:ok, Path.expand(root)}
    else
      {:error, "expected absolute path, got: #{inspect(root)}"}
    end
  end

  def validate_root(root), do: {:error, "expected absolute path string, got: #{inspect(root)}"}

  defp options_validation_error(%NimbleOptions.ValidationError{key: unknown_keys})
       when is_list(unknown_keys),
       do: {:unknown_options, Enum.uniq(unknown_keys)}

  defp options_validation_error(%NimbleOptions.ValidationError{key: key, value: nil})
       when key in [:root, :max_size_bytes],
       do: {:missing_required_option, key}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :root, value: root}),
    do: {:invalid_root, root}

  defp options_validation_error(%NimbleOptions.ValidationError{key: key, message: message}),
    do: {:invalid_option, key, message}

  defp read_entry(paths) do
    with {:ok, metadata} <- read_metadata(paths),
         {:ok, body_path} <- body_path_from_metadata(paths, metadata),
         {:ok, file} <- CacheFile.open(body_path, metadata.body_byte_size) do
      {:hit, file, metadata}
    end
  end

  @doc false
  # Hashes the stored body against its metadata. Returns `:miss` when nothing
  # is stored, and an error for a body that differs or can't be read.
  def verify(%Key{} = key, opts) do
    with {:ok, paths} <- paths(key, opts),
         {:ok, metadata} <- read_metadata(paths),
         {:ok, body_path} <- body_path_from_metadata(paths, metadata) do
      if matching_body_file?(body_path, metadata.body_filename),
        do: :ok,
        else: {:error, {:invalid_metadata, :body_digest_mismatch}}
    end
  end

  def metadata(%Key{} = key, opts) do
    with {:ok, paths} <- paths(key, opts), do: read_metadata(paths)
  end

  # Like `get/2` for a reader that needs only the metadata: the body stays
  # closed, and the read still counts as a hit for admission.
  def metadata_hit(%Key{} = key, opts) do
    case metadata(key, opts) do
      {:ok, metadata} ->
        maybe_cast_hit(opts, %{
          key_hash: key.hash,
          size_bytes: metadata.body_byte_size,
          body_sha256: metadata.body_sha256,
          cost_us: Map.get(metadata, :cost_us, 0)
        })

        {:ok, metadata}

      other ->
        other
    end
  end

  def refresh_source_record(key, previous, record, opts) do
    with {:ok, paths} <- paths(key, opts) do
      case lookup_admission(opts) do
        {:ok, pid} -> Admission.refresh_source_record(pid, paths, previous, record)
        :unavailable -> :ok
      end
    end
  end

  def refresh_entry(paths, previous, record) do
    case read_metadata(paths) do
      {:ok, %{source_record: ^previous} = metadata} ->
        write_refreshed_metadata(paths, %{metadata | source_record: record})

      _missing_or_changed ->
        :ok
    end
  end

  defp write_refreshed_metadata(paths, metadata) do
    binary = :erlang.term_to_binary(metadata, [:deterministic])

    with {:ok, temp} <- write_sink_metadata(paths, binary) do
      result = File.rename(temp, paths.meta_path)
      File.rm(temp)
      result
    end
  end

  def delete(key, opts) do
    with {:ok, paths} <- paths(key, opts) do
      case lookup_admission(opts) do
        {:ok, pid} -> Admission.delete(pid, paths)
        :unavailable -> unwrap_delete(delete_entry(paths))
      end
    end
  end

  def delete_entry(paths) do
    with {:ok, metadata} <- read_metadata(paths),
         {:ok, path} <- body_path_from_metadata(paths, metadata),
         :ok <- File.rm(paths.meta_path) do
      {:ok, File.rm(path)}
    end
  end

  defp unwrap_delete({:ok, result}), do: result
  defp unwrap_delete(result), do: result

  defp read_metadata(paths) do
    with {:ok, binary} <- read_cache_file(paths.meta_path, :metadata), do: decode_metadata(binary)
  end

  defp read_cache_file(path, kind) do
    case :file.read_file(path, [:raw]) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, read_error(kind, reason)}
    end
  end

  defp read_error(:metadata, reason), do: {:metadata_read, reason}

  defp sink_metadata(state, body_sha256, body_filename) do
    metadata =
      Map.merge(state.metadata, %{
        metadata_version: @metadata_version,
        body_byte_size: state.size,
        body_sha256: body_sha256,
        body_filename: body_filename
      })

    :erlang.term_to_binary(metadata, [:deterministic])
  end

  defp decode_metadata(binary) do
    metadata = safe_term(binary)

    case validate_metadata(metadata) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> handle_invalid_metadata(reason)
    end
  rescue
    ArgumentError -> handle_invalid_metadata(:decode_failed)
  end

  # Stored metadata names atoms from ImagePipe's own modules, the URL
  # builder's, and libvips enums. A VM that loads code lazily (mix run, IEx)
  # may not have created them yet when it reads entries an earlier VM wrote,
  # so a refused decode loads those modules and tries once more.
  defp safe_term(binary) do
    :erlang.binary_to_term(binary, [:safe])
  rescue
    ArgumentError ->
      [:image_pipe, :image_pipe_url, :vix]
      |> Enum.flat_map(&Application.spec(&1, :modules))
      |> :code.ensure_modules_loaded()

      :erlang.binary_to_term(binary, [:safe])
  end

  defp validate_metadata(
         %{
           metadata_version: @metadata_version,
           body_byte_size: size,
           body_sha256: sha,
           body_filename: filename,
           cost_us: cost
         } = metadata
       )
       when is_integer(size) and size >= 0 and is_binary(sha) and is_binary(filename) and
              is_integer(cost) and cost >= 0,
       do: {:ok, metadata}

  defp validate_metadata(%{metadata_version: version}) when version != @metadata_version,
    do: {:error, :version_mismatch}

  defp validate_metadata(_), do: {:error, :invalid_shape}
  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp body_path_from_metadata(
         paths,
         %{body_filename: body_filename, body_sha256: body_sha256}
       ) do
    expected_body_filename = body_filename(paths.hash, body_sha256)

    if valid_body_sha256?(body_sha256) and body_filename == expected_body_filename do
      {:ok, Path.join(paths.dir, body_filename)}
    else
      handle_invalid_metadata(:invalid_body_filename)
    end
  end

  defp valid_body_sha256?(body_sha256),
    do: is_binary(body_sha256) and hex64?(body_sha256, :lower)

  defp write_sink_metadata(paths, encoded_metadata) do
    temp_path = temp_path(paths)

    case File.write(temp_path, encoded_metadata, [:binary, :exclusive]) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_sink_files(state, body_filename) do
    body_path = Path.join(state.paths.dir, body_filename)

    with :ok <- File.rename(state.temp_body_path, body_path) do
      commit_metadata_file(state.paths.meta_path, state.temp_meta_path)
    end
  end

  defp commit_metadata_file(meta_path, meta_tmp_path) do
    File.rename(meta_tmp_path, meta_path)
  end

  defp matching_body_file?(body_path, body_filename) do
    with {:ok, expected_sha256} <- body_sha256_from_filename(body_filename),
         {:ok, actual_sha256} <- file_sha256(body_path) do
      actual_sha256 == expected_sha256
    else
      _reason -> false
    end
  end

  defp file_sha256(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        sha256 =
          io
          |> IO.binstream(64 * 1024)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> finalize_body_sha256()

        {:ok, sha256}
      after
        File.close(io)
      end
    end
  end

  defp close_body_io(%{body_io: body_io}) do
    case File.close(body_io) do
      :ok -> :ok
      {:error, :terminated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:close_failed, reason}}
  end

  defp sink_body_sha256(%{body_sha256: body_sha256}), do: body_sha256
  defp sink_body_sha256(state), do: finalize_body_sha256(state.hash_context)

  defp finalize_body_sha256(hash_context) do
    hash_context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp cleanup_sink_state(%{body_io: _} = state) do
    _result = close_body_io(state)
    cleanup_sink_state(Map.delete(state, :body_io))
  end

  defp cleanup_sink_state(state),
    do: cleanup_temp_files([state.temp_body_path, state.temp_meta_path])

  defp cleanup_temp_files(temp_paths) do
    temp_paths
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&File.rm/1)
  end

  @doc false
  def paths(%Key{hash: hash}, opts), do: paths_from_hash(hash, opts)

  @doc false
  # The options were validated with the cache configuration.
  def paths_from_hash(hash, opts) when is_binary(hash) and is_list(opts) do
    root = Keyword.fetch!(opts, :root)

    with {:ok, {first_partition, second_partition}} <- partitions(hash) do
      dir = Path.join([root, first_partition, second_partition])
      meta_path = Path.join(dir, hash <> ".meta")

      with :ok <- checked_partition(root, dir) do
        {:ok, %{root: root, dir: dir, meta_path: meta_path, hash: hash}}
      end
    end
  end

  @doc false
  @spec read_descriptor(Path.t()) ::
          {:ok,
           %{
             key_hash: binary(),
             size_bytes: non_neg_integer(),
             body_sha256: binary(),
             cost_us: non_neg_integer()
           }, integer()}
          | {:error, term()}
  def read_descriptor(meta_path) do
    with {:ok, meta_binary} <- read_cache_file(meta_path, :metadata),
         {:ok, metadata} <- decode_metadata(meta_binary),
         {:ok, info} <- :file.read_file_info(meta_path, [:raw, time: :posix]) do
      %File.Stat{mtime: mtime} = File.Stat.from_record(info)

      {:ok,
       %{
         key_hash: Path.basename(meta_path, ".meta"),
         size_bytes: metadata.body_byte_size,
         body_sha256: metadata.body_sha256,
         cost_us: metadata.cost_us
       }, mtime}
    else
      :miss -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  @doc false
  def delete_victims([], _opts), do: :ok

  def delete_victims(victims, opts) do
    Enum.each(victims, fn victim ->
      with {:ok, victim_paths} <- paths_from_hash(victim.key_hash, opts) do
        delete_victim_files(victim, victim_paths)
      end
    end)
  end

  defp delete_victim_files(victim, victim_paths) do
    if victim.delete_body? do
      body_path = Path.join(victim_paths.dir, "#{victim.key_hash}.#{victim.body_sha256}.body")
      rm_tolerant(body_path)
    end

    if victim.delete_meta?, do: rm_tolerant(victim_paths.meta_path)
  end

  defp rm_tolerant(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        log_delete_failure(reason)
    end
  end

  # Path omitted: victim body/meta filenames embed the cache key hash (a
  # cache-adapter internal). Log the reason only.
  defp log_delete_failure(reason) do
    require Logger
    Logger.warning("cache: victim delete failed: reason=#{inspect(reason)}")
    :ok
  end

  defp partitions(hash) do
    if hex64?(hash, :any) do
      do_partitions(hash)
    else
      {:error, {:invalid_hash, hash}}
    end
  end

  defp do_partitions(hash) do
    <<first::binary-size(2), second::binary-size(2), _rest::binary>> = hash
    {:ok, {first, second}}
  end

  defp checked_partition(root, dir) do
    case CheckedDirs.checked?(dir) do
      true ->
        :ok

      false ->
        with :ok <- validate_under_root(root, dir), do: CheckedDirs.put(dir)
    end
  end

  defp validate_under_root(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    relative = Path.relative_to(path, root, force: true)

    # Symlinks resolve against root. A plain prefix check would allow a
    # partition directory symlink to point outside the cache root.
    case SafePath.relative(relative, root) do
      {:ok, _relative} -> :ok
      :error -> {:error, {:path_outside_root, path}}
    end
  end

  defp body_filename(hash, body_sha256), do: "#{hash}.#{body_sha256}.body"

  defp body_sha256_from_filename(body_filename) do
    case String.split(body_filename, ".", parts: 3) do
      [_hash, body_sha256, "body"] ->
        if valid_body_sha256?(body_sha256) do
          {:ok, body_sha256}
        else
          {:error, :invalid_body_filename}
        end

      _parts ->
        {:error, :invalid_body_filename}
    end
  end

  defp temp_path(paths) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Path.join(paths.dir, ".#{paths.hash}.#{random}.tmp")
  end

  # 64 hex digits, scanned because OTP 28 and later rebuild a regex at every
  # use. Body digests are lowercase.
  defp hex64?(string, letters) when byte_size(string) == 64, do: hex?(string, letters)
  defp hex64?(_string, _letters), do: false

  defp hex?(<<>>, _letters), do: true

  defp hex?(<<char, rest::binary>>, letters) do
    (char in ?0..?9 or char in ?a..?f or (letters == :any and char in ?A..?F)) and
      hex?(rest, letters)
  end
end
