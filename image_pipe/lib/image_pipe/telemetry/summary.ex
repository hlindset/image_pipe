defmodule ImagePipe.Telemetry.Summary do
  @moduledoc false
  # Builds the `[:request, :summary]` event: one record of what a request did,
  # emitted when its `[:request]` span stops.
  #
  # Stages run in several processes, so their fields travel to the request
  # process as messages to an alias it creates when the request starts. The
  # alias rides in `RequestContext`, which every process that serves the
  # request adopts. When the request stops, the request process removes the
  # alias, so a message sent later (from a worker that outlived its request)
  # is dropped by the VM, then collects the messages already delivered.
  # Messages from one process arrive in the order it sent them, and workers
  # send their fields before they return results to the request, so the
  # request process has them all by then.
  #
  # Nothing is collected unless something is attached to the summary event
  # when the request starts.

  @alias_key {__MODULE__, :alias}
  @fields_key {__MODULE__, :fields}
  # A request inside another one in the same process, such as `ImagePipe.run/4`
  # called while a request is served, keeps the outer one's state here.
  @outer_key {__MODULE__, :outer}

  @typedoc false
  @type handle :: reference() | nil

  @doc false
  # The request's alias in this process, for `RequestContext` to carry.
  @spec current() :: handle()
  def current, do: Process.get(@alias_key)

  @doc false
  # Makes `alias` the target of this process's fields, for a process that
  # adopts a request.
  @spec adopt(handle()) :: :ok
  def adopt(nil) do
    Process.delete(@alias_key)
    :ok
  end

  def adopt(alias) do
    Process.put(@alias_key, alias)
    :ok
  end

  @doc false
  # Called at `[:request]` start in the request process. An outer request's
  # state is kept, and its fields stop until this request ends.
  @spec open([atom()], map()) :: :ok
  def open(prefix, start_metadata) do
    outer = {current(), Process.delete(@fields_key)}
    Process.put(@outer_key, [outer | Process.get(@outer_key, [])])

    case :telemetry.list_handlers(prefix ++ [:request, :summary]) do
      [] ->
        adopt(nil)

      _handlers ->
        alias = :erlang.alias()
        adopt(alias)
        Process.put(@fields_key, Map.take(start_metadata, [:method, :path]))
        :ok
    end
  end

  @doc false
  # Stops recording in a process that adopted the request for side work, such
  # as fetching a watermark, whose stages would overwrite the main source's.
  @spec ignore() :: :ok
  def ignore, do: adopt(nil)

  # Puts the outer request's state back.
  defp restore do
    case Process.get(@outer_key, []) do
      [{alias, fields} | rest] ->
        Process.put(@outer_key, rest)
        adopt(alias)
        if fields, do: Process.put(@fields_key, fields), else: Process.delete(@fields_key)

      [] ->
        adopt(nil)
        Process.delete(@fields_key)
    end

    :ok
  end

  @doc false
  # Adds fields from a process serving the request. The request process keeps
  # its own fields directly. Other processes send them to its alias. A no-op
  # outside a summarized request.
  @spec put(map()) :: :ok
  def put(fields) do
    case {Process.get(@fields_key), current()} do
      {own, _alias} when is_map(own) -> Process.put(@fields_key, merge(own, fields))
      {nil, nil} -> :ok
      {nil, alias} -> send(alias, {alias, fields})
    end

    :ok
  end

  @doc false
  # Adds the bytes of a body sent by the request process: a size, or the
  # body, measured only when a summary is open.
  @spec add_bytes(non_neg_integer() | iodata()) :: :ok
  def add_bytes(bytes) when is_integer(bytes), do: put(%{bytes: bytes})

  def add_bytes(body) do
    if current(), do: put(%{bytes: IO.iodata_length(body)}), else: :ok
  end

  @doc false
  # Records a stage's fields, from a span's stop or a one-shot event.
  @spec record([atom()], integer() | nil, map()) :: :ok
  def record(stage, duration, metadata) do
    case current() do
      nil ->
        :ok

      _alias ->
        case fields(stage, duration, metadata) do
          empty when empty == %{} -> :ok
          fields -> put(fields)
        end
    end
  end

  @doc false
  # Called after `[:request]` stops, in the request process: emits the summary
  # and forgets the request.
  @spec close([atom()], integer(), map()) :: :ok
  def close(prefix, duration, stop_metadata) do
    case {current(), Process.delete(@fields_key)} do
      {alias, fields} when is_reference(alias) and is_map(fields) ->
        :erlang.unalias(alias)
        restore()

        summary =
          alias
          |> collect(fields)
          |> Map.merge(Map.take(stop_metadata, [:result, :status, :error]))
          |> put_cache_outcome()
          |> Map.put(:duration_ms, ms(duration))

        :telemetry.execute(prefix ++ [:request, :summary], %{duration: duration}, summary)

      _no_summary ->
        restore()
    end

    :ok
  end

  @doc false
  # Forgets a request whose span raised, emitting nothing.
  @spec discard() :: :ok
  def discard do
    case current() do
      nil ->
        :ok

      alias ->
        :erlang.unalias(alias)
        _fields = collect(alias, %{})
    end

    Process.delete(@fields_key)
    restore()
  end

  defp collect(alias, fields) do
    receive do
      {^alias, more} -> collect(alias, merge(fields, more))
    after
      0 -> fields
    end
  end

  # Operations accumulate and bytes add up. Every other field keeps the last
  # value sent.
  defp merge(fields, more) do
    Map.merge(fields, more, fn
      :ops, ops, new -> ops ++ new
      :bytes, bytes, new -> bytes + new
      _key, _old, new -> new
    end)
  end

  defp put_cache_outcome(%{status: 304} = summary), do: Map.put(summary, :cache, :not_modified)

  defp put_cache_outcome(%{coalesced: true, cache: :hit} = summary),
    do: summary |> Map.delete(:coalesced) |> Map.put(:cache, :coalesced)

  defp put_cache_outcome(summary), do: Map.delete(summary, :coalesced)

  defp fields([:parse], _duration, meta),
    do:
      take(meta,
        sig_key: :sig_key_index,
        source_url: :source_url,
        watermark_source_urls: :watermark_source_urls
      )

  defp fields([:source, :resolve], _duration, meta), do: take(meta, source: :source_name)

  defp fields([:source, :fetch], duration, meta),
    do: meta |> take(source_fetch: :result) |> Map.put(:fetch_ms, ms(duration))

  defp fields([:source, :fetch_decode], duration, %{result: :ok} = meta) do
    meta
    |> take(input: :detected_source_format, input_size: :original_dims)
    |> Map.put(:decode_ms, ms(duration))
  end

  defp fields([:cache, :lookup], _duration, %{entry: :response, cache: cache}),
    do: %{cache: cache}

  defp fields([:cache, :coordination], _duration, %{operation: :output, result: :waiting}),
    do: %{coalesced: true}

  defp fields([:transform, :operation], _duration, %{result: :ok} = meta),
    do: Map.merge(%{ops: [meta.operation]}, take(meta, output_size: :dims))

  defp fields([:output, :negotiate], _duration, meta), do: take(meta, output: :output_format)
  defp fields([:output, :terminal], _duration, meta), do: take(meta, output: :terminal)

  defp fields([:encode], duration, meta),
    do: meta |> take(output: :output_format) |> Map.put(:encode_ms, ms(duration))

  defp fields([:processing, :admission], duration, meta) do
    meta
    |> take(admission: :result)
    |> Map.put(:queue_ms, ms(duration))
    |> Map.merge(if meta[:priority] == :low, do: %{priority: :low}, else: %{})
  end

  defp fields([:transform, :detect], _duration, meta), do: take(meta, detect: :result)

  defp fields([:http_cache, :fallback, :no_store], _duration, _meta), do: %{degraded: true}

  defp fields([:source, :stage], _duration, meta),
    do: take(meta, staging: :staging, staging_reason: :staging_reason)

  defp fields([:output, :clamp], _duration, meta), do: take(meta, clamped: :dimensions)

  defp fields([:encode, :search], _duration, meta),
    do: take(meta, quality: :chosen_quality, quality_search: :outcome)

  defp fields([:request, :ignored_options], _duration, meta), do: take(meta, ignored: :options)
  defp fields([:transform, :detect, :skipped], _duration, meta), do: take(meta, detect: :result)

  defp fields([:deliver], _duration, meta) do
    %{}
    |> Map.merge(if meta[:skipped], do: %{skipped: true}, else: %{})
    |> Map.merge(if meta[:result] == :client_closed, do: %{client_closed: true}, else: %{})
  end

  defp fields(_stage, _duration, _meta), do: %{}

  defp take(meta, mapping) do
    for {field, key} <- mapping,
        value = Map.get(meta, key),
        value != nil,
        into: %{},
        do: {field, value}
  end

  defp ms(nil), do: nil
  defp ms(duration), do: System.convert_time_unit(duration, :native, :millisecond)
end
