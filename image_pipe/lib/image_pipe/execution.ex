defmodule ImagePipe.Execution do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.MaterialDigest,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Processing,
      ImagePipe.ProcessingPool,
      ImagePipe.RawFile,
      ImagePipe.Representation,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [Context, Inputs, Output, Staging, Staging.Resources]

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Delivery

  alias ImagePipe.Execution.{
    Acquisition,
    Context,
    Identity,
    Output,
    SourceCache,
    Staging,
    Watermarks
  }

  alias ImagePipe.Output.Resolved
  alias ImagePipe.Processing
  alias ImagePipe.Processing.DebugBuilder
  alias ImagePipe.Processing.Terminal
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Representation
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Executor

  def identity_material(request, policy, inputs, config),
    do: Identity.material(request, policy, inputs, config, detector_identity(request, config))

  @doc "Plans the request's watermark assets before any source access."
  def watermark_sources(request, config), do: Watermarks.plan(request, config)

  @doc """
  Prepares a request and runs `fun` with its context, closing the context
  after. The output policy and watermark plan are checked before
  `resolve_source` runs, so their errors return before any source access.
  `resolve_source` gets the config and returns `{:ok, source, config}`.
  """
  def with_prepared(request, accept, inputs, config, resolve_source, fun) do
    with {:ok, policy} <- Processing.prepare(request, config, accept),
         {:ok, watermarks} <- watermark_sources(request, config),
         {:ok, source, config} <- resolve_source.(config),
         {:ok, context} <- prepare(request, source, watermarks, policy, inputs, config) do
      try do
        fun.(context)
      after
        close(context)
      end
    end
  end

  def prepare(request, source, watermarks, policy, inputs, config) do
    config = Keyword.put(config, :processing_priority, request.priority)
    material = identity_material(request, policy, inputs, config)
    tasks = Watermarks.prepare_async(watermarks, material, config)

    context = %Context{
      request: request,
      source: source,
      policy: policy,
      material: material,
      inputs: inputs,
      config: config,
      representation: nil
    }

    with {:ok, context} <- prepare_source(context, tasks),
         {:ok, watermarks} <- watermarks(tasks, context) do
      {:ok, with_watermarks(context, watermarks)}
    else
      {:error, _reason} = error ->
        Watermarks.cancel(tasks)
        error
    end
  end

  # A failure that exits this process, which can outlive the request, as on a
  # kept-alive connection, first stops the asset tasks.
  defp prepare_source(context, tasks) do
    case SourceCache.staged?(context.source) do
      true -> prepare_remote(context)
      false -> {:ok, represent(context)}
    end
  catch
    kind, reason ->
      Watermarks.cancel(tasks)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Callers close a prepared context only after a successful prepare, so a
  # failed or crashed watermark releases the source lease here.
  defp watermarks(tasks, context) do
    result =
      try do
        Watermarks.await(tasks)
      catch
        :exit, reason ->
          Watermarks.cancel(tasks)
          close(context)
          exit(reason)
      end

    with {:error, _reason} = error <- result do
      close(context)
      error
    end
  end

  defp with_watermarks(context, []), do: context

  defp with_watermarks(context, watermarks) do
    assets = Map.new(watermarks, &{&1.asset, [source: &1.source.identity, opacity: &1.opacity]})

    partitions =
      for %{input_key: %{hash: hash}} <- watermarks, do: {:watermark_partition, hash}

    material = Identity.put_watermarks(context.material, assets)
    material = %{material | storage_only: material.storage_only ++ partitions}

    represent(%{context | material: material, watermarks: watermarks})
  end

  defp represent(context) do
    %{
      context
      | representation:
          Representation.build(context.source.identity, context.material, byte_identity(context))
    }
  end

  # Byte identity of the main source together with every watermark asset.
  defp byte_identity(%Context{} = context) do
    main =
      case context.acquisition.record do
        nil -> context.source.cache_semantics.byte_identity
        record -> record.byte_identity
      end

    Watermarks.byte_identity(main, context.watermarks)
  end

  @doc """
  The main source's cache semantics, narrowed by every watermark asset: byte
  identity spans all inputs, and any unstable or storage-denying asset
  applies to the response.
  """
  def cache_semantics(%Context{} = context) do
    semantics = context.source.cache_semantics
    assets = Enum.map(context.watermarks, & &1.source.cache_semantics)

    policy =
      case Enum.any?(assets, &(Keyword.get(&1.policy, :storage) == :deny)) do
        true -> Keyword.put(semantics.policy, :storage, :deny)
        false -> semantics.policy
      end

    %{
      semantics
      | byte_identity: byte_identity(context),
        stable?: semantics.stable? and Enum.all?(assets, & &1.stable?),
        policy: policy
    }
  end

  defp prepare_remote(context) do
    with {:ok, source, fetch_digest} <-
           Source.prepare_cache_context(context.source, context.config) do
      key = Representation.input_key(source.identity, context.material, fetch_digest)

      material = %{
        context.material
        | storage_only: [{:source_partition, key.hash} | context.material.storage_only]
      }

      context = %{context | source: source, input_key: key, material: material}

      resolve_record(context)
    end
  end

  # Fetches or checks the source when no fresh or stale record serves it.
  defp resolve_record(context) do
    record =
      SourceCache.immutable_record(context.source, context.config) ||
        SourceCache.lookup(context.source, context.input_key, context.config)

    case SourceCache.status(record, context.source, context.config) do
      :fresh -> {:ok, current(context, %Acquisition{record: record})}
      :stale -> {:ok, %{current(context, %Acquisition{record: record}) | stale?: true}}
      _ -> acquire(context, record)
    end
  end

  defp acquire(context, record) do
    case SourceCache.acquire(
           context.source,
           context.input_key,
           record,
           preparation(context),
           context.config
         ) do
      {:ok, acquisition} ->
        {:ok, current(context, acquisition)}

      {:error, _reason} = error ->
        error
    end
  end

  defp current(context, acquisition),
    do: represent(%{context | acquisition: acquisition, stale?: false})

  # An overlapped decode would start before watermark assets are available.
  defp preparation(%Context{request: request, policy: policy}) do
    case Enum.any?(request.groups, &(&1.watermark != nil)) do
      true -> nil
      false -> {request, policy}
    end
  end

  # Prepare owns its source lease; callers close it after their conditional gate
  # and output consumption. Output owns leases acquired later by open/1.
  def close(%Context{acquisition: acquisition}) do
    SourceCache.release(acquisition.lease)
  end

  def open(%Context{stale?: true} = context) do
    case lookup(context) do
      {:hit, output} ->
        refresh(context)
        {:ok, output}

      :miss ->
        with {:ok, current} <- acquire(context, context.acquisition.record) do
          open_with_lease(current, current.acquisition.lease, recheck(context, current))
        end
    end
  end

  def open(%Context{} = context), do: open_current(context)

  # The stale lookup already counted this request. Its key changes only when
  # the original did, and a lookup of the new key counts as its own.
  defp recheck(stale, current) do
    case stale.representation.cache_key == current.representation.cache_key do
      true -> &Cache.recheck_entry/2
      false -> &Cache.lookup_entry/2
    end
  end

  defp open_current(context, lookup \\ &Cache.lookup_entry/2) do
    case lookup(context, lookup) do
      {:hit, output} ->
        {:ok, output}

      :miss ->
        with_watermark_inputs(context, &input/1)
    end
  end

  # Asset bytes are read while the main source is acquired, and awaited when
  # generation needs them. An uncached main source is fetched by the
  # processing worker, so that worker reads the assets alongside it instead.
  defp with_watermark_inputs(%Context{watermarks: []} = context, fun), do: fun.(context)

  defp with_watermark_inputs(%Context{input_key: nil} = context, fun),
    do: fun.(%{context | watermark_tasks: :deferred})

  defp with_watermark_inputs(context, fun) do
    tasks = Watermarks.open_async(context.watermarks, context.config)

    try do
      fun.(%{context | watermark_tasks: tasks})
    after
      Watermarks.cancel(tasks)
    end
  end

  defp watermark_inputs(%Context{watermarks: []}), do: {:ok, %{}}

  defp watermark_inputs(%Context{watermark_tasks: :deferred} = context),
    do: {:ok, {:deferred, Watermarks.deferred(context.watermarks, context.config)}}

  defp watermark_inputs(context) do
    with {:ok, watermarks} <- Watermarks.await(context.watermark_tasks) do
      {:ok, Watermarks.inputs(watermarks)}
    end
  end

  # A recheck looks again after waiting for another request's write, so the
  # cache's stats count the request once.
  defp lookup(context, lookup \\ &Cache.lookup_entry/2) do
    case storable?(context) do
      true ->
        {result, time} =
          Timing.measure(fn ->
            lookup.(context.representation.cache_key, lookup_config(context))
          end)

        checked_hit(result, context, time)

      false ->
        :miss
    end
  end

  # The cache keeps entries in memory without their debug facts, so a debug
  # request reads its hit from disk.
  defp lookup_config(%Context{request: %{debug?: true}} = context),
    do: Keyword.put(context.config, :debug?, true)

  defp lookup_config(context), do: context.config

  defp checked_hit({:hit, entry}, context, time) do
    case {context.request.output.terminal, entry.representation} do
      {:image, {:complete_body, _}} ->
        Cache.Entry.close(entry)
        :miss

      {:image, _} ->
        {:hit, output(context, {:entry, entry}, :hit, time)}

      {:info, {:complete_body, "application/json"}} ->
        {:hit, output(context, {:entry, entry}, :hit, time)}

      {terminal, {:complete_body, "text/plain"}} when terminal in [:blurhash, :lqip_css] ->
        {:hit, output(context, {:entry, entry}, :hit, time)}

      _ ->
        Cache.Entry.close(entry)
        :miss
    end
  end

  defp checked_hit(_miss, _context, _time), do: :miss

  defp storable?(context) do
    source_storable?(context.acquisition.record, context.source) and
      Enum.all?(context.watermarks, fn watermark ->
        source_storable?(watermark.record, watermark.source)
      end)
  end

  defp source_storable?(nil, source),
    do:
      source.internal_cache == :enabled and
        Keyword.get(source.cache_semantics.policy, :storage) != :deny

  defp source_storable?(record, source), do: SourceCache.storable?(record, source)

  defp input(%Context{input_key: nil} = context), do: generate(context)

  defp input(%Context{acquisition: %{response: %Source.Response{}}} = context),
    do: generate(context)

  # A request without the original's bytes joins its image's flight before
  # fetching them, so it fetches them only to make the image.
  defp input(context), do: coalesce(context, &fetch_input/1)

  defp fetch_input(context) do
    case SourceCache.input(
           context.source,
           context.input_key,
           context.acquisition.record,
           preparation(context),
           context.config
         ) do
      {:ok, acquisition} ->
        {:ok, current(context, %{acquisition | lease: context.acquisition.lease}),
         acquisition.lease}

      {:error, _reason} = error ->
        error
    end
  end

  defp open_with_lease(context, lease, lookup) do
    attach_lease(open_current(context, lookup), lease)
  catch
    kind, reason ->
      SourceCache.release(lease)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp attach_lease({:ok, %Output{extra_lease: nil} = output}, lease),
    do: {:ok, %{output | extra_lease: lease}}

  defp attach_lease({:ok, %Output{} = output}, lease) do
    # A refreshed record without a body may need a second input lease.
    SourceCache.release(lease)
    {:ok, output}
  end

  defp attach_lease({:error, _reason} = error, lease) do
    SourceCache.release(lease)
    error
  end

  defp generate(context), do: coalesce(context, &{:ok, &1, nil})

  # `fetch` gives the context with the original's bytes, and the lease on
  # them, or an error. It runs only when this request makes the image.
  defp coalesce(context, fetch) do
    case {Keyword.get(context.config, :cache), storable?(context)} do
      {nil, _} ->
        make(context, fetch, nil, false)

      {_, false} ->
        make(context, fetch)

      {cache, true} ->
        join_output(context, cache, fetch)
    end
  end

  defp join_output(context, cache, fetch) do
    case join_flight(context, cache, context.representation.cache_key.hash) do
      {:leader, lease} -> make_leading(context, fetch, lease)
      :none -> make(context, fetch)
      :ready -> cached_or_make(context, fetch)
      :bypass -> make(context, fetch)
      # Another request's image wasn't stored in time, so the disk is slow:
      # this render isn't stored, so it doesn't add to the writes.
      {:bypass, :deadline} -> make(context, fetch, nil, false)
    end
  end

  # A low-priority request may wait on a flight but never leads one, so a
  # normal request for the same image never waits behind its queue turn.
  defp join_flight(%{request: %{priority: :low}} = context, cache, key),
    do: Cache.OutputWork.follow(cache, key, context.config)

  defp join_flight(context, cache, key),
    do: Cache.OutputWork.join(cache, key, context.config)

  defp cached_or_make(context, fetch) do
    case lookup(context, &Cache.recheck_entry/2) do
      {:hit, output} -> {:ok, output}
      :miss -> make(context, fetch)
    end
  end

  # An original that changed since its record makes an image with another
  # key, so the flight joined for the old key lets its waiters go.
  defp lease_for_key(context, fetched, lease) do
    case fetched.representation.cache_key == context.representation.cache_key do
      true ->
        lease

      false ->
        Cache.OutputWork.complete(lease, :bypass)
        nil
    end
  end

  defp make_leading(context, fetch, lease) do
    result =
      case lookup(context, &Cache.recheck_entry/2) do
        {:hit, output} -> {:ok, output}
        :miss -> make(context, fetch, lease)
      end

    case result do
      {:ok, %Output{value: {:stream, _}}} -> :ok
      {:ok, _output} -> Cache.OutputWork.complete(lease, :ready)
      {:error, _reason} -> Cache.OutputWork.complete(lease, :bypass)
    end

    result
  catch
    kind, reason ->
      Cache.OutputWork.complete(lease, :bypass)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp make(context, fetch, lease \\ nil, store? \\ true) do
    with {:ok, fetched, input_lease} <- fetch.(context) do
      lease = lease_for_key(context, fetched, lease)

      try do
        attach_lease(generate_uncoalesced(fetched, lease, store?), input_lease)
      catch
        kind, reason ->
          SourceCache.release(input_lease)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp generate_uncoalesced(context, lease, store?) do
    with {:ok, watermark_inputs} <- watermark_inputs(context) do
      session = [output_lease: lease]
      key = if store? and storable?(context), do: context.representation.cache_key
      generate(context, watermark_inputs, session, key)
    end
  end

  # The encode of an overlapped decode continues that turn's deadline, at the
  # front of the pool's queue.
  defp continuation(config, %{processing_deadline: deadline}) when is_integer(deadline),
    do: Keyword.put(config, :processing_continuation, deadline)

  defp continuation(config, _acquisition), do: config

  # Where the stream spools output a slow client hasn't read yet. Without a
  # private staging directory, it keeps pace with the client instead.
  defp spool_path do
    dir = Staging.dir()

    case Staging.private_dir(dir) do
      :ok -> Staging.temporary_path(dir)
      :error -> nil
    end
  end

  # An overlapped preparation that failed answers with its error, without
  # waiting for another processing slot.
  defp generate(%Context{acquisition: %{processing: {:error, _reason} = error}}, _, _, _),
    do: error

  defp generate(%Context{request: %{output: %{terminal: :image}}} = context, inputs, session, key) do
    config = context.config

    build =
      case context.acquisition.processing do
        # An overlapped preparation that found a skipped source leaves the
        # completed source to be streamed unchanged.
        processing when processing in [nil, {:ok, :skipped}] ->
          Processing.build_fun(
            context.request,
            decode_input(context),
            context.policy,
            config,
            inputs
          )

        result ->
          Processing.resume_fun(result, context.acquisition.source_bytes, config)
      end

    session = Keyword.put(session, :spool_path, spool_path())

    with {:ok, stream} <-
           Delivery.stream(build, key, continuation(config, context.acquisition), session) do
      output = output(context, {:stream, stream}, :miss, nil)
      {:ok, %Output{output | degraded?: degraded?(stream.resolved_output)}}
    end
  end

  defp generate(context, inputs, session, key) do
    config = context.config

    {pooled, total} =
      Timing.measure(fn ->
        ProcessingPool.run(
          Keyword.get(config, :processing_pool),
          fn -> render_terminal(context, config, inputs) end,
          config
        )
      end)

    with {:rendered, result} <- pooled,
         {:ok, type, data, degraded?} <- result do
      body =
        if context.request.output.terminal == :info, do: JSON.encode_to_iodata!(data), else: data

      body = IO.iodata_to_binary(body)
      debug = DebugBuilder.build_terminal(Executor.operation_names(context.request), total)

      store_body(
        if(degraded?, do: nil, else: key),
        type,
        body,
        [cost_us: Cache.Cost.terminal(context.request.output.terminal), debug: debug],
        Keyword.get(session, :output_lease),
        config
      )

      output = output(context, {:body, body, type, debug}, :miss, nil)
      {:ok, %Output{output | degraded?: degraded?}}
    end
  end

  defp render_terminal(context, config, inputs),
    do: {:rendered, Terminal.render(decode_input(context), context.request, config, inputs)}

  defp degraded?(%Resolved{degraded?: degraded?}), do: degraded?
  defp degraded?(_skipped), do: false

  defp decode_input(context), do: context.acquisition.response || context.source

  defp store_body(nil, _type, _body, _facts, _lease, _config), do: :ok

  # The writer takes the lease with the body, so waiters wake when it's
  # stored. The leader's own completion then does nothing.
  defp store_body(key, type, body, facts, lease, config) do
    key
    |> Cache.open_sink({:complete_body, type}, facts, config)
    |> Cache.write_chunk(body, config)
    |> Cache.commit_sink(config, lease)

    :ok
  end

  defp output(context, value, cache, time),
    do: %Output{context: context, value: value, cache: cache, cache_us: time}

  def close_output(%Output{} = output) do
    case output.value do
      {:entry, entry} -> Cache.Entry.close(entry)
      {:stream, stream} -> stream.cancel.()
      {:body, _, _, _} -> :ok
    end
  after
    SourceCache.release(output.extra_lease)
  end

  @doc """
  The cached input state that bounds response freshness: the main source's,
  or the most restrictive among it and the watermark assets.
  """
  def source_state(context) do
    now = SourceCache.now(context.config)

    [{context.acquisition.record, context.source.cache_semantics}]
    |> Enum.concat(Enum.map(context.watermarks, &{&1.record, &1.source.cache_semantics}))
    |> Enum.reject(fn {record, _semantics} -> is_nil(record) end)
    |> Enum.map(fn {record, semantics} -> record_state(record, semantics, now) end)
    |> case do
      [] -> nil
      states -> {combine(states, now), now}
    end
  end

  # The earliest freshness deadline (with its age), the earliest stale
  # deadline, and the strictest revalidation, so the response is never cached
  # longer or more loosely than one of its sources allows.
  defp combine(states, now) do
    %{
      Enum.min_by(states, &freshness(&1, now))
      | stale_until: states |> Enum.map(& &1.stale_until) |> Enum.min_by(&deadline/1),
        revalidation: states |> Enum.map(& &1.revalidation) |> Enum.max_by(&strictness/1)
    }
  end

  defp deadline(nil), do: {0, 0}
  defp deadline(:infinity), do: {2, 0}
  defp deadline(seconds), do: {1, seconds}

  defp strictness(:none), do: 0
  defp strictness(:stale), do: 1
  defp strictness(:always), do: 2

  defp record_state(record, semantics, now) do
    age =
      case record.origin do
        nil ->
          max(0, now - record.received_at)

        origin ->
          Source.CacheState.current_age(
            origin.headers,
            {origin.requested_at, origin.received_at},
            now
          )
      end

    Map.put(Source.Record.state(record, semantics), :age, age)
  end

  # Unstorable state wins, then the earliest freshness deadline.
  defp freshness(%{storable?: false}, _now), do: {0, 0}
  defp freshness(%{fresh_until: nil}, _now), do: {1, 0}
  defp freshness(%{fresh_until: :infinity}, _now), do: {3, 0}
  defp freshness(%{fresh_until: deadline}, now), do: {2, deadline - now}

  defp refresh(context) do
    Cache.Work.refresh(
      {:output, context.representation.cache_key.hash},
      fn ->
        Telemetry.span(
          context.config,
          [:cache, :refresh],
          %{pool: :input},
          fn ->
            result = refresh_current(context)
            {result, %{result: refresh_result(result)}}
          end
        )
      end,
      context.config
    )
  end

  defp refresh_result({:ok, _}), do: :ok
  defp refresh_result({:error, _} = error), do: Telemetry.request_result(error)

  defp refresh_current(context) do
    with {:ok, current} <- acquire(%{context | stale?: false}, context.acquisition.record) do
      try do
        # The request that started the refresh already counted its lookup.
        with {:ok, output} <- open_current(current, &Cache.recheck_entry/2) do
          try do
            Output.consume(output)
          after
            close_output(output)
          end
        end
      after
        close(current)
      end
    end
  end

  defp detector_identity(request, config) do
    face? = Enum.any?(request.groups, &(&1.guide == {:smart, :face_assist}))

    classes =
      case {Processing.explicit_detector_classes(request), face?} do
        {:all, _} -> :all
        {nil, false} -> nil
        {nil, true} -> ["face"]
        {classes, false} -> classes
        {classes, true} -> Enum.sort(Enum.uniq(["face" | classes]))
      end

    case classes do
      nil ->
        nil

      classes ->
        Transform.detector_identity(Keyword.fetch!(config, :detector), classes: classes)
    end
  end
end
