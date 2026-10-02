defmodule ImagePipe.Response.CachePolicy do
  @moduledoc false
  # The generated HTTP cache-header policy: given a built
  # `%ImagePipe.Representation{}` and a few facts about the resolved source,
  # decides which `Cache-Control`, `ETag`, and `Vary` headers this response
  # may carry.
  #
  # Two rules shape every decision:
  #
  #   * the host wins — a `Set-Cookie`, a `Vary: *`, a `Cache-Control` the
  #     host set itself, or a host-supplied `ETag` suppresses the matching
  #     generated header rather than overwriting it;
  #   * a source with no byte identity may never be stored — it falls back to
  #     `Cache-Control: no-store` and contributes no validator, so a
  #     conditional GET can never revalidate against content whose bytes may
  #     have changed.
  #
  # The `ETag` itself is never computed here: it belongs to the
  # representation. This module only decides whether to emit it.

  import Plug.Conn, only: [get_resp_header: 2]

  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Telemetry

  @generated_cache_control "public, max-age=31536000, immutable"
  @no_store "no-store"

  @typedoc """
  The slice of the resolved source this policy reads. A plain map, projected
  by the caller: this boundary owns response delivery and must not depend on
  `ImagePipe.Source`.
  """
  @type source_facts :: %{
          optional(:storage) => :origin | :allow | :deny,
          byte_identity: {:strong, term()} | :none,
          stable?: boolean(),
          source_mount: atom() | nil,
          source_kind: :path | :url | :object | :input
        }

  @typedoc """
  The resolved `http_cache` value: what this response's headers may carry.
  """
  @type mode :: :validators | :auto | :public | :private

  @doc """
  Resolves a source's `http_cache` against the mount's: any source value
  other than `:inherit` replaces the mount's.
  """
  @spec mode(:inherit | mode(), keyword()) :: mode()
  def mode(:inherit, config), do: Keyword.get(config, :http_cache, :validators)
  def mode(mode, _config), do: mode

  @spec generate(Plug.Conn.t(), Representation.t(), source_facts(), mode(), keyword()) ::
          CacheHeaders.t()
  def generate(
        %Plug.Conn{} = conn,
        %Representation{} = representation,
        source_facts,
        mode,
        config
      ) do
    {prepared, fallback_reason} = prepare(conn, representation, source_facts, mode, config)

    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :prepare],
      %{},
      %{
        effective_mode: mode,
        byte_identity: byte_identity_kind(source_facts.byte_identity),
        etag: etag_emitted?(prepared.etag)
      }
    )

    emit_fallback_telemetry(fallback_reason, source_facts, config)

    prepared
  end

  # `:validators` carries only what the representation itself implies: its
  # ETag, or `no-store` when the bytes have no identity or the source denies
  # storage.
  defp prepare(_conn, representation, source_facts, :validators, _config) do
    case Map.get(source_facts, :storage) do
      :deny ->
        {CacheHeaders.from_representation(%{representation | etag: nil, no_store?: true}), nil}

      _permission ->
        {CacheHeaders.from_representation(representation),
         if(representation.no_store?, do: :missing_byte_identity)}
    end
  end

  defp prepare(conn, representation, source_facts, mode, config) do
    representation_headers = representation_headers(conn, representation)

    {headers, etag, fallback_reason} =
      generated_cache_headers(conn, representation, source_facts, representation_headers)

    headers =
      Enum.map(headers, fn
        {"cache-control", @generated_cache_control} ->
          {"cache-control", "#{visibility(mode, config)}, max-age=31536000, immutable"}

        header ->
          header
      end)

    {%CacheHeaders{
       representation_headers: representation_headers,
       headers: headers,
       etag: etag
     }, fallback_reason}
  end

  @doc false
  def limit_to_source(prepared, conn, facts, now, mode, config) do
    cond do
      not facts.storable? ->
        %{
          prepared
          | etag: nil,
            headers: [{"cache-control", "no-store"}],
            representation_headers: [
              {"cache-control", "no-store"} | prepared.representation_headers
            ]
        }

      facts.fresh_until == :infinity ->
        prepared

      CacheHeaders.host_cache_control?(get_resp_header(conn, "cache-control")) ->
        prepared

      prepared.etag == nil ->
        prepared

      true ->
        limit_headers(prepared, facts, now, mode, config)
    end
  end

  defp limit_headers(prepared, facts, now, mode, config) do
    visibility = visibility(mode, config)
    {ttl, stale} = source_lifetimes(facts, now)
    control = "#{visibility}, max-age=#{ttl}"

    control =
      case facts.revalidation do
        :none -> control
        :always -> control <> ", no-cache"
        :stale -> control <> ", must-revalidate"
      end

    control =
      case stale do
        0 -> control
        seconds -> control <> ", stale-while-revalidate=#{seconds}"
      end

    headers =
      Enum.reject(prepared.headers, fn {name, _} -> name in ["cache-control", "age"] end)

    %{
      prepared
      | headers: headers ++ [{"cache-control", control}, {"age", Integer.to_string(facts.age)}]
    }
  end

  # `Vary` can't name cookies, so a cookie-partitioned response isn't safe for
  # a shared cache unless the host says so with `:public`.
  defp visibility(:public, _config), do: "public"
  defp visibility(:private, _config), do: "private"

  defp visibility(_auto_or_validators, config) do
    if Enum.any?(Keyword.get(config, :storage_inputs, []), &match?({:cookie, _}, &1)),
      do: "private",
      else: "public"
  end

  defp source_lifetimes(%{fresh_until: nil}, _now), do: {0, 0}

  defp source_lifetimes(facts, now) do
    {max(0, facts.fresh_until - now + facts.age), max(0, facts.stale_until - facts.fresh_until)}
  end

  @doc """
  Emits `[:http_cache, :conditional, :match]`. The runner calls this at the
  conditional gate when the policy owns the headers — the policy owns the
  event, `ImagePipe.Response.Conditional` owns the matching.
  """
  @spec conditional_matched(Plug.Conn.t(), keyword()) :: :ok
  def conditional_matched(%Plug.Conn{method: method}, config) do
    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :conditional, :match],
      %{},
      %{method: conditional_method(method)}
    )
  end

  defp conditional_method("GET"), do: :get
  defp conditional_method("HEAD"), do: :head

  defp generated_cache_headers(
         %Plug.Conn{method: method},
         _representation,
         _source_facts,
         _representation_headers
       )
       when method not in ["GET", "HEAD"],
       do: {[], nil, nil}

  defp generated_cache_headers(conn, representation, source_facts, representation_headers) do
    cond do
      has_set_cookie?(conn) ->
        {[], nil, nil}

      vary_star?(conn) or vary_star?(representation_headers) ->
        {[], nil, nil}

      host_has_no_store?(conn) ->
        {[], nil, nil}

      Map.get(source_facts, :storage) == :deny ->
        denied_storage_headers(conn)

      has_host_cache_control?(conn) ->
        generated_etag_only(conn, representation)

      true ->
        generated_cache_control_and_etag(conn, representation, source_facts)
    end
  end

  defp denied_storage_headers(conn) do
    case has_host_cache_control?(conn) do
      true -> {[], nil, nil}
      false -> {[{"cache-control", @no_store}], nil, nil}
    end
  end

  defp generated_cache_control_and_etag(conn, representation, source_facts) do
    case policy_etag(conn, representation) do
      {:etag, etag} ->
        {[{"cache-control", @generated_cache_control}, {"etag", etag}], etag, nil}

      :not_generated ->
        cache_control_without_etag(conn, source_facts)
    end
  end

  defp cache_control_without_etag(_conn, %{byte_identity: :none}) do
    {[{"cache-control", @no_store}], nil, :missing_byte_identity}
  end

  defp cache_control_without_etag(conn, %{byte_identity: {:strong, _seed}, stable?: true}) do
    if has_resp_header?(conn, "etag"),
      do: {[{"cache-control", @generated_cache_control}], nil, nil},
      else: {[], nil, nil}
  end

  defp generated_etag_only(conn, representation) do
    case policy_etag(conn, representation) do
      {:etag, etag} -> {[{"etag", etag}], etag, nil}
      :not_generated -> {[], nil, nil}
    end
  end

  defp policy_etag(_conn, %Representation{etag: nil}), do: :not_generated

  defp policy_etag(conn, %Representation{etag: etag}) do
    cond do
      has_resp_header?(conn, "etag") -> :not_generated
      host_has_no_store?(conn) -> :not_generated
      true -> {:etag, etag}
    end
  end

  defp representation_headers(_conn, %Representation{vary: []}), do: []

  defp representation_headers(conn, %Representation{vary: names}),
    do: [{"vary", CacheHeaders.merge_vary(conn, names)}]

  defp vary_star?(%Plug.Conn{} = conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.any?(fn value -> "*" in CacheHeaders.split_vary(value) end)
  end

  defp vary_star?(headers) do
    Enum.any?(headers, fn
      {"vary", value} -> "*" in CacheHeaders.split_vary(value)
      _header -> false
    end)
  end

  defp host_has_no_store?(conn) do
    conn
    |> get_resp_header("cache-control")
    |> Enum.join(",")
    |> String.downcase()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == @no_store))
  end

  defp has_resp_header?(conn, name), do: get_resp_header(conn, name) != []

  defp has_set_cookie?(%Plug.Conn{} = conn) do
    has_resp_header?(conn, "set-cookie") or conn.resp_cookies != %{}
  end

  defp has_host_cache_control?(conn) do
    CacheHeaders.host_cache_control?(get_resp_header(conn, "cache-control"))
  end

  defp byte_identity_kind({:strong, _seed}), do: :strong
  defp byte_identity_kind(:none), do: :none

  defp etag_emitted?(nil), do: false
  defp etag_emitted?(_etag), do: true

  defp emit_fallback_telemetry(nil, _source_facts, _config), do: :ok

  defp emit_fallback_telemetry(reason, source_facts, config) do
    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :fallback, :no_store],
      %{},
      %{
        source_mount: source_facts.source_mount,
        source_kind: source_facts.source_kind,
        reason: reason
      }
    )
  end
end
