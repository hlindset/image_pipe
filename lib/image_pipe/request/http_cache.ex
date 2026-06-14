defmodule ImagePipe.Request.HTTPCache do
  @moduledoc false

  import Plug.Conn,
    only: [get_req_header: 2, get_resp_header: 2]

  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Telemetry

  @etag_schema 1
  @generated_cache_control "public, max-age=31536000, immutable"
  @no_store "no-store"

  @spec prepare(Plug.Conn.t(), Plan.t(), Resolved.t(), keyword()) :: CacheHeaders.t()
  def prepare(%Plug.Conn{} = conn, %Plan{} = plan, %Resolved{} = resolved, opts) do
    effective_mode = effective_mode(resolved, opts)
    representation_headers = representation_headers(conn, plan)

    {headers, etag, fallback_reason} =
      generated_cache_headers(conn, plan, resolved, opts, effective_mode, representation_headers)

    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:http_cache, :prepare],
      %{},
      %{
        effective_mode: effective_mode,
        byte_identity: byte_identity_kind(resolved.cache_semantics),
        etag: etag_emitted?(etag)
      }
    )

    emit_fallback_telemetry(fallback_reason, resolved, opts)

    %CacheHeaders{
      representation_headers: representation_headers,
      headers: headers,
      etag: etag
    }
  end

  @doc false
  @spec etag_schema() :: pos_integer()
  def etag_schema, do: @etag_schema

  @doc false
  @spec generated_cache_control() :: String.t()
  def generated_cache_control, do: @generated_cache_control

  @doc false
  @spec etag_material(Plug.Conn.t(), Plan.t(), term(), keyword()) :: {:ok, keyword()}
  def etag_material(conn, %Plan{} = plan, source_seed, opts) do
    {:ok, plan_material} = Key.plan_material(plan, opts)

    # The ETag is a strong byte-identity validator derived only from request
    # inputs (source seed + canonical plan + negotiated Accept), never from the
    # encoded bytes — that is what lets a conditional GET 304 before any fetch,
    # decode, encode, or cache read. Drop the cachebuster (:cache): it busts
    # storage but yields byte-identical output, so it must not move the ETag (a
    # change would force clients to re-download identical content). Vary
    # headers/cookies, which partition the cache key, are absent here for the
    # same reason. Keep this input-derived; do not make it a hash of the body.
    {:ok,
     [
       etag_schema: @etag_schema,
       source: source_seed,
       plan: Keyword.drop(plan_material, [:cache]),
       accept: accept_material(conn, plan.output, opts)
     ]}
  end

  @spec evaluate_conditional(Plug.Conn.t(), CacheHeaders.t(), keyword()) ::
          :proceed | {:not_modified, CacheHeaders.t()}
  def evaluate_conditional(
        %Plug.Conn{method: method} = conn,
        %CacheHeaders{etag: etag} = prepared,
        opts
      )
      when method in ["GET", "HEAD"] and is_binary(etag) do
    if if_none_match?(conn, etag) do
      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:http_cache, :conditional, :match],
        %{},
        %{method: conditional_method(method)}
      )

      {:not_modified, prepared}
    else
      :proceed
    end
  end

  def evaluate_conditional(%Plug.Conn{}, %CacheHeaders{}, _opts), do: :proceed

  defp conditional_method("GET"), do: :get
  defp conditional_method("HEAD"), do: :head

  defp effective_mode(%Resolved{http_cache: :inherit}, opts),
    do: opts |> Keyword.fetch!(:http_cache) |> Keyword.fetch!(:mode)

  defp effective_mode(%Resolved{http_cache: mode}, _opts) when mode in [:enabled, :disabled],
    do: mode

  defp generated_cache_headers(
         _conn,
         _plan,
         _resolved,
         _opts,
         :disabled,
         _representation_headers
       ),
       do: {[], nil, nil}

  defp generated_cache_headers(
         %Plug.Conn{method: method},
         _plan,
         _resolved,
         _opts,
         :enabled,
         _representation_headers
       )
       when method not in ["GET", "HEAD"],
       do: {[], nil, nil}

  defp generated_cache_headers(conn, plan, resolved, opts, :enabled, representation_headers) do
    cond do
      has_set_cookie?(conn) ->
        {[], nil, nil}

      vary_star?(conn) or vary_star?(representation_headers) ->
        {[], nil, nil}

      host_has_no_store?(conn) ->
        {[], nil, nil}

      has_host_cache_control?(conn) ->
        generated_etag_only(conn, plan, resolved, opts)

      true ->
        generated_cache_control_and_etag(conn, plan, resolved, opts)
    end
  end

  defp generated_cache_control_and_etag(conn, plan, resolved, opts) do
    case generated_etag(conn, plan, resolved, opts) do
      {:etag, etag} ->
        {[{"cache-control", @generated_cache_control}, {"etag", etag}], etag, nil}

      :not_generated ->
        cache_control_without_etag(conn, resolved.cache_semantics)
    end
  end

  defp cache_control_without_etag(_conn, %CacheSemantics{byte_identity: :none}) do
    {[{"cache-control", @no_store}], nil, :missing_byte_identity}
  end

  defp cache_control_without_etag(conn, %CacheSemantics{
         byte_identity: {:strong, _seed},
         stable?: true
       }) do
    if has_resp_header?(conn, "etag"),
      do: {[{"cache-control", @generated_cache_control}], nil, nil},
      else: {[], nil, nil}
  end

  defp generated_etag_only(conn, plan, resolved, opts) do
    case generated_etag(conn, plan, resolved, opts) do
      {:etag, etag} -> {[{"etag", etag}], etag, nil}
      :not_generated -> {[], nil, nil}
    end
  end

  defp generated_etag(conn, plan, %Resolved{cache_semantics: cache_semantics}, opts) do
    cond do
      has_resp_header?(conn, "etag") ->
        :not_generated

      host_has_no_store?(conn) ->
        :not_generated

      true ->
        do_generated_etag(conn, plan, cache_semantics, opts)
    end
  end

  defp do_generated_etag(conn, plan, %CacheSemantics{byte_identity: {:strong, seed}}, opts) do
    {:ok, material} = etag_material(conn, plan, seed, opts)

    material
    |> serialize_material()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&{:etag, ~s("ip#{@etag_schema}-#{&1}")})
  end

  defp do_generated_etag(_conn, _plan, %CacheSemantics{byte_identity: :none}, _opts),
    do: :not_generated

  defp accept_material(conn, %Output{mode: :automatic}, opts) do
    conn
    |> get_req_header("accept")
    |> Enum.join(",")
    |> Negotiation.modern_candidates(opts)
  end

  defp accept_material(_conn, %Output{}, _opts), do: []

  defp accept_material(_conn, nil, _opts), do: []

  defp representation_headers(conn, %Plan{output: %Output{mode: :automatic}}),
    do: merge_vary(conn, "Accept")

  defp representation_headers(_conn, %Plan{}), do: []

  defp merge_vary(conn, added_name) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&split_vary/1)

    values =
      existing
      |> Kernel.++([added_name])
      |> dedupe_tokens()

    if Enum.any?(existing, &(String.downcase(&1) == "*")),
      do: [{"vary", "*"}],
      else: [{"vary", Enum.join(values, ", ")}]
  end

  defp split_vary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp dedupe_tokens(tokens) do
    Enum.reduce(tokens, [], fn token, acc ->
      if Enum.any?(acc, &(String.downcase(&1) == String.downcase(token))),
        do: acc,
        else: acc ++ [token]
    end)
  end

  defp vary_star?(%Plug.Conn{} = conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.any?(fn value -> "*" in split_vary(value) end)
  end

  defp vary_star?(headers) do
    Enum.any?(headers, fn
      {"vary", value} -> "*" in split_vary(value)
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

  defp byte_identity_kind(%CacheSemantics{byte_identity: {:strong, _seed}}), do: :strong
  defp byte_identity_kind(%CacheSemantics{byte_identity: :none}), do: :none

  defp etag_emitted?(nil), do: false
  defp etag_emitted?(_etag), do: true

  defp emit_fallback_telemetry(nil, _resolved, _opts), do: :ok

  defp emit_fallback_telemetry(reason, resolved, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:http_cache, :fallback, :no_store],
      %{},
      %{
        adapter: resolved.adapter,
        source_kind: resolved.source_kind,
        reason: reason
      }
    )
  end

  defp if_none_match?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.join(",")
    |> parse_if_none_match()
    |> tags_match?(etag)
  end

  defp parse_if_none_match(""), do: []

  defp parse_if_none_match(value) do
    tags =
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if "*" in tags, do: :wildcard, else: tags
  end

  defp tags_match?(:wildcard, _etag), do: false
  defp tags_match?(tags, etag), do: Enum.any?(tags, &weak_entity_match?(&1, etag))

  defp weak_entity_match?(candidate, etag),
    do: quoted_entity_tag?(candidate) and strip_weak(candidate) == strip_weak(etag)

  defp quoted_entity_tag?("W/\"" <> rest), do: String.ends_with?(rest, "\"")
  defp quoted_entity_tag?("\"" <> rest), do: String.ends_with?(rest, "\"")
  defp quoted_entity_tag?(_value), do: false

  defp strip_weak("W/" <> rest), do: rest
  defp strip_weak(value), do: value

  defp serialize_material(material) do
    material
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp canonicalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
    else
      Enum.map(value, &canonicalize/1)
    end
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
    |> Enum.sort()
  end

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  defp canonicalize(value), do: value
end
