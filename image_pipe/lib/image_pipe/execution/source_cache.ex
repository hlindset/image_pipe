defmodule ImagePipe.Execution.SourceCache do
  @moduledoc false
  alias ImagePipe.Cache
  alias ImagePipe.Cache.Work
  alias ImagePipe.Execution.{Acquisition, Overlap, Staging}
  alias ImagePipe.Execution.Staging.Resources
  alias ImagePipe.MaterialDigest
  alias ImagePipe.RawFile
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheState
  alias ImagePipe.Source.Record
  alias ImagePipe.Source.Response
  alias ImagePipe.Telemetry

  # Staging derives a content identity, retains the origin's freshness, and
  # copies the original to a staged file when the source asks for one. A
  # local file with a strong identity and no copy is read where it is.
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
      :enabled -> Cache.source_record(key, config)
    end
  end

  def status(nil, _source, _config), do: :requires_validation

  def status(record, source, config),
    do: CacheState.status(Record.state(record, source.cache_semantics), now(config))

  def acquire(source, key, previous, preparation, config) do
    case Source.validation_mode(source, config) do
      :local ->
        acquire_local(source, key, previous, preparation, config)

      :exclusive ->
        acquire_locked(source, key, previous, preparation, config)

      {:shared, adapter} ->
        cohort = validation_cohort(source, previous, adapter, config)
        acquire_locked(source, key, previous, preparation, config, cohort)
    end
  end

  # A first download is shared with the other requests for the same original
  # made with the same settings.
  defp download_cohort(source, config) do
    MaterialDigest.of({
      :download,
      source.fetch,
      source.cache_semantics,
      Keyword.take(config, [:max_body_bytes, :clock, :cache])
    })
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
    Telemetry.span(config, [:source, :stage], %{}, fn ->
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

  # `cohort` is the validation cohort this request may share a validation
  # with, or nil.
  defp acquire_locked(source, key, previous, preparation, config, cohort \\ nil) do
    cohort = if is_nil(previous), do: download_cohort(source, config), else: cohort

    coordinate(
      shared_work?(source, previous, config),
      key,
      fn coordination, outcome ->
        lease = if coordination, do: coordination

        # Another request may have written a fresh record since the caller
        # read `previous`, unless every copy of this source needs validating.
        record =
          if outcome == :coalesced or not validated_on_every_use?(previous, source),
            do: lookup(source, key, config) || previous,
            else: previous

        result =
          case status(record, source, config) do
            :fresh -> {:ok, %Acquisition{record: record}}
            _validate -> fetch(source, key, record, preparation, config, lease)
          end

        if is_nil(previous), do: share_download(coordination, result, source)
        complete_validation(coordination, result, source, cohort)
      end,
      work_opts(source, config, cohort)
    )
    |> waited()
    |> finish_overlap()
  end

  defp complete_validation(
         lease,
         {:ok, %Acquisition{response: nil, lease: nil, record: record}} = result,
         source,
         cohort
       )
       when is_reference(lease) do
    if cohort != nil and storable?(record, source),
      do: Work.complete(lease, result)

    result
  end

  defp complete_validation(_lease, result, _source, _cohort), do: result

  defp validation_cohort(source, %Record{} = previous, adapter, config) do
    if storable?(previous, source) do
      MaterialDigest.of({
        adapter,
        source.fetch,
        source.cache_semantics,
        untimed(previous),
        Keyword.take(config, [:max_body_bytes, :clock, :cache])
      })
    end
  end

  defp validation_cohort(_source, nil, _adapter, _config), do: nil

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

  # Downloads the original of `record`, a current record whose bytes this
  # request needs, sharing the download with other requests for it.
  def input(source, key, record, preparation, config) do
    coordinate(
      storable?(record, source) and staged?(source),
      key,
      fn coordination, _outcome ->
        lease = if coordination, do: coordination
        result = fetch(source, key, nil, preparation, config, lease, record)
        share_download(coordination, result, source)
        result
      end,
      work_opts(source, config, download_cohort(source, config))
    )
    |> waited()
    |> finish_overlap()
  end

  # A request waits for another one's work on the same source only when that
  # work can leave something it uses: a stored original, a staged one it
  # shares (`share_download/3`), or a shared check of a known one.
  defp coordinate(true, key, fun, opts), do: Work.run({:source, key.hash}, fun, opts)
  defp coordinate(false, _key, fun, _opts), do: fun.(false, :uncoordinated)

  defp shared_work?(%{internal_cache: :disabled}, _previous, _config), do: false

  defp shared_work?(source, previous, config),
    do: staged?(source) or (previous != nil and Keyword.has_key?(config, :cache))

  # The requests waiting for this download each get their own hard link to
  # the staged original, tracked for that request, or the bytes of one held
  # in memory. A link that can't be made leaves its request queued, to take
  # the lease next. Nothing is shared for an original that may not be stored.
  defp share_download(
         lease,
         {:ok, %Acquisition{response: %Response{} = response, record: record} = acquisition},
         source
       )
       when is_reference(lease) do
    with true <- storable?(record, source),
         [_ | _] = waiting <- Work.sharing(lease) do
      shared = %{acquisition | processing: nil, processing_deadline: nil}

      values =
        for pid <- waiting,
            {:ok, copy} <- [shared_copy(shared, response, pid)],
            into: %{},
            do: {pid, {:ok, copy}}

      Work.complete_each(lease, values)
    end
  end

  defp share_download(_lease, _result, _source), do: :ok

  defp shared_copy(%Acquisition{lease: :unavailable} = acquisition, _response, _pid),
    do: {:ok, acquisition}

  defp shared_copy(acquisition, %Response{path: path} = response, pid) when is_binary(path) do
    link = Staging.temporary_path(Staging.dir())

    with :ok <- RawFile.make_link(path, link),
         {_token, ^link} = lease <- Resources.track(link, pid) do
      {:ok, %{acquisition | response: %{response | path: link}, lease: lease}}
    else
      _failed ->
        RawFile.delete(link)
        :error
    end
  end

  defp shared_copy(_acquisition, _response, _pid), do: :error

  # A request waiting behind another one's download gives up a second after
  # that download's own deadline, with the same timeout error.
  defp work_opts(source, config, cohort) do
    case wait_timeout(source) do
      nil -> coordination_opts(config, cohort)
      timeout -> Keyword.put(coordination_opts(config, cohort), :wait, timeout)
    end
  end

  # How long a request waits behind another one's download of `source`, or
  # nil when the source sets no download deadline.
  def wait_timeout(%{fetch: fetch}) when is_list(fetch) do
    case Keyword.get(fetch, :fetch_timeout) do
      nil -> nil
      timeout -> timeout + 1_000
    end
  end

  def wait_timeout(_source), do: nil

  defp coordination_opts(config, cohort),
    do: Keyword.put(Telemetry.telemetry_opts(config), :share, cohort)

  defp waited(:timeout), do: {:error, {:source, :receive_timeout}}
  defp waited(result), do: result

  # Processing that overlapped the download is awaited after the source's work
  # is released, so requests waiting for the same source don't wait for it too.
  defp finish_overlap({:ok, %Acquisition{processing: overlap} = acquisition}) do
    {processing, deadline} = Overlap.finish(overlap)
    {:ok, %{acquisition | processing: processing, processing_deadline: deadline}}
  end

  defp finish_overlap(result), do: result

  # `lease` is this request's lease on the source's work, or nil.
  # `release_unstored/4` lets its waiters go when the response may not be
  # stored. `known` is a
  # current record whose bytes are needed again, for another variant. A local
  # original whose evidence still matches it isn't rehashed.
  defp fetch(source, key, previous, preparation, config, lease, known \\ nil) do
    Telemetry.span(config, [:source, :stage], %{}, fn ->
      preparation = if is_nil(previous), do: preparation

      stage = fn response ->
        release_unstored(lease, response, source, config)
        stage(response, source, preparation, config, known)
      end

      result = fetch_response(source, previous, config, stage)
      result = publish_coordinated(result, source, key, previous || known, config, lease)
      {result, stop_metadata(result)}
    end)
  end

  # Requests waiting for a download that won't be stored would only download
  # it again once it ends, so they start now.
  defp release_unstored(nil, _response, _source, _config), do: :ok

  defp release_unstored(lease, response, source, config) do
    if not storable?(Record.new(source, nil, response.origin, now(config)), source),
      do: Work.release_waiters(lease)
  end

  # Only writes take the publication lock, so a check that changes nothing,
  # the steady state for a local file, doesn't. A lease that is no longer
  # current skips the writes (see `Cache.publish/3`).
  defp publish_coordinated(result, source, key, previous, config, lease) do
    case publication(result, source, key, previous, config) do
      {result, nil} ->
        result

      {result, write} ->
        Cache.publish(key.hash, lease, write)
        result
    end
  end

  defp fetch_response(source, %Record{origin: %Source.Origin{} = origin}, config, fun),
    do: Source.with_revalidated(source, origin, config, fun)

  defp fetch_response(source, _previous, config, fun),
    do: Source.with_fetched(source, config, fun)

  # The result of a fetch and the write to memory it calls for, or `nil` when
  # it calls for none.
  defp publication({:not_modified, origin}, source, key, previous, config) do
    record = Record.refresh(previous, origin)

    write =
      if not unchanged_record?(previous, record, source, config),
        do: remember(source, key, record, config)

    {{:ok, %Acquisition{record: record}}, write}
  end

  defp publication({:ok, %Acquisition{record: record}} = result, source, key, previous, config) do
    write =
      cond do
        storable?(record, source) ->
          store(source, key, previous, record, config)

        # Nothing is stored for a source that isn't cached internally.
        source.internal_cache == :disabled ->
          nil

        true ->
          invalidation(key, config)
      end

    {result, write}
  end

  defp publication({:error, {:source, {:bad_status, status}}} = error, _source, key, _, config)
       when status in [401, 403, 404, 410],
       do: {error, invalidation(key, config)}

  defp publication(error, _source, _key, _previous, _config), do: {error, nil}

  defp store(source, key, previous, record, config) do
    if not unchanged_record?(previous, record, source, config),
      do: fn -> Cache.remember_source(key, record, config) end
  end

  defp remember(source, key, record, config) do
    case storable?(record, source) do
      true -> fn -> Cache.remember_source(key, record, config) end
      false -> invalidation(key, config)
    end
  end

  # An invalidation runs even after its lease has expired: forgetting a
  # record is always safe, and skipping one could keep serving a removed
  # source.
  defp invalidation(key, config),
    do: {:invalidate, fn -> Cache.remember_source(key, nil, config) end}

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

    case RawFile.stat(original) do
      {:ok, %File.Stat{size: size}} ->
        {:ok,
         %Acquisition{
           record: record,
           response: %Response{path: original, origin: response.origin},
           source_bytes: size
         }}

      {:error, _reason} ->
        {:error, {:source, :unreadable}}
    end
  rescue
    exception in Source.StreamError -> {:error, {:source, exception.reason}}
    _exception in File.Error -> {:error, {:source, :unreadable}}
  end

  # Without a private staging directory, the original is buffered in memory.
  defp stage(response, source, preparation, config, _known) do
    dir = Staging.dir()
    path = Staging.temporary_path(dir)

    lease =
      case Staging.private_dir(dir) do
        :ok -> Resources.track(path)
        :error -> :unavailable
      end

    try do
      stream =
        case response.path do
          nil -> response.stream
          path -> File.stream!(path, 65_536)
        end

      {body, digest, size, processing, buffered} =
        case lease do
          :unavailable -> spool_buffer(stream, config[:max_body_bytes], :dir)
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
         processing: processing,
         buffered: buffered
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
    case :file.open(path, [:read, :write, :binary, :exclusive, :raw]) do
      {:ok, io} ->
        _result = RawFile.set_mode(path, 0o600)

        overlap = Overlap.start(response, preparation, config, path)

        try do
          spool_file(stream, io, config[:max_body_bytes], overlap)
        catch
          kind, reason ->
            Overlap.close(overlap)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          :file.close(io)
        end

      {:error, _reason} ->
        spool_buffer(stream, config[:max_body_bytes], :open)
    end
  end

  # Network messages are often a few KiB, so they're written to the file in
  # batches of `@spool_batch` bytes. A decode that may read the file as it
  # grows needs every byte as it arrives, since the origin can pause between
  # messages, so then each message is written at once.
  @spool_batch 65_536

  defp spool_file(stream, io, limit, overlap) do
    initial = {:file, 0, :crypto.hash_init(:sha256), overlap, {[], 0}}

    {body, size, hash, overlap, pending} =
      Source.reduce_body(stream, initial, fn bytes, {body, size, hash, overlap, pending} ->
        next_size = size + byte_size(bytes)
        check_size!(next_size, limit)
        hash = :crypto.hash_update(hash, bytes)
        {body, overlap, pending} = append(body, io, bytes, next_size, overlap, pending)
        {body, next_size, hash, overlap, pending}
      end)

    body = flush(body, io, pending)
    overlap = if match?({:buffer, _}, body), do: Overlap.cancel(overlap), else: overlap
    check_staged_size!(body, io, size)
    buffered = if body != :file, do: :write

    {finish_body(body), :crypto.hash_final(hash), size, Overlap.complete(overlap), buffered}
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

  # `pending` holds the bytes not yet written, newest first, and how many
  # bytes the file holds.
  defp append(:file, io, bytes, size, overlap, {chunks, written}) do
    chunks = [bytes | chunks]

    if size - written >= @spool_batch or Overlap.reading?(overlap) do
      body = flush(:file, io, {chunks, written})
      {body, observe(body, overlap, io, size), {[], size}}
    else
      {:file, overlap, {chunks, written}}
    end
  end

  defp append({:buffer, reversed}, _io, bytes, _size, overlap, pending),
    do: {{:buffer, [bytes | reversed]}, overlap, pending}

  defp flush(:file, _io, {[], _written}), do: :file

  defp flush(:file, io, {chunks, written}) do
    case :file.pwrite(io, written, Enum.reverse(chunks)) do
      :ok -> :file
      {:error, _reason} -> {:buffer, chunks ++ [written_prefix(io, written)]}
    end
  end

  defp flush({:buffer, _reversed} = body, _io, _pending), do: body

  defp written_prefix(_io, 0), do: ""

  defp written_prefix(io, written) do
    {:ok, prefix} = :file.pread(io, 0, written)
    prefix
  end

  defp finish_body(:file), do: :file

  defp finish_body({:buffer, reversed}),
    do: {:buffer, reversed |> Enum.reverse() |> IO.iodata_to_binary()}

  # `reason` says why the original isn't staged to a file.
  defp spool_buffer(stream, limit, reason) do
    {bytes, size, hash} =
      Source.reduce_body(stream, {[], 0, :crypto.hash_init(:sha256)}, fn bytes,
                                                                         {acc, size, hash} ->
        check_size!(size + byte_size(bytes), limit)
        {[bytes | acc], size + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end)

    {{:buffer, bytes |> Enum.reverse() |> IO.iodata_to_binary()}, :crypto.hash_final(hash), size,
     nil, reason}
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
  defp stop_metadata({:ok, %Acquisition{buffered: nil}}), do: %{result: :ok}

  defp stop_metadata({:ok, %Acquisition{buffered: reason}}),
    do: %{result: :ok, staging: :memory, staging_reason: reason}

  defp stop_metadata({:error, {:source, reason}}),
    do: %{result: :source_error, error: Telemetry.error_tag(reason)}

  defp stop_metadata({:error, _reason} = error), do: %{result: Telemetry.request_result(error)}
end
