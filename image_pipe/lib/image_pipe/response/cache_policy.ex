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
          byte_identity: {:strong, term()},
          stable?: boolean(),
          source_mount: atom() | nil
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

  # `degraded?` marks output produced by a fallback after a failure (a crop that
  # used attention because detection errored). Neither shared caches nor the
  # client may keep it, and it gets no validator to revalidate against.
  @spec generate(Plug.Conn.t(), Representation.t(), source_facts(), mode(), keyword(), boolean()) ::
          CacheHeaders.t()
  def generate(
        %Plug.Conn{} = conn,
        %Representation{} = representation,
        source_facts,
        mode,
        config,
        degraded? \\ false
      ) do
    {prepared, fallback_reason} =
      case prepare(conn, representation, source_facts, mode, config) do
        {prepared, _reason} when degraded? -> {no_store(prepared), :detection_failed}
        prepared_and_reason -> prepared_and_reason
      end

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
  # ETag, or `no-store` when the source denies storage.
  defp prepare(_conn, representation, source_facts, :validators, _config) do
    case Map.get(source_facts, :storage) do
      :deny ->
        prepared = CacheHeaders.from_representation(representation)
        {%{prepared | etag: nil, headers: [{"cache-control", "no-store"}]}, nil}

      _permission ->
        {CacheHeaders.from_representation(representation), nil}
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
        no_store(prepared)

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

  @doc """
  Bounds the response's cache lifetime by the request's `expires`, so no
  cache holds or serves it after the URL stops being valid. Runs after
  `limit_to_source/6`, over whichever `Cache-Control` the policy settled on.
  A host `Cache-Control` and `no-store` are left alone. A response with a
  generated ETag but no `Cache-Control` (`:validators`) gets one bounded by
  the expiry.
  """
  @spec limit_to_expiry(
          CacheHeaders.t(),
          Plug.Conn.t(),
          pos_integer() | nil,
          integer(),
          mode(),
          keyword()
        ) :: CacheHeaders.t()
  def limit_to_expiry(prepared, _conn, nil, _now, _mode, _config), do: prepared

  def limit_to_expiry(prepared, conn, expires, now, mode, config) do
    remaining = max(0, expires - now)
    host? = CacheHeaders.host_cache_control?(get_resp_header(conn, "cache-control"))

    case List.keyfind(prepared.headers, "cache-control", 0) do
      _control when host? ->
        prepared

      {"cache-control", control} ->
        capped = cap_control(control, response_age(prepared.headers), remaining)

        %{
          prepared
          | headers:
              List.keystore(prepared.headers, "cache-control", 0, {"cache-control", capped})
        }

      nil when prepared.etag != nil ->
        control = "#{visibility(mode, config)}, max-age=#{remaining}, must-revalidate"
        %{prepared | headers: prepared.headers ++ [{"cache-control", control}]}

      nil ->
        prepared
    end
  end

  # Caches subtract `Age` from `max-age`, so the freshness left is the
  # difference; a stale window may only run until the expiry.
  defp cap_control(control, age, remaining) do
    directives =
      control |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    if "no-store" in directives do
      control
    else
      fresh = directive_seconds(directives, "max-age") - age

      directives =
        if fresh > remaining do
          directives
          |> put_directive("max-age", remaining + age)
          |> put_directive("stale-while-revalidate", 0)
        else
          stale = min(directive_seconds(directives, "stale-while-revalidate"), remaining - fresh)
          put_directive(directives, "stale-while-revalidate", stale)
        end

      directives
      |> Enum.concat(["must-revalidate"])
      |> Enum.uniq()
      |> Enum.join(", ")
    end
  end

  defp directive_seconds(directives, name) do
    Enum.find_value(directives, 0, fn directive ->
      case String.split(directive, "=", parts: 2) do
        [^name, seconds] -> String.to_integer(seconds)
        _other -> nil
      end
    end)
  end

  defp put_directive(directives, name, seconds) do
    Enum.flat_map(directives, fn directive ->
      case String.split(directive, "=", parts: 2) do
        [^name, _seconds] when seconds == 0 and name != "max-age" -> []
        [^name, _seconds] -> ["#{name}=#{seconds}"]
        _other -> [directive]
      end
    end)
  end

  defp response_age(headers) do
    case List.keyfind(headers, "age", 0) do
      {"age", age} -> String.to_integer(age)
      nil -> 0
    end
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

  # Reached when the host set its own ETag. Only an immutable source's
  # lifetime is known without that validator.
  defp cache_control_without_etag(conn, %{stable?: true}) do
    if has_resp_header?(conn, "etag"),
      do: {[{"cache-control", @generated_cache_control}], nil, nil},
      else: {[], nil, nil}
  end

  defp cache_control_without_etag(_conn, _source_facts), do: {[], nil, nil}

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

  defp no_store(prepared) do
    %{
      prepared
      | etag: nil,
        headers: [{"cache-control", "no-store"}],
        representation_headers: [{"cache-control", "no-store"} | prepared.representation_headers]
    }
  end

  defp byte_identity_kind({:strong, _seed}), do: :strong

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
        reason: reason
      }
    )
  end
end
