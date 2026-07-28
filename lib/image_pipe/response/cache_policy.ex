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
          http_cache: :inherit | :enabled | :disabled,
          byte_identity: {:strong, term()} | :none,
          stable?: boolean(),
          adapter: module(),
          source_kind: :path | :url | :object | :reference
        }

  @spec generate(Plug.Conn.t(), Representation.t(), source_facts(), keyword()) :: CacheHeaders.t()
  def generate(%Plug.Conn{} = conn, %Representation{} = representation, source_facts, config) do
    effective_mode = effective_mode(source_facts, config)
    representation_headers = representation_headers(conn, representation)

    {headers, etag, fallback_reason} =
      generated_cache_headers(
        conn,
        representation,
        source_facts,
        effective_mode,
        representation_headers
      )

    Telemetry.execute(
      Telemetry.telemetry_opts(config),
      [:http_cache, :prepare],
      %{},
      %{
        effective_mode: effective_mode,
        byte_identity: byte_identity_kind(source_facts.byte_identity),
        etag: etag_emitted?(etag)
      }
    )

    emit_fallback_telemetry(fallback_reason, source_facts, config)

    %CacheHeaders{
      representation_headers: representation_headers,
      headers: headers,
      etag: etag
    }
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

  defp effective_mode(%{http_cache: :inherit}, config),
    do: config |> Keyword.fetch!(:http_cache) |> Keyword.fetch!(:mode)

  defp effective_mode(%{http_cache: mode}, _config) when mode in [:enabled, :disabled], do: mode

  defp generated_cache_headers(
         _conn,
         _representation,
         _source_facts,
         :disabled,
         _representation_headers
       ),
       do: {[], nil, nil}

  defp generated_cache_headers(
         %Plug.Conn{method: method},
         _representation,
         _source_facts,
         :enabled,
         _representation_headers
       )
       when method not in ["GET", "HEAD"],
       do: {[], nil, nil}

  defp generated_cache_headers(
         conn,
         representation,
         source_facts,
         :enabled,
         representation_headers
       ) do
    cond do
      has_set_cookie?(conn) ->
        {[], nil, nil}

      vary_star?(conn) or vary_star?(representation_headers) ->
        {[], nil, nil}

      host_has_no_store?(conn) ->
        {[], nil, nil}

      has_host_cache_control?(conn) ->
        generated_etag_only(conn, representation)

      true ->
        generated_cache_control_and_etag(conn, representation, source_facts)
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
  defp representation_headers(conn, %Representation{vary: names}), do: merge_vary(conn, names)

  defp merge_vary(conn, added_names) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&split_vary/1)

    values =
      existing
      |> Kernel.++(added_names)
      |> Enum.uniq_by(&String.downcase/1)

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
        adapter: source_facts.adapter,
        source_kind: source_facts.source_kind,
        reason: reason
      }
    )
  end
end
