defmodule ImagePipe.Cache.FileSystem do
  @moduledoc """
  Filesystem-backed cache adapter for processed image responses.
  """

  # Dialyzer over-narrows `validate_metadata_headers/1`'s `Enum.all?(.., &valid_metadata_header?/1)`
  # to always-true and flags the `{:error, :invalid_headers}` branch as dead — but
  # that branch validates headers decoded from external cache storage (a boundary
  # Dialyzer can't see needs the check). It reports the warning unattributed
  # (line 1), so suppression must be module-scoped.
  @dialyzer :no_match

  @behaviour ImagePipe.Cache

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key
  alias ImagePipe.Debug.Info

  @metadata_version 1
  @cache_key_hash_pattern ~r/\A[0-9A-Fa-f]{64}\z/
  @body_sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @option_keys [:root, :path_prefix]
  # Bounded-mode options: exhaustive list of all bounded-mode keys so that
  # validate_unknown_options/1 accepts them. Kept in sync with @options_schema.
  @bounded_option_keys [
    :max_size_bytes,
    :node_id,
    :state_dir,
    :window_ratio,
    :sketch_depth,
    :sketch_width,
    :doorkeeper_cardinality,
    :doorkeeper_fpr,
    :eviction_victim_limit,
    :aging_sample_size,
    :reconcile_interval,
    :flush_interval,
    :cleanup_interval,
    :state_ttl
  ]
  @options_schema NimbleOptions.new!(
                    root: [
                      required: true,
                      type: {:custom, __MODULE__, :validate_root, []}
                    ],
                    path_prefix: [
                      default: "",
                      type: {:custom, __MODULE__, :validate_path_prefix, []}
                    ],
                    # Bounded-mode options — all optional at the per-key level;
                    # cross-key requirements and derivation are enforced in
                    # derive_bounded_options/1 after per-key validation.
                    max_size_bytes: [
                      type: :pos_integer
                    ],
                    node_id: [
                      type: :string
                    ],
                    state_dir: [
                      type: :string
                    ],
                    window_ratio: [
                      type: {:custom, __MODULE__, :validate_window_ratio, []}
                    ],
                    sketch_depth: [
                      type: :pos_integer
                    ],
                    sketch_width: [
                      type: :pos_integer
                    ],
                    aging_sample_size: [
                      type: :pos_integer
                    ],
                    doorkeeper_cardinality: [
                      type: :pos_integer
                    ],
                    doorkeeper_fpr: [
                      type: {:custom, __MODULE__, :validate_doorkeeper_fpr, []}
                    ],
                    eviction_victim_limit: [
                      type: :pos_integer
                    ],
                    flush_interval: [
                      type: :pos_integer
                    ],
                    cleanup_interval: [
                      type: :pos_integer
                    ],
                    reconcile_interval: [
                      type: :pos_integer
                    ],
                    state_ttl: [
                      type: :pos_integer
                    ]
                  )

  @doc false
  def child_spec(opts) do
    if Keyword.has_key?(opts, :max_size_bytes) do
      registry_name = registry_name(Keyword.fetch!(opts, :root))
      derived = derive_bounded_options(opts)
      admission_opts = translate_to_admission_opts(derived, registry_name)

      children = [
        {Registry, keys: :unique, name: registry_name},
        {Admission, admission_opts}
      ]

      %{
        id: {__MODULE__, Keyword.fetch!(opts, :root)},
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      }
    else
      :ignore
    end
  end

  # Translate validated+derived seconds-based opts into the millisecond keys
  # that Admission.init/1 reads, and inject the registry name.
  defp translate_to_admission_opts(opts, registry_name) do
    opts
    |> Keyword.put(:registry, registry_name)
    |> Keyword.put(:flush_interval_ms, Keyword.fetch!(opts, :flush_interval) * 1000)
    |> Keyword.put(:cleanup_interval_ms, Keyword.fetch!(opts, :cleanup_interval) * 1000)
    |> Keyword.put(:reconcile_interval_ms, Keyword.fetch!(opts, :reconcile_interval) * 1000)
    |> Keyword.put(:state_ttl_ms, Keyword.fetch!(opts, :state_ttl) * 1000)
    |> Keyword.delete(:flush_interval)
    |> Keyword.delete(:cleanup_interval)
    |> Keyword.delete(:reconcile_interval)
    |> Keyword.delete(:state_ttl)
  end

  # Bounded mode runs one Registry + Admission supervisor per cache root.
  # Deriving the Registry name from the root (rather than one global name) lets
  # multiple bounded FileSystem caches coexist in a single VM without clashing
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

  @impl true
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

            {:hit, entry}

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

  @impl true
  def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, opts) when is_list(opts) do
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

  @impl true
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

  @impl true
  def commit_sink(state, opts) when is_map(state) do
    case lookup_admission(opts) do
      :unbounded ->
        legacy_commit(state)

      {:ok, pid} ->
        commit_bounded(state, pid, opts)

      :unavailable ->
        # Bounded mode but the Admission process is missing. We cannot account
        # for a write, so we MUST NOT leave an untracked entry on disk (it
        # would silently grow the cache past cap). Nothing has been renamed
        # yet, so clean the temp files and fail open.
        require Logger
        Logger.warning("Admission process unavailable in bounded mode; skipping write")
        cleanup_sink_state(state)
        :ok
    end
  end

  # The existing unbounded commit body, unchanged, extracted under a name.
  defp legacy_commit(state) do
    case prepare_sink_commit(state) do
      {:ok, state, body_filename} ->
        commit_prepared_sink(state, body_filename)

      {:error, reason, state} ->
        cleanup_sink_state(state)
        {:error, reason}
    end
  end

  defp commit_bounded(state, pid, opts) do
    # Write to the final location FIRST, then account. admit/2 mutates
    # Admission's in-memory queues the moment it returns, so calling it before a
    # successful rename would track a phantom entry and orphan evicted victims.
    case prepare_sink_commit(state) do
      {:ok, prepared, body_filename} ->
        case commit_sink_files(prepared, body_filename) do
          :ok ->
            finish_admission(pid, build_descriptor(prepared, body_filename), opts)

          {:error, reason} ->
            cleanup_sink_state(prepared)
            {:error, reason}
        end

      {:error, reason, prepared} ->
        cleanup_sink_state(prepared)
        {:error, reason}
    end
  end

  defp finish_admission(pid, descriptor, opts) do
    case Admission.admit(pid, descriptor) do
      {:admit, victims} ->
        delete_victims(victims, opts)
        :ok

      {:reject, _reason} ->
        # Admission declined to keep the entry. It was never inserted into the
        # queues (reject mutates nothing), so the only cleanup is the bytes we
        # just wrote. Delete both body and meta so on-disk state stays
        # consistent with Admission's accounting. Signal rejection so the Sink
        # records the request-path outcome (`cache: :admission_rejected` on the
        # `[:cache, :write]` span) instead of a plain successful write.
        delete_victims([reject_victim(descriptor)], opts)
        {:ok, :rejected}
    end
  end

  # Build the full-eviction victim shape delete_victims/2 consumes for a
  # descriptor whose write must be undone.
  defp reject_victim(descriptor) do
    %{
      key_hash: descriptor.key_hash,
      body_sha256: descriptor.body_sha256,
      size_bytes: descriptor.size_bytes,
      delete_body?: true,
      delete_meta?: true
    }
  end

  # prepare_sink_commit/1 encodes body_sha256 into body_filename
  # ("<hash>.<sha>.body"); recover it rather than recomputing the digest.
  defp build_descriptor(prepared, body_filename) do
    {:ok, body_sha256} = body_sha256_from_filename(body_filename)

    %{
      key_hash: prepared.paths.hash,
      size_bytes: prepared.size,
      body_sha256: body_sha256,
      cost_us: prepared.metadata.cost_us
    }
  end

  defp lookup_admission(opts) do
    if Keyword.has_key?(opts, :max_size_bytes) do
      root = Keyword.fetch!(opts, :root)
      registry_key = {root, Keyword.fetch!(opts, :node_id)}

      try do
        case Registry.lookup(registry_name(root), registry_key) do
          [{pid, _}] -> {:ok, pid}
          [] -> :unavailable
        end
      rescue
        # The Registry itself is not started (bounded mode configured but the
        # supervision tree never came up). Fail closed, same as a missing entry.
        ArgumentError -> :unavailable
      end
    else
      :unbounded
    end
  end

  defp prepare_sink_commit(state) do
    with :ok <- close_body_io(state),
         body_sha256 = finalize_body_sha256(state.hash_context),
         body_filename = body_filename(state.paths.hash, body_sha256),
         encoded_metadata = sink_metadata(state, body_sha256, body_filename),
         {:ok, temp_meta_path} <- write_sink_metadata(state.paths, encoded_metadata) do
      {:ok, %{state | temp_meta_path: temp_meta_path}, body_filename}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp commit_prepared_sink(state, body_filename) do
    case commit_sink_files(state, body_filename) do
      :ok ->
        :ok

      {:error, reason} ->
        cleanup_sink_state(state)
        {:error, reason}
    end
  end

  @impl true
  def abort_sink(state, _opts) when is_map(state) do
    cleanup_sink_state(state)
  end

  @impl true
  def validate_options(opts) when is_list(opts) do
    with {:ok, validated_opts} <- validate_filesystem_options(opts),
         {:ok, derived_opts} <- apply_bounded_validation(validated_opts),
         :ok <- validate_representative_cache_dir(derived_opts) do
      {:ok, derived_opts}
    end
  end

  defp validate_representative_cache_dir(validated_opts) do
    root = Keyword.fetch!(validated_opts, :root)
    path_prefix = Keyword.fetch!(validated_opts, :path_prefix)
    # Probe the directory shape every cache key will use after hash partitioning.
    dir = Path.join([root, path_prefix, "00", "00"])

    validate_under_root(root, dir)
  end

  defp validate_filesystem_options(opts) do
    with :ok <- validate_unknown_options(opts) do
      validate_known_options(opts)
    end
  end

  # If max_size_bytes is present, enforce bounded-mode cross-key requirements
  # (node_id required, no stray bounded opts without max_size_bytes) and fill
  # derived defaults. If absent, return opts unchanged (unbounded mode).
  defp apply_bounded_validation(opts) do
    if Keyword.has_key?(opts, :max_size_bytes) do
      with :ok <- require_node_id(opts) do
        {:ok, derive_bounded_options(opts)}
      end
    else
      bounded_only_keys = @bounded_option_keys -- [:max_size_bytes]

      case Enum.filter(bounded_only_keys, &Keyword.has_key?(opts, &1)) do
        [] -> {:ok, opts}
        stray_keys -> {:error, {:bounded_options_require_max_size_bytes, stray_keys}}
      end
    end
  end

  defp require_node_id(opts) do
    case Keyword.fetch(opts, :node_id) do
      {:ok, _} -> :ok
      :error -> {:error, {:missing_required_bounded_option, :node_id}}
    end
  end

  # Fill derived defaults for bounded-mode opts. User-supplied values are
  # treated as overrides and are never clobbered.
  defp derive_bounded_options(opts) do
    max_size_bytes = Keyword.fetch!(opts, :max_size_bytes)
    root = Keyword.fetch!(opts, :root)

    defaults = [
      window_ratio: 0.01,
      sketch_depth: 4,
      sketch_width: max(4096, div(max_size_bytes, 25_000)),
      aging_sample_size: max(81_920, div(max_size_bytes, 5_000)),
      doorkeeper_cardinality: max(8192, div(max_size_bytes, 12_500)),
      doorkeeper_fpr: 0.01,
      eviction_victim_limit: 64,
      flush_interval: 30,
      cleanup_interval: 3600,
      reconcile_interval: 60,
      state_ttl: 604_800,
      state_dir: Path.join(root, ".cache_state")
    ]

    Keyword.merge(defaults, opts)
  end

  defp validate_known_options(opts) do
    all_known_keys = @option_keys ++ @bounded_option_keys

    case NimbleOptions.validate(Keyword.take(opts, all_known_keys), @options_schema) do
      {:ok, validated_opts} -> {:ok, validated_opts}
      {:error, error} -> {:error, options_validation_error(error)}
    end
  end

  defp validate_unknown_options(opts) do
    known_option_keys =
      @option_keys ++ @bounded_option_keys ++ ImagePipe.Cache.shared_option_keys()

    case Keyword.keys(opts) -- known_option_keys do
      [] -> :ok
      unknown_keys -> {:error, {:unknown_options, Enum.uniq(unknown_keys)}}
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

  @doc false
  def validate_path_prefix(""), do: {:ok, ""}

  def validate_path_prefix(prefix) when is_binary(prefix) do
    invalid_segment? =
      prefix
      |> String.split("/", trim: false)
      |> Enum.any?(fn segment ->
        segment in ["", ".", ".."]
      end)

    if Path.type(prefix) == :relative and not String.contains?(prefix, "\\") and
         not invalid_segment? do
      {:ok, prefix}
    else
      {:error, "expected relative path without traversal, got: #{inspect(prefix)}"}
    end
  end

  def validate_path_prefix(prefix),
    do: {:error, "expected relative path string, got: #{inspect(prefix)}"}

  @doc false
  # window_ratio carves the byte budget for the window LRU; an out-of-range
  # value would size the window past (or below) the total cap and break the
  # soft-cap invariant. Inclusive [0.0, 1.0] (0.0 disables the window).
  def validate_window_ratio(ratio) when is_float(ratio) and ratio >= 0.0 and ratio <= 1.0,
    do: {:ok, ratio}

  def validate_window_ratio(ratio),
    do: {:error, "expected float in [0.0, 1.0], got: #{inspect(ratio)}"}

  @doc false
  # doorkeeper_fpr is a Bloom-filter false-positive probability; 0.0 and 1.0
  # are degenerate, so the open interval (0.0, 1.0) is required.
  def validate_doorkeeper_fpr(fpr) when is_float(fpr) and fpr > 0.0 and fpr < 1.0,
    do: {:ok, fpr}

  def validate_doorkeeper_fpr(fpr),
    do: {:error, "expected float in (0.0, 1.0), got: #{inspect(fpr)}"}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :root, value: nil}),
    do: {:missing_required_option, :root}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :root, value: root}),
    do: {:invalid_root, root}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :path_prefix, value: prefix}),
    do: {:invalid_path_prefix, prefix}

  defp options_validation_error(%NimbleOptions.ValidationError{key: key, message: message}),
    do: {:invalid_option, key, message}

  defp read_entry(paths) do
    with {:ok, meta_binary} <- read_cache_file(paths.meta_path, :metadata),
         {:ok, metadata} <- decode_metadata(meta_binary),
         {:ok, body_path} <- body_path_from_metadata(paths, metadata),
         {:ok, body} <- read_cache_file(body_path, :body),
         # Cache hits trust metadata plus byte size without recomputing the body
         # digest. That keeps reads compatible with the future streaming hit path.
         :ok <- validate_body_size(body, metadata),
         {:ok, created_at} <- parse_created_at(metadata.created_at) do
      {:hit,
       %Entry{
         body: body,
         content_type: metadata.content_type,
         headers: metadata.headers,
         created_at: created_at,
         debug: metadata.debug
       }, metadata}
    end
  end

  defp read_cache_file(path, kind) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, read_error(kind, reason)}
    end
  end

  defp read_error(:metadata, reason), do: {:metadata_read, reason}
  defp read_error(:body, reason), do: {:body_read, reason}

  defp validate_body_size(body, %{body_byte_size: body_byte_size})
       when byte_size(body) == body_byte_size,
       do: :ok

  defp validate_body_size(_body, _metadata), do: handle_invalid_metadata(:body_byte_size_mismatch)

  defp sink_metadata(state, body_sha256, body_filename) do
    metadata = %{
      metadata_version: @metadata_version,
      content_type: state.metadata.content_type,
      headers: state.metadata.headers,
      created_at: DateTime.to_iso8601(state.metadata.created_at),
      body_byte_size: state.size,
      body_sha256: body_sha256,
      body_filename: body_filename,
      cost_us: state.metadata.cost_us,
      debug: state.metadata.debug
    }

    :erlang.term_to_binary(metadata, [:deterministic])
  end

  defp decode_metadata(binary) do
    metadata = :erlang.binary_to_term(binary, [:safe])

    case validate_metadata(metadata) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> handle_invalid_metadata(reason)
    end
  rescue
    ArgumentError -> handle_invalid_metadata(:decode_failed)
  end

  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) and is_integer(cost_us) and cost_us >= 0 do
    with :ok <- validate_metadata_debug(debug),
         :ok <- validate_metadata_content_type(content_type),
         :ok <- validate_metadata_headers(headers) do
      {:ok,
       %{
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us,
         debug: debug
       }}
    end
  end

  defp validate_metadata(%{metadata_version: _version}), do: {:error, :version_mismatch}
  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp validate_metadata_debug(debug) when is_struct(debug, Info) or is_nil(debug), do: :ok
  defp validate_metadata_debug(_debug), do: {:error, :invalid_debug}

  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp validate_metadata_content_type(content_type) do
    case Entry.validate_content_type(content_type) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_content_type, reason}}
    end
  end

  defp validate_metadata_headers(headers) do
    if Enum.all?(headers, &valid_metadata_header?/1) do
      :ok
    else
      {:error, :invalid_headers}
    end
  end

  defp valid_metadata_header?({name, value}), do: is_binary(name) and is_binary(value)
  defp valid_metadata_header?(_header), do: false

  defp parse_created_at(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> handle_invalid_metadata({:invalid_created_at, reason})
    end
  end

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
    do: is_binary(body_sha256) and Regex.match?(@body_sha256_pattern, body_sha256)

  defp write_sink_metadata(paths, encoded_metadata) do
    temp_path = temp_path(paths)

    case File.write(temp_path, encoded_metadata, [:binary, :exclusive]) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_sink_files(state, body_filename) do
    body_path = Path.join(state.paths.dir, body_filename)

    with :ok <- commit_body_file(state.temp_body_path, body_path, body_filename) do
      commit_metadata_file(state.paths.meta_path, state.temp_meta_path)
    end
  end

  defp commit_metadata_file(meta_path, meta_tmp_path) do
    File.rename(meta_tmp_path, meta_path)
  end

  defp commit_body_file(body_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      # Existing matching body content wins. The new temp body is no longer
      # needed, and cleanup is best-effort cache housekeeping.
      cleanup_temp_files([body_tmp_path])
      :ok
    else
      case File.rename(body_tmp_path, body_path) do
        :ok -> :ok
        {:error, :eexist} -> use_existing_body_file(body_tmp_path, body_path, body_filename)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp use_existing_body_file(body_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      cleanup_temp_files([body_tmp_path])
      :ok
    else
      {:error, :body_file_exists}
    end
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

  defp finalize_body_sha256(hash_context) do
    hash_context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp cleanup_sink_state(state) do
    _result = close_body_io(state)
    cleanup_temp_files([state.temp_body_path, state.temp_meta_path])
  end

  defp cleanup_temp_files(temp_paths) do
    temp_paths
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&File.rm/1)
  end

  @doc false
  def paths(%Key{hash: hash}, opts), do: paths_from_hash(hash, opts)

  @doc false
  def paths_from_hash(hash, opts) when is_binary(hash) and is_list(opts) do
    with {:ok, opts} <- validate_filesystem_options(opts),
         root = Keyword.fetch!(opts, :root),
         path_prefix = Keyword.fetch!(opts, :path_prefix),
         {:ok, {first_partition, second_partition}} <- partitions(hash) do
      dir = Path.join([root, path_prefix, first_partition, second_partition])
      meta_path = Path.join(dir, hash <> ".meta")

      with :ok <- validate_under_root(root, dir) do
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
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(meta_path, time: :posix) do
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

    if victim.delete_meta? do
      rm_tolerant(victim_paths.meta_path)
    end
  end

  defp rm_tolerant(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        require Logger
        # Path omitted: victim body/meta filenames embed the cache key
        # hash (a cache-adapter internal). Log the reason only.
        Logger.warning("cache: victim delete failed: reason=#{inspect(reason)}")
        :ok
    end
  end

  defp partitions(hash) do
    if Regex.match?(@cache_key_hash_pattern, hash) do
      do_partitions(hash)
    else
      {:error, {:invalid_hash, hash}}
    end
  end

  defp do_partitions(hash) do
    <<first::binary-size(2), second::binary-size(2), _rest::binary>> = hash
    {:ok, {first, second}}
  end

  defp validate_under_root(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)
    relative = Path.relative_to(path, root, force: true)

    # The two-argument form resolves symlinks against root. A plain prefix check
    # would allow a partition directory symlink to point outside the cache root.
    case Path.safe_relative(relative, root) do
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
end
