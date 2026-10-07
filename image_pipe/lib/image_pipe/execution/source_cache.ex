defmodule ImagePipe.Execution.SourceCache do
  @moduledoc false
  alias ImagePipe.Cache
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.Work
  alias ImagePipe.Error
  alias ImagePipe.Execution.{Acquisition, Overlap}
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheState
  alias ImagePipe.Source.Record
  alias ImagePipe.Source.Response
  alias ImagePipe.Telemetry

  # Staging derives a content identity, retains the origin's freshness, and
  # keeps a copy of the original when the source asks for one. A local file with
  # a strong identity and no copy is read where it is.
  def staged?(%{cache_semantics: %{byte_identity: :content}}), do: true
  def staged?(%{cache_semantics: %{copy?: copy?}}), do: copy?

  def now(config), do: Keyword.get(config, :clock, fn -> System.system_time(:second) end).()

  def immutable_record(source, config) do
    semantics = source.cache_semantics

    if semantics.stable? and Keyword.get(semantics.policy, :storage) == :allow do
      Record.new(source, nil, nil, now(config))
    end
  end

  def lookup(source, key, config) do
    case source.internal_cache do
      :disabled -> nil
      :enabled -> Cache.source_record(key, config) || Input.metadata(key, config)
    end
  end

  def status(nil, _source, _config), do: :requires_validation

  def status(record, source, config),
    do: CacheState.status(Record.state(record, source.cache_semantics), now(config))

  def acquire(source, key, previous, preparation, config) do
    case Source.validation_mode(source, config) do
      :local -> acquire_local(source, key, previous, preparation, config)
      :exclusive -> acquire_locked(source, key, previous, preparation, config)
    end
  end

  defp acquire_local(
         source,
         key,
         %Record{origin: %Source.Origin{}} = previous,
         preparation,
         config
       ) do
    case validated_on_every_use?(previous, source) do
      true ->
        case check_unchanged(source, previous, config) do
          {:ok, _acquisition} = result -> result
          :changed -> acquire_locked(source, key, previous, preparation, config)
        end

      false ->
        acquire_locked(source, key, previous, preparation, config)
    end
  end

  defp acquire_local(source, key, previous, preparation, config),
    do: acquire_locked(source, key, previous, preparation, config)

  # A changed or failed stat must be observed again while holding the lease,
  # before staging new bytes or invalidating an existing record.
  defp check_unchanged(source, previous, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:source, :stage], %{}, fn ->
      source
      |> fetch_response(previous, config, fn _response -> :changed end)
      |> preflight_result(previous)
    end)
  end

  defp preflight_result({:not_modified, origin}, previous) do
    result = {:ok, %Acquisition{record: Record.refresh(previous, origin)}}
    {result, stop_metadata(result)}
  end

  defp preflight_result(result, _previous), do: {:changed, preflight_metadata(result)}

  defp preflight_metadata(:changed), do: %{result: :ok}
  defp preflight_metadata(error), do: stop_metadata(error)

  defp acquire_locked(source, key, previous, preparation, config) do
    Work.run(
      {:source, key.hash},
      fn coordination, outcome ->
        opts =
          case coordination do
            false -> config
            ref -> Keyword.put(config, :source_lease, ref)
          end

        # Another request may have written a fresh record since the caller
        # read `previous`, unless every copy of this source needs validating.
        record =
          if outcome == :coalesced or not validated_on_every_use?(previous, source),
            do: lookup(source, key, opts) || previous,
            else: previous

        case status(record, source, opts) do
          :fresh -> {:ok, %Acquisition{record: record}}
          _validate -> fetch(source, key, record, preparation, opts)
        end
      end,
      work_opts(source, config)
    )
    |> waited()
  end

  # A source whose copies arrive without freshness (no-cache, no lifetime, or
  # already stale) gains nothing from a record another request just wrote.
  defp validated_on_every_use?(nil, _source), do: false

  defp validated_on_every_use?(record, source) do
    case Record.state(record, source.cache_semantics).fresh_until do
      nil -> true
      :infinity -> false
      fresh_until -> fresh_until <= record.received_at
    end
  end

  def input(source, key, record, preparation, config) do
    case Input.open(key, record, config) do
      {:ok, path, lease} ->
        checked_input(record, path, lease, config)

      :miss ->
        Work.run(
          {:source, key.hash},
          fn coordination, _outcome ->
            open_or_fetch(source, key, record, preparation, config, coordination)
          end,
          work_opts(source, config)
        )
        |> waited()
    end
  end

  # A request waiting behind another one's download gives up a second after
  # that download's own deadline, with the same timeout error.
  defp work_opts(%{fetch: fetch}, config) when is_list(fetch) do
    case Keyword.get(fetch, :fetch_timeout) do
      nil -> Telemetry.telemetry_opts(config)
      timeout -> Keyword.put(Telemetry.telemetry_opts(config), :wait, timeout + 1_000)
    end
  end

  defp work_opts(_source, config), do: Telemetry.telemetry_opts(config)

  defp waited(:timeout), do: {:error, {:source, :receive_timeout}}
  defp waited(result), do: result

  defp open_or_fetch(source, key, record, preparation, config, ref) when is_reference(ref) do
    config = Keyword.put(config, :source_lease, ref)

    case Input.open(key, record, config) do
      {:ok, path, lease} -> checked_input(record, path, lease, config)
      :miss -> fetch(source, key, nil, preparation, config, record)
    end
  end

  defp open_or_fetch(source, key, record, preparation, config, false),
    do: fetch(source, key, nil, preparation, config, record)

  defp checked_input(record, path, lease, config) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{size: size}} when size <= limit ->
        {:ok,
         %Acquisition{
           record: record,
           response: %Response{path: path, origin: record.origin},
           lease: lease,
           source_bytes: size
         }}

      {:ok, _stat} ->
        Resources.release(lease)
        {:error, {:source, :body_too_large}}

      {:error, _reason} ->
        Resources.release(lease)
        {:error, {:source, :invalid_body}}
    end
  end

  # `known` is a current record whose bytes are needed again, for another
  # variant. A local original whose evidence still matches it isn't rehashed.
  defp fetch(source, key, previous, preparation, config, known \\ nil) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:source, :stage], %{}, fn ->
      started = System.monotonic_time(:microsecond)
      preparation = if is_nil(previous), do: preparation
      stage = &stage(&1, source, preparation, config, known)
      result = fetch_response(source, previous, config, stage)
      cost = System.monotonic_time(:microsecond) - started
      result = publish_coordinated(result, source, key, previous || known, cost, config)
      {result, stop_metadata(result)}
    end)
  end

  # Only writes take the publication lock, so a check that changes nothing,
  # the steady state for a local file, doesn't. A lease that is no longer
  # current skips the writes.
  defp publish_coordinated(result, source, key, previous, cost, config) do
    case publication(result, source, key, previous, cost, config) do
      {result, nil} ->
        result

      {result, write} ->
        Work.publish(key.hash, Keyword.get(config, :source_lease), write)
        result
    end
  end

  defp fetch_response(source, %Record{origin: %Source.Origin{} = origin}, config, fun),
    do: Source.with_revalidated(source, origin, config, fun)

  defp fetch_response(source, _previous, config, fun),
    do: Source.with_fetched(source, config, fun)

  # The result of a fetch and the cache writes it calls for, or `nil` when it
  # calls for none.
  defp publication({:not_modified, origin}, source, key, previous, _cost, config) do
    record = Record.refresh(previous, origin)

    write =
      if not unchanged_record?(previous, record, source, config),
        do: fn -> remember(source, key, record, config) end

    {{:ok, %Acquisition{record: record}}, write}
  end

  defp publication(
         {:ok, %Acquisition{record: record, response: response, source_sha256: sha256}} = result,
         source,
         key,
         previous,
         cost,
         config
       ) do
    write =
      cond do
        storable?(record, source) ->
          store(source, key, previous, record, {response, sha256}, cost, config)

        # Nothing is stored for a source that isn't cached internally.
        source.internal_cache == :disabled ->
          nil

        true ->
          fn -> invalidate(key, config) end
      end

    {result, write}
  end

  defp publication(
         {:error, {:source, {:bad_status, status}}} = error,
         _source,
         key,
         _previous,
         _cost,
         config
       )
       when status in [401, 403, 404, 410],
       do: {error, fn -> invalidate(key, config) end}

  defp publication(error, _source, _key, _previous, _cost, _config), do: {error, nil}

  defp store(source, key, previous, record, {response, sha256}, cost, config) do
    copy? = response.path != nil and source.cache_semantics.copy?
    remember? = not unchanged_record?(previous, record, source, config)

    cond do
      copy? and remember? ->
        fn ->
          Input.put(key, response.path, sha256, record, cost, config)
          Cache.remember_source(key, record, config)
        end

      copy? ->
        fn -> Input.put(key, response.path, sha256, record, cost, config) end

      remember? ->
        fn -> Cache.remember_source(key, record, config) end

      true ->
        nil
    end
  end

  defp remember(source, key, record, config) do
    case storable?(record, source) do
      true ->
        Input.refresh(key, record, config)
        Cache.remember_source(key, record, config)

      false ->
        invalidate(key, config)
    end
  end

  # A check that moved only the receipt times of a record that must be
  # validated on every use leaves the stored record as useful as the new one,
  # so it isn't rewritten. A record with remaining freshness is always stored.
  defp unchanged_record?(nil, _record, _source, _config), do: false

  defp unchanged_record?(previous, record, source, config) do
    untimed(previous) == untimed(record) and
      status(previous, source, config) == :requires_validation and
      status(record, source, config) == :requires_validation
  end

  defp untimed(%Record{origin: nil} = record), do: %{record | received_at: nil}

  defp untimed(%Record{origin: origin} = record),
    do: %{record | received_at: nil, origin: %{origin | requested_at: nil, received_at: nil}}

  # A decode failure can come from the request (an output profile libvips
  # can't apply) as easily as from the source, and libvips is lazy, so a
  # corrupt source often fails only in the encoder. Refetching helps only when
  # the stored original no longer matches what was fetched, so the original
  # and its record are dropped only then.
  def check(key, config) do
    case Input.verify(key, config) do
      {:error, _reason} -> invalidate(key, config)
      _intact_or_missing -> :ok
    end
  end

  defp invalidate(key, config) do
    Input.discard(key, config)
    Cache.remember_source(key, nil, config)
  end

  def storable?(record, source),
    do:
      source.internal_cache == :enabled and Record.state(record, source.cache_semantics).storable?

  def release(nil), do: :ok
  def release(lease), do: Resources.release(lease)

  # A local original without a copy is hashed where it is and decoded from its
  # own path.
  defp stage(
         %Response{path: original} = response,
         %{cache_semantics: %{copy?: false}} = source,
         _preparation,
         config,
         known
       )
       when is_binary(original) do
    record =
      if unchanged?(known, response.origin),
        do: Record.refresh(known, response.origin),
        else:
          Record.new(
            source,
            hash_file(original, config[:max_body_bytes]),
            response.origin,
            now(config)
          )

    {:ok,
     %Acquisition{
       record: record,
       response: %Response{path: original, origin: response.origin},
       source_bytes: File.stat!(original).size
     }}
  rescue
    exception in Source.StreamError -> {:error, {:source, exception.reason}}
    _exception in File.Error -> {:error, {:source, :unreadable}}
  end

  defp stage(response, source, preparation, config, _known) do
    dir = Input.staging_dir()
    _result = File.mkdir_p(dir)
    path = Input.temporary_path(dir)
    lease = Resources.track(path)

    try do
      stream =
        case response.path do
          nil -> response.stream
          path -> File.stream!(path, 65_536)
        end

      {body, digest, size, processing} =
        case lease do
          :unavailable -> spool_buffer(stream, config[:max_body_bytes])
          _ref -> spool(stream, path, response, preparation, config)
        end

      record = Record.new(source, digest, response.origin, now(config))
      prepared = staged_response(body, path, response.origin)

      {:ok,
       %Acquisition{
         record: record,
         response: prepared,
         lease: lease,
         source_bytes: size,
         source_sha256: digest,
         processing: processing
       }}
    rescue
      exception in Source.StreamError ->
        release(lease)
        {:error, {:source, exception.reason}}

      _exception in File.Error ->
        release(lease)
        {:error, {:source, :unreadable}}
    catch
      kind, reason ->
        release(lease)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp staged_response(:file, path, origin), do: %Response{path: path, origin: origin}

  defp staged_response({:buffer, bytes}, _path, origin),
    do: %Response{stream: [bytes], origin: origin}

  defp spool(stream, path, response, preparation, config) do
    case File.open(path, [:read, :write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          Overlap.with_session(response, preparation, config, path, fn overlap ->
            spool_file(stream, io, config[:max_body_bytes], overlap)
          end)
        after
          File.close(io)
        end

      {:error, _reason} ->
        spool_buffer(stream, config[:max_body_bytes])
    end
  end

  defp spool_file(stream, io, limit, overlap) do
    initial = {:file, 0, :crypto.hash_init(:sha256), overlap}

    {body, size, hash, overlap} =
      Source.reduce_body(stream, initial, fn bytes, {body, size, hash, overlap} ->
        next_size = size + byte_size(bytes)
        check_size!(next_size, limit)
        body = append(body, io, bytes, size)

        overlap = observe(body, overlap, io, next_size)
        {body, next_size, :crypto.hash_update(hash, bytes), overlap}
      end)

    check_staged_size!(body, io, size)
    {finish_body(body), :crypto.hash_final(hash), size, Overlap.finish(overlap)}
  end

  defp check_staged_size!(:file, io, size) do
    case :file.read_file_info(io) do
      {:ok, info} when elem(info, 1) == size -> :ok
      _invalid -> raise Source.StreamError, reason: :invalid_body
    end
  end

  defp check_staged_size!({:buffer, _bytes}, _io, _size), do: :ok

  defp observe(:file, overlap, io, size), do: Overlap.observe(overlap, io, size)
  defp observe({:buffer, _}, overlap, _io, _size), do: Overlap.cancel(overlap)

  defp append(:file, io, bytes, size) do
    case :file.pwrite(io, size, bytes) do
      :ok ->
        :file

      {:error, _reason} ->
        {:ok, prefix} = :file.pread(io, 0, size)
        {:buffer, [bytes, prefix]}
    end
  end

  defp append({:buffer, reversed}, _io, bytes, _size), do: {:buffer, [bytes | reversed]}
  defp finish_body(:file), do: :file

  defp finish_body({:buffer, reversed}),
    do: {:buffer, reversed |> Enum.reverse() |> IO.iodata_to_binary()}

  defp spool_buffer(stream, limit) do
    {bytes, size, hash} =
      Source.reduce_body(stream, {[], 0, :crypto.hash_init(:sha256)}, fn bytes,
                                                                         {acc, size, hash} ->
        check_size!(size + byte_size(bytes), limit)
        {[bytes | acc], size + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end)

    {{:buffer, bytes |> Enum.reverse() |> IO.iodata_to_binary()}, :crypto.hash_final(hash), size,
     nil}
  end

  defp unchanged?(%Record{origin: %{headers: %{"etag" => same}}}, %{headers: %{"etag" => same}}),
    do: true

  defp unchanged?(_known, _evidence), do: false

  defp hash_file(path, limit) do
    {_size, hash} =
      path
      |> File.stream!(65_536)
      |> Enum.reduce({0, :crypto.hash_init(:sha256)}, fn bytes, {size, hash} ->
        check_size!(size + byte_size(bytes), limit)
        {size + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end)

    :crypto.hash_final(hash)
  end

  defp check_size!(size, limit) when size > limit,
    do: raise(Source.StreamError, reason: :body_too_large)

  defp check_size!(_size, _limit), do: :ok
  defp stop_metadata({:ok, %Acquisition{}}), do: %{result: :ok}

  defp stop_metadata({:error, {:source, reason}}),
    do: %{result: :source_error, error: Error.tag(reason)}

  defp stop_metadata({:error, _reason} = error), do: %{result: Telemetry.request_result(error)}
end
