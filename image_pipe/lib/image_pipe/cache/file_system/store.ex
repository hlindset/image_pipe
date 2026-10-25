defmodule ImagePipe.Cache.FileSystem.Store do
  @moduledoc false
  @dialyzer :no_match

  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.CheckedDirs
  alias ImagePipe.Cache.FileSystem.Memo
  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.Cache.FileSystem.Root
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Key
  alias ImagePipe.RawFile
  alias ImagePipe.SafePath

  # Bump for every change to the stored metadata's shape, including the
  # `ImagePipe.Debug.Info` it can hold (see AGENTS.md). An entry stored under
  # another version is a miss. The sweep checks that stored metadata decodes
  # only when this differs from the version recorded at the cache root, so a
  # shape change without a bump leaves entries it can't read in the cache.
  @metadata_version 2
  @commit_timeout 5_000
  @usage_timeout 1_000
  @options_schema NimbleOptions.new!(
                    root: [
                      required: true,
                      type: {:custom, __MODULE__, :validate_root, []},
                      type_doc: "absolute path (`t:String.t/0`)",
                      doc: """
                      Directory that holds the cache files. Must be an absolute path. \
                      An instance whose root another instance in the VM already uses \
                      raises `ArgumentError` when it starts.
                      """
                    ],
                    max_size_bytes: [
                      required: true,
                      type: :pos_integer,
                      doc: """
                      Cap, in bytes, on the disk the stored entries take. Each entry \
                      counts its body rounded up to whole 4 KiB blocks, plus a block for \
                      its metadata file. Writes evict the entries least worth keeping \
                      to stay under it: those requested least often and quickest to \
                      make for their size. An entry larger than a twentieth of the cap, \
                      or 256 MiB, is never stored.
                      """
                    ],
                    max_remembered_entries: [
                      type: :pos_integer,
                      doc: """
                      How many recently served entries the cache keeps in memory, so a \
                      repeated hit reads only the body file. Defaults to one for each \
                      50 KB of `max_size_bytes`, at least 1,000 and at most 50,000.
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
  # registry it's found in, the writers, and the periodic sweep. Admission's
  # startup scan sweeps, so the periodic sweep's first run waits an interval.
  def cache_children(opts) do
    registry_name = registry_name(Keyword.fetch!(opts, :root))
    telemetry = Keyword.take(opts, [:telemetry_prefix])
    sweep = [root_dir(opts), :output, telemetry, registry_name]

    [
      {Registry, keys: :unique, name: registry_name},
      {Admission, admission_options(opts, registry_name)},
      {Writers, opts},
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

  defp admission_defaults(opts) do
    max_size_bytes = Keyword.fetch!(opts, :max_size_bytes)

    [
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

  # `sighting?: false` reads without counting a hit for admission, for a
  # request that already counted when it missed.
  # `remembered?: false` reads the metadata from disk even when it's in
  # memory, for a request that needs the debug facts the memory leaves out.
  # `decode` builds the entry, without its body, from stored metadata.
  def get(%Key{} = key, opts, sighting?, remembered?, decode) when is_list(opts) do
    case paths(key, opts) do
      {:ok, paths} ->
        case read_entry(paths, remembered?, decode) do
          {:hit, entry, hit} ->
            sight_hit(sighting?, opts, key, hit)
            {:hit, entry}

          other ->
            other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp sight_hit(false, _opts, _key, _metadata), do: :ok

  defp sight_hit(true, opts, key, metadata),
    do: maybe_cast_hit(opts, hit_descriptor(key, metadata))

  defp hit_descriptor(key, metadata),
    do: %{
      key_hash: key.hash,
      size_bytes: metadata.body_byte_size,
      cost_us: metadata.cost_us,
      body_filename: metadata.body_filename
    }

  # A request missed `key`, so admission counts it as a sighting.
  def miss(%Key{} = key, opts) do
    case lookup_admission(opts) do
      {:ok, pid} -> Admission.miss(pid, key.hash)
      _ -> :ok
    end
  end

  defp maybe_cast_hit(opts, descriptor) do
    case lookup_admission(opts) do
      {:ok, pid} -> Admission.hit(pid, descriptor)
      _ -> :ok
    end
  end

  # The body is a raw file, so only the process that opens the sink can
  # write, sync and close it: the cache's writer, or a test.
  def open_sink(%Key{} = key, metadata, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts),
         temp_body_path = temp_path(paths),
         {:ok, body_io} <-
           in_partition(paths, fn ->
             :file.open(temp_body_path, [:write, :binary, :exclusive, :raw])
           end) do
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
    case :file.write(state.body_io, chunk) do
      :ok ->
        {:ok,
         %{
           state
           | size: state.size + byte_size(chunk),
             hash_context: :crypto.hash_update(state.hash_context, chunk)
         }}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def commit_sink(state, opts) when is_map(state) do
    case lookup_admission(opts) do
      {:ok, pid} ->
        commit_bounded(state, pid, opts)

      :unavailable ->
        # Without Admission a write can't be counted, and an uncounted entry
        # would grow the cache past its cap. Nothing has been renamed yet, so
        # clean the temp files and report the write as failed.
        cleanup_sink_state(state)
        {:error, :admission_unavailable}
    end
  end

  # Admission decides once the body is written, before it's synced, so a
  # rejected body is deleted without reaching the disk. Tests shorten the
  # commit's wait with `:commit_timeout`.
  defp commit_bounded(state, pid, opts) do
    timeout = Keyword.get(opts, :commit_timeout, @commit_timeout)
    body_sha256 = sink_body_sha256(state)

    body_filename =
      body_filename(state.paths.hash, body_sha256, state.size, cost_us(state.metadata))

    held = Writers.held()

    case Admission.decide(pid, body_filename, held, @commit_timeout) do
      {:admit, victims} ->
        commit_admitted(state, {body_sha256, body_filename, held, victims}, pid, timeout)

      {:reject, _reason} ->
        cleanup_sink_state(state)
        {:ok, :rejected}

      {:error, _reason} = error ->
        cleanup_sink_state(state)
        error
    end
  end

  defp commit_admitted(state, {body_sha256, body_filename, held, victims}, pid, timeout) do
    case prepare_sink_commit(state, body_sha256, body_filename) do
      {:ok, prepared} ->
        prepared = Map.merge(prepared, %{held: held, victims: victims})
        admit_commit(prepared, body_filename, pid, timeout)

      {:error, reason, prepared} ->
        cleanup_sink_state(prepared)
        {:error, reason}
    end
  end

  # Admission owns the prepared files once the commit is sent, and publishes or
  # removes them even after this call times out. They are left here only when
  # Admission is gone.
  defp admit_commit(prepared, body_filename, pid, timeout) do
    case Admission.commit(pid, prepared, body_filename, timeout) do
      {:error, :admission_unavailable} = error ->
        cleanup_sink_state(prepared)
        error

      result ->
        result
    end
  end

  @doc false
  # Admission's descriptor of a prepared write, before it's published, read
  # back from the body filename commit_bounded/3 built.
  def descriptor(_prepared, body_filename) do
    {:ok, descriptor} = parse_body_filename(body_filename)
    descriptor
  end

  @doc false
  def publish_prepared(prepared, body_filename),
    do: commit_prepared_sink(prepared, body_filename)

  @doc false
  def discard_prepared(prepared), do: cleanup_sink_state(prepared)

  @doc false
  # Admission can be busy or restarting, so a stats caller gets no usage for
  # that cache rather than an exit. It waits less than a scrape usually does.
  def usage(opts) do
    with {:ok, pid} <- lookup_admission(opts), do: {:ok, Admission.usage(pid, @usage_timeout)}
  catch
    :exit, _reason -> {:error, :admission_unavailable}
  end

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
  defp prepare_sink_commit(state, body_sha256, body_filename) do
    with :ok <- :file.datasync(state.body_io),
         :ok <- close_body_io(state),
         encoded_metadata = sink_metadata(state, body_sha256, body_filename),
         {:ok, temp_meta_path} <- write_sink_metadata(state.paths, encoded_metadata) do
      prepared = state |> Map.put(:temp_meta_path, temp_meta_path) |> Map.delete(:body_io)
      {:ok, prepared}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp commit_prepared_sink(state, body_filename) do
    case commit_sink_files(state, body_filename) do
      :ok ->
        :ok

      error ->
        cleanup_sink_state(state)
        error
    end
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

  # A hit reads the entry from the memo when it's there: the decoded entry,
  # without its debug facts, and the body file's name, size, and cost. The
  # body is stat'ed rather than opened, since delivery sends it by path. A
  # remembered entry whose body is gone or changed is read again from disk,
  # so the memo never turns a hit into anything a read from disk wouldn't.
  defp read_entry(paths, false, decode), do: read_stored(paths, decode)

  defp read_entry(paths, true, decode) do
    case Memo.get(paths.root, paths.hash) do
      {entry, hit} -> read_remembered(paths, decode, entry, hit)
      nil -> read_stored(paths, decode)
    end
  end

  defp read_remembered(paths, decode, entry, hit) do
    path = Path.join(paths.dir, hit.body_filename)

    case CacheFile.remembered(path, hit.body_byte_size, paths.root, paths.hash) do
      {:ok, file} ->
        {:hit, %{entry | body: file}, hit}

      :gone ->
        Memo.drop(paths.root, paths.hash)
        read_stored(paths, decode)
    end
  end

  defp read_stored(paths, decode) do
    epoch = Memo.epoch(paths.root, paths.hash)

    with {:ok, metadata} <- read_metadata(paths),
         {:ok, body_path} <- body_path_from_metadata(paths, metadata),
         {:ok, entry} <- decode.(metadata),
         {:ok, file} <- CacheFile.open(body_path, metadata.body_byte_size) do
      hit = Map.take(metadata, [:body_filename, :body_byte_size, :cost_us])
      Memo.remember(paths.root, paths.hash, epoch, {%{entry | debug: nil}, hit})
      {:hit, %{entry | body: file}, hit}
    end
  end

  def metadata(%Key{} = key, opts) do
    with {:ok, paths} <- paths(key, opts), do: read_metadata(paths)
  end

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
              is_integer(cost) and cost >= 0 do
    case parse_body_filename(filename) do
      {:ok, %{body_sha256: ^sha, size_bytes: ^size, cost_us: ^cost}} -> {:ok, metadata}
      _other -> {:error, :invalid_body_filename}
    end
  end

  defp validate_metadata(%{metadata_version: version}) when version != @metadata_version,
    do: {:error, :version_mismatch}

  defp validate_metadata(_), do: {:error, :invalid_shape}
  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp body_path_from_metadata(
         paths,
         %{body_filename: body_filename, body_sha256: body_sha256} = metadata
       ) do
    expected_body_filename =
      body_filename(paths.hash, body_sha256, metadata.body_byte_size, metadata.cost_us)

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

    case :file.write_file(temp_path, encoded_metadata, [:raw, :binary, :exclusive]) do
      :ok ->
        {:ok, temp_path}

      # A failed write leaves a partial file behind.
      {:error, _reason} = error ->
        RawFile.delete(temp_path)
        error
    end
  end

  defp commit_sink_files(state, body_filename) do
    body_path = Path.join(state.paths.dir, body_filename)

    with :ok <- RawFile.rename(state.temp_body_path, body_path) do
      commit_metadata_file(state.paths.meta_path, state.temp_meta_path)
    end
  end

  defp cost_us(metadata), do: Map.get(metadata, :cost_us, 0)

  defp commit_metadata_file(meta_path, meta_tmp_path) do
    RawFile.rename(meta_tmp_path, meta_path)
  end

  defp close_body_io(%{body_io: body_io}), do: :file.close(body_io)

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
    |> Enum.each(&RawFile.delete/1)
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
             cost_us: non_neg_integer(),
             body_filename: String.t()
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
         cost_us: metadata.cost_us,
         body_filename: metadata.body_filename
       }, mtime}
    else
      :miss -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  @doc false
  # Whether the metadata file at `meta_path` reads but doesn't decode. Unlike
  # read_descriptor/1 it doesn't stat the file, since a sweep that checks
  # every metadata file spends most of its time on these calls.
  def undecodable?(meta_path) do
    with {:ok, meta_binary} <- read_cache_file(meta_path, :metadata),
         {:error, {:invalid_metadata, _reason}} <- decode_metadata(meta_binary) do
      true
    else
      _decoded_missing_or_failed -> false
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
    rm_tolerant(Path.join(victim_paths.dir, victim.body_filename))

    if victim.delete_meta?, do: rm_tolerant(victim_paths.meta_path)
  end

  defp rm_tolerant(path) do
    case RawFile.delete(path) do
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

  @doc false
  def metadata_version, do: @metadata_version

  @doc false
  # A body's filename carries what Admission needs to count and score the
  # entry, so its startup scan lists names instead of reading metadata.
  def body_filename(hash, body_sha256, size, cost),
    do: "#{hash}.#{body_sha256}.#{size}.#{cost}.body"

  @doc false
  def parse_body_filename(body_filename) do
    case body_parts(body_filename) do
      {:ok, hash, body_sha256, {_raw_hash, size, cost, _raw_sha256}} ->
        {:ok,
         %{
           key_hash: hash,
           body_sha256: body_sha256,
           size_bytes: size,
           cost_us: cost,
           body_filename: body_filename
         }}

      :error ->
        {:error, :invalid_body_filename}
    end
  end

  @doc false
  # The row Admission keeps for a body: `{key hash, size, cost, body
  # SHA-256}`, with both hashes as raw 32-byte binaries.
  def body_row(body_filename) do
    case body_parts(body_filename) do
      {:ok, _hash, _body_sha256, row} -> {:ok, row}
      :error -> :error
    end
  end

  @doc false
  # What a file in a partition directory is, by its name: a body with its
  # key hash and row, a metadata file with its key hash, a temp file, or
  # none of these. Bodies stored before their names carried size and cost
  # end at the digest, and have no row.
  def classify(<<hash::binary-size(64), ".meta">>) do
    if hex64?(hash, :lower), do: {:meta, hash}, else: :unrelated
  end

  def classify(<<?., hash::binary-size(64), ?., rest::binary>>) do
    if hex64?(hash, :lower) and temp_suffix?(rest), do: :temp, else: :unrelated
  end

  def classify(<<hash::binary-size(64), ?., body_sha256::binary-size(64), ".body">>) do
    if hex64?(hash, :lower) and hex64?(body_sha256, :lower),
      do: {:body, hash, nil},
      else: :unrelated
  end

  def classify(name) do
    case body_parts(name) do
      {:ok, hash, _body_sha256, row} -> {:body, hash, row}
      :error -> :unrelated
    end
  end

  # The hashes are matched by position, and decoding them checks they are
  # lowercase hex.
  defp body_parts(<<hash::binary-size(64), ?., body_sha256::binary-size(64), ?., rest::binary>>) do
    with {:ok, raw_hash} <- Base.decode16(hash, case: :lower),
         {:ok, raw_sha256} <- Base.decode16(body_sha256, case: :lower),
         {size, <<?., rest::binary>>} <- digits(rest),
         {cost, ".body"} <- digits(rest) do
      {:ok, hash, body_sha256, {raw_hash, size, cost, raw_sha256}}
    else
      _invalid -> :error
    end
  end

  defp body_parts(_name), do: :error

  # Digits only: a sign would let a planted name count negative bytes.
  defp digits(<<digit, rest::binary>>) when digit in ?0..?9, do: digits(rest, digit - ?0)
  defp digits(_string), do: :error

  defp digits(<<digit, rest::binary>>, integer) when digit in ?0..?9,
    do: digits(rest, integer * 10 + digit - ?0)

  defp digits(rest, integer), do: {integer, rest}

  # The random part temp_path/1 writes: URL-safe Base64.
  defp temp_suffix?(<<".tmp">>), do: false
  defp temp_suffix?(rest), do: temp_random?(rest)

  defp temp_random?(<<".tmp">>), do: true

  defp temp_random?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-],
       do: temp_random?(rest)

  defp temp_random?(_rest), do: false

  # Creates the partition directory only when `fun` finds it missing, so a
  # write into an existing partition makes no directory calls.
  defp in_partition(paths, fun) do
    case fun.() do
      {:error, :enoent} ->
        with :ok <- RawFile.make_dir_p(paths.dir), do: fun.()

      result ->
        result
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
