defmodule ImagePipe.Execution do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Delivery,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Processing,
      ImagePipe.ProcessingPool,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [Context, Inputs, Output]

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Delivery
  alias ImagePipe.Execution.{Context, Identity, Output, SourceCache}
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Response, as: PlanResponse
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

  def prepare(request, source, policy, inputs, config) do
    material = identity_material(request, policy, inputs, config)

    context = %Context{
      request: request,
      source: source,
      policy: policy,
      material: material,
      config: config,
      representation:
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)
    }

    case SourceCache.enabled?(source, config) do
      true -> prepare_remote(context)
      false -> {:ok, context}
    end
  end

  defp prepare_remote(context) do
    with {:ok, source, fetch_context} <-
           Source.prepare_cache_context(context.source, context.config) do
      key = Representation.input_key(source.identity, context.material, fetch_context)

      material = %{
        context.material
        | storage_only: [{:source_partition, key.hash} | context.material.storage_only]
      }

      context = %{context | source: source, input_key: key, material: material}

      record =
        SourceCache.trusted_record(source, context.config) ||
          SourceCache.lookup(source, key, context.config)

      case SourceCache.status(record, source, context.config) do
        :fresh -> {:ok, current(context, record, nil, nil)}
        :stale -> {:ok, %{current(context, record, nil, nil) | stale?: true}}
        _ -> acquire(context, record)
      end
    end
  end

  defp acquire(context, record) do
    case SourceCache.acquire(context.source, context.input_key, record, context.config, false) do
      {:ok, record, response, lease} -> {:ok, current(context, record, response, lease)}
      {:error, _reason} = error -> error
    end
  end

  defp current(context, record, response, lease) do
    %{
      context
      | record: record,
        response: response,
        lease: lease,
        stale?: false,
        representation:
          Representation.build(context.source.identity, context.material, record.byte_identity)
    }
  end

  # Prepare owns its source lease; callers close it after their conditional gate
  # and output consumption. Output owns leases acquired later by open/1.
  def close(%Context{lease: lease}), do: SourceCache.release(lease)

  def open(%Context{stale?: true} = context) do
    case lookup(context) do
      {:hit, output} ->
        refresh(context)
        {:ok, output}

      :miss ->
        with {:ok, current} <- acquire(context, context.record) do
          open_with_lease(current, current.lease)
        end
    end
  end

  def open(%Context{} = context), do: open_current(context)

  defp open_current(context) do
    case lookup(context) do
      {:hit, output} -> {:ok, output}
      :miss -> input(context)
    end
  end

  defp lookup(context) do
    case storable?(context) do
      true ->
        {result, time} =
          Timing.measure(fn ->
            Cache.lookup_entry(context.representation.cache_key, context.config)
          end)

        checked_hit(result, context, time)

      false ->
        :miss
    end
  end

  defp checked_hit({:hit, entry}, context, time) do
    case {context.request.output.terminal, entry.representation} do
      {:image, {:complete_body, _}} ->
        Cache.Entry.close(entry)
        :miss

      {:image, _} ->
        {:hit, output(context, {:entry, entry}, :hit, time)}

      {_, {:complete_body, _}} ->
        {:hit, output(context, {:entry, entry}, :hit, time)}

      _ ->
        Cache.Entry.close(entry)
        :miss
    end
  end

  defp checked_hit(_miss, _context, _time), do: :miss

  defp storable?(%Context{record: nil, source: source}), do: source.internal_cache == :enabled
  defp storable?(context), do: SourceCache.storable?(context.record, context.source)

  defp input(%Context{input_key: nil} = context), do: generate(context)
  defp input(%Context{response: %Source.Response{}} = context), do: generate(context)

  defp input(context) do
    case SourceCache.input(context.source, context.input_key, context.record, context.config) do
      {:ok, record, response, lease} ->
        context = current(context, record, response, context.lease)
        generate_leased(context, lease)

      {:error, _reason} = error ->
        error
    end
  end

  defp generate_leased(context, lease) do
    attach_lease(generate(context), lease)
  catch
    kind, reason ->
      SourceCache.release(lease)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp open_with_lease(context, lease) do
    attach_lease(open_current(context), lease)
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

  defp generate(context) do
    case {Keyword.get(context.config, :cache), storable?(context)} do
      {nil, _} -> generate_uncoalesced(context)
      {_, false} -> generate_uncoalesced(context)
      {cache, true} -> coalesce(context, cache)
    end
  end

  defp coalesce(context, cache) do
    case Cache.OutputWork.join(cache, context.representation.cache_key.hash, context.config) do
      {:leader, lease} -> generate_leader(context, lease)
      :ready -> cached_or_generate(context)
      :bypass -> generate_uncoalesced(context)
    end
  end

  defp cached_or_generate(context) do
    case lookup(context) do
      {:hit, output} -> {:ok, output}
      :miss -> generate_uncoalesced(context)
    end
  end

  defp generate_leader(context, lease) do
    result =
      case lookup(context) do
        {:hit, output} -> {:ok, output}
        :miss -> generate_uncoalesced(context, lease)
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

  defp generate_uncoalesced(context, lease \\ nil) do
    config = prepared_config(context)
    config = Keyword.put(config, :output_lease, lease)
    key = if storable?(context), do: context.representation.cache_key
    result = generate(context, config, key)
    finish(context, result)
    result
  end

  defp generate(%Context{request: %{output: %{terminal: :image}}} = context, config, key) do
    build = Processing.build_fun(context.request, context.source, context.policy, config)

    with {:ok, stream} <-
           Delivery.stream(self(), build, key, response_meta(context.request), config) do
      stream = %{stream | next: fn -> next(stream, context) end}
      {:ok, output(context, {:stream, stream}, :miss, nil)}
    end
  end

  defp generate(context, config, key) do
    {result, cost} =
      Timing.measure(fn ->
        ProcessingPool.run(
          Keyword.get(config, :processing_pool),
          fn -> Terminal.render(context.source, context.request, config) end,
          config
        )
      end)

    with {:ok, type, data} <- result do
      body =
        if context.request.output.terminal == :info, do: JSON.encode_to_iodata!(data), else: data

      body = IO.iodata_to_binary(body)
      debug = DebugBuilder.build_terminal(Executor.operation_names(context.request), cost)
      store_body(key, type, body, debug, cost, config)
      {:ok, output(context, {:body, body, type, debug}, :miss, nil)}
    end
  end

  defp next(stream, context) do
    result = stream.next.()
    finish(context, result)
    result
  end

  defp prepared_config(%Context{record: nil, config: config}), do: config

  defp prepared_config(context),
    do:
      context.config
      |> Keyword.put(:prepared_source, context.response)
      |> Keyword.put(:source_record, context.record)

  defp store_body(nil, _type, _body, _debug, _cost, _config), do: :ok

  defp store_body(key, type, body, debug, cost, config) do
    key
    |> Cache.open_sink(
      {:complete_body, type},
      Keyword.merge(config, cost_us: cost, debug_info: debug)
    )
    |> Cache.write_chunk(body, config)
    |> Cache.commit_sink(config)

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

  def finish(%Context{input_key: nil}, _result), do: :ok

  def finish(context, {:error, {:decode, _reason}}),
    do: SourceCache.invalidate(context.input_key, context.config)

  def finish(context, {:error, :source_format_required}),
    do: SourceCache.invalidate(context.input_key, context.config)

  def finish(_context, _result), do: :ok

  def source_state(%Context{record: nil}), do: nil

  def source_state(context) do
    record = context.record
    now = SourceCache.now(context.config)

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

    {Map.put(Source.Record.state(record, context.source.cache_semantics), :age, age), now}
  end

  defp refresh(context) do
    Cache.Work.refresh(
      {:output, context.representation.cache_key.hash},
      fn ->
        Telemetry.span(
          Telemetry.telemetry_opts(context.config),
          [:cache, :refresh],
          %{pool: :input},
          fn ->
            result = refresh_current(context)
            {result, %{result: refresh_result(result)}}
          end
        )
      end,
      Telemetry.telemetry_opts(context.config)
    )
  end

  defp refresh_result({:ok, _}), do: :ok
  defp refresh_result({:error, _} = error), do: Telemetry.request_result(error)

  defp refresh_current(context) do
    with {:ok, current} <- acquire(%{context | stale?: false}, context.record) do
      try do
        with {:ok, output} <- open(current) do
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

  def response_meta(%Request{} = request),
    do: %PlanResponse{
      filename: request.filename,
      disposition: if(request.attachment?, do: :attachment, else: :inline),
      debug?: request.debug?
    }

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
        Transform.detector_identity(
          Keyword.get(config, :detector, :default),
          Keyword.put(config, :classes, classes)
        )
    end
  end
end
