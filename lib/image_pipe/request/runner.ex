defmodule ImagePipe.Request.Runner do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Error
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Response
  alias ImagePipe.Request.RenderRunner
  alias ImagePipe.Request.SourceSession
  alias ImagePipe.Request.SourceSession.Prepared, as: SessionPrepared
  alias ImagePipe.Request.SourceSession.Request, as: SessionRequest
  alias ImagePipe.Request.SourceSessionSupervisor
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Transform

  @type hit_debug() :: %{cache_key: String.t(), cache_serve_us: non_neg_integer()}

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t(), hit_debug()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}

  @type error() ::
          {:processing, term(), [{String.t(), String.t()}]}

  @spec run(
          Plug.Conn.t(),
          Plan.t(),
          Source.Resolved.t(),
          CacheHeaders.t(),
          keyword()
        ) ::
          {:ok, delivery()} | {:error, error()}
  def run(
        _conn,
        %Plan{render: {:custom, _module, params}} = plan,
        %Source.Resolved{} = resolved_source,
        %CacheHeaders{} = prepared_http_cache,
        opts
      ) do
    case RenderRunner.run(plan, resolved_source, opts) do
      {:ok, {content_type, body}} ->
        offers = Map.get(params, :offers, [])
        {:ok, {:rendered, content_type, body, offers, prepared_http_cache}}

      {:error, reason} ->
        {:error, {:processing, {:render, reason}, []}}
    end
  end

  def run(
        conn,
        %Plan{} = plan,
        %Source.Resolved{} = resolved_source,
        %CacheHeaders{} = prepared_http_cache,
        opts
      ) do
    run_with_cache_config(conn, plan, resolved_source, prepared_http_cache, opts)
  end

  defp run_with_cache_config(
         conn,
         plan,
         %Source.Resolved{internal_cache: :disabled} = resolved_source,
         prepared_http_cache,
         opts
       ),
       do: process_prepared_stream(conn, plan, resolved_source, nil, prepared_http_cache, opts)

  defp run_with_cache_config(
         conn,
         plan,
         %Source.Resolved{internal_cache: :enabled} = resolved_source,
         prepared_http_cache,
         opts
       ) do
    {result, cache_serve_us} =
      Timing.measure(fn -> lookup_cache(conn, plan, resolved_source, opts) end)

    case result do
      :disabled ->
        process_prepared_stream(conn, plan, resolved_source, nil, prepared_http_cache, opts)

      {:hit, %Key{} = key, %Entry{} = entry} ->
        hit_debug = %{cache_key: key.hash, cache_serve_us: cache_serve_us}
        {:ok, {:cache_entry, entry, plan.response, prepared_http_cache, hit_debug}}

      {:miss, %Key{} = key} ->
        process_cacheable_miss(conn, plan, resolved_source, key, prepared_http_cache, opts)

      {:miss, %Key{} = key, {:cache_read, _error}} ->
        process_cacheable_miss(conn, plan, resolved_source, key, prepared_http_cache, opts)
    end
  end

  defp lookup_cache(conn, plan, resolved_source, opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:cache, :lookup],
      cache_lookup_metadata(opts),
      fn ->
        result =
          case Keyword.get(opts, :cache) do
            nil -> :disabled
            _cache -> Cache.lookup(conn, plan, resolved_source.identity, opts)
          end

        {result, cache_lookup_stop_metadata(result)}
      end
    )
  end

  defp process_cacheable_miss(
         conn,
         plan,
         resolved_source,
         %Key{} = key,
         prepared_http_cache,
         opts
       ) do
    process_prepared_stream(conn, plan, resolved_source, key, prepared_http_cache, opts)
  end

  defp process_prepared_stream(conn, plan, resolved_source, cache_key, prepared_http_cache, opts) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.ensure_capable(policy, opts) do
      :ok ->
        request = %SessionRequest{
          plan: plan,
          resolved_source: resolved_source,
          output_policy: policy,
          opts: opts,
          cache_key: cache_key
        }

        supervisor = Keyword.get(opts, :source_session_supervisor, SourceSessionSupervisor)

        # Capture the active trace context from THIS (request) process and pass it as
        # data: the SourceSession/Producer spawn does not inherit our process stack.
        trace_context = Trace.Stack.context()

        case SourceSessionSupervisor.start_session(supervisor, request,
               trace_context: trace_context
             ) do
          {:ok, session} ->
            prepare_supervised_session(
              session,
              supervisor,
              plan.response,
              policy,
              prepared_http_cache,
              cache_key
            )

          {:error, reason} ->
            {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
        end

      {:error, reason} ->
        {:error, {:processing, reason, policy.headers}}
    end
  end

  defp prepare_supervised_session(
         session,
         supervisor,
         %Response{} = response,
         %Policy{} = policy,
         %CacheHeaders{} = prepared_http_cache,
         cache_key
       ) do
    case SourceSession.prepare(session) do
      {:ok, %SessionPrepared{} = prepared} ->
        case prepared_stream(session, supervisor, prepared, response, cache_key) do
          {:ok, %PreparedStream{} = prepared_stream} ->
            {:ok, {:prepared_stream, prepared_stream, response, prepared_http_cache}}

          {:error, reason} ->
            _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
            {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
        end

      {:error, reason} ->
        _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
        {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
    end
  end

  defp prepared_stream(
         session,
         supervisor,
         %SessionPrepared{} = prepared,
         %Response{} = response,
         cache_key
       ) do
    with :ok <- check_first_chunk(prepared.first_chunk),
         {:ok, content_disposition} <-
           Response.content_disposition(response, prepared.content_type) do
      {:ok,
       %PreparedStream{
         first_chunk: prepared.first_chunk,
         content_type: prepared.content_type,
         headers: prepared.headers ++ [{"content-disposition", content_disposition}],
         next: fn -> SourceSession.next(session) end,
         cancel: fn -> cancel_supervised_session(supervisor, session) end,
         resolved_output: prepared.resolved_output,
         debug: prepared.debug,
         cache_key: key_hash(cache_key)
       }}
    else
      {:error, reason} ->
        _cancel_result = SourceSession.cancel(session)
        {:error, reason}
    end
  end

  defp cancel_supervised_session(supervisor, session) do
    result = SourceSession.cancel(session)
    _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)

    result
  end

  defp key_hash(%Key{hash: hash}), do: hash
  defp key_hash(nil), do: nil

  defp check_first_chunk(chunk) when is_binary(chunk) and byte_size(chunk) > 0, do: :ok

  defp check_first_chunk(_chunk) do
    {:error, {:encode, :empty_stream}}
  end

  defp normalize_session_prepare_error({:session, reason}) do
    {:encode, RuntimeError.exception("source session failed: #{inspect(reason)}"), []}
  end

  defp normalize_session_prepare_error(reason), do: reason

  defp cache_lookup_metadata(opts) do
    cache =
      case Keyword.get(opts, :cache) do
        nil -> :disabled
        _cache -> nil
      end

    %{cache: cache}
  end

  defp cache_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}
  defp cache_lookup_stop_metadata({:hit, %Key{}, %Entry{}}), do: %{result: :ok, cache: :hit}
  defp cache_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp cache_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Error.tag(error)}

  @doc """
  Returns `opts` augmented with the resolved detector identity when the plan's
  output depends on the configured detector — `{:detect, _}` guides or
  `{:smart, :face_assist}` (face-assist blends the detected face centroid into
  the attention point). The identity is folded in as the `:detector_identity`
  key option so a detector/model change (or availability change) yields a
  different cache key instead of colliding.

  The request entry point (the plug) calls this once, before `HTTPCache.prepare`
  and `Runner.run/5`, so the ETag and cache key both derive from a single
  detector resolution.
  """
  def with_detector_identity(opts, plan) do
    detect_classes = Plan.detect_classes(plan)

    if detect_classes != nil or Plan.face_assist?(plan) do
      opts_with_classes = Keyword.put(opts, :classes, detect_classes || ["face"])

      case Transform.detector_identity(Keyword.get(opts, :detector, :default), opts_with_classes) do
        nil -> opts
        identity -> Keyword.put(opts, :detector_identity, identity)
      end
    else
      opts
    end
  end
end
