defmodule ImagePipe.Request.Runner do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Delivery
  alias ImagePipe.Error
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Response
  alias ImagePipe.Request.DeliveryBuild
  alias ImagePipe.Request.HTTPCache
  alias ImagePipe.Request.RenderRunner
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  @type hit_debug() :: %{cache_key: String.t(), cache_serve_us: non_neg_integer()}

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t(), hit_debug()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}

  @type error() ::
          {:processing, term(), [{String.t(), String.t()}]}

  @type not_modified() :: {:not_modified, CacheHeaders.t()}

  @spec run(
          Plug.Conn.t(),
          Plan.t(),
          Source.Resolved.t(),
          CacheHeaders.t(),
          keyword()
        ) ::
          {:ok, delivery()} | not_modified() | {:error, error()}
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
        # A cache hit is the proof, absent pre-fetch, that a current representation
        # exists for this key — so this is the only place `If-None-Match: *` may be
        # honored (independent of whether an ETag was generated).
        if HTTPCache.if_none_match_wildcard?(conn) do
          {:not_modified, prepared_http_cache}
        else
          hit_debug = %{cache_key: key.hash, cache_serve_us: cache_serve_us}
          {:ok, {:cache_entry, entry, plan.response, prepared_http_cache, hit_debug}}
        end

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
        build_fun = DeliveryBuild.build_fun(plan, resolved_source, policy, opts)

        case Delivery.stream(self(), build_fun, cache_key, plan.response, opts) do
          {:ok, %PreparedStream{} = prepared_stream} ->
            {:ok, {:prepared_stream, prepared_stream, plan.response, prepared_http_cache}}

          {:error, reason} ->
            {:error, {:processing, normalize_delivery_error(reason), policy.headers}}
        end

      {:error, reason} ->
        {:error, {:processing, reason, policy.headers}}
    end
  end

  defp normalize_delivery_error({:session, reason}) do
    {:encode, RuntimeError.exception("delivery session failed: #{inspect(reason)}"), []}
  end

  defp normalize_delivery_error(reason), do: reason

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
