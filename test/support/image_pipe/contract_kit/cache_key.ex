defmodule ImagePipe.ContractKit.CacheKey do
  @moduledoc """
  Executable contract kit for representation identity [pipelines design
  §Enforcement model, layer 4]: `use ImagePipe.ContractKit.CacheKey, dialect:
  SomeDialect` generates ExUnit tests that make real
  `SomeDialect.call/2` requests and assert the cache-key/ETag/Vary promises
  every dialect must keep, parameterized by a small test-facing behaviour the
  using module implements.

  Generated cases:

    * `equivalent_requests/1` groups — every path within a group MUST share a
      cache key and an ETag (paths that differ only in option order, or in
      an option's default vs. its explicit spelling, or in an alias that
      normalizes to the same canonical value).
    * `format_negotiation_cases/1` `:same_selection` pairs — two `Accept`
      spellings that negotiate the *same* format MUST share a cache key and
      an ETag, and both responses MUST carry `Vary: Accept`.
    * `format_negotiation_cases/1` `:different_selection` pairs — two
      `Accept` spellings that negotiate *different* formats MUST differ in
      both cache key and ETag.
    * `format_negotiation_cases/1` `:explicit_format` paths — an explicit
      output-format request MUST ignore `Accept` (same cache key/ETag/
      content-type with or without the given header) and MUST carry no
      `Vary`.
    * `format_negotiation_cases/1` `:fixed_content_type` paths — a
      fixed-content-type terminal (e.g. a BlurHash route) MUST carry no
      `Vary`, regardless of `Accept`.
    * `storage_only_case/1` — variants of a configured storage-only
      header/cookie MUST produce different cache keys but the SAME ETag
      (storage segregates without changing bytes); a HEADER-type variant's
      configured name MUST appear in `Vary`, a COOKIE-type variant's name
      MUST NOT.

  The using module supplies concrete paths via the callbacks below; the
  functions in this module (called from the small generated `test` bodies)
  own request execution, cache-key capture (via a probe `ImagePipe.Cache`
  adapter), and the assertions. It reuses the existing wire-test rig rather
  than re-inventing fixtures: `ImagePipe.SourceTest.RootHTTPAdapter` as the
  source adapter, `ImgproxyWireConformanceTest.OriginImage` as the origin
  plug, and `ImgproxyWireConformanceTest.CacheProbe` to observe cache
  lookups (see Tasks 15-17's `native_wire_test.exs`, which exercises the same
  rig by hand).
  """

  import ExUnit.Assertions
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.OriginImage

  @typedoc "A request-target path (dialect-specific wire syntax)."
  @type path :: String.t()

  @typedoc "A raw `Accept` header value, or `nil` to mean the header is omitted."
  @type accept :: String.t() | nil

  @typedoc """
  A group of paths that must ALL resolve to the same cache key and ETag,
  together with the (pre-`init/1`) config to run them under.
  """
  @type equivalence_group :: {[path], keyword()}

  @typedoc """
  A configured storage-only input variant: a header or cookie name/value
  pair applied to the request. Two variants of the same input must yield
  different cache keys but the same ETag.
  """
  @type header_or_cookie_variant ::
          {:header, name :: String.t(), value :: String.t()}
          | {:cookie, name :: String.t(), value :: String.t()}

  @doc """
  Returns one or more groups of paths. Every path within a single group MUST
  produce the same cache key and the same ETag. `base_opts` is the kit's
  starter config (currently just `:sources`); each group carries the config
  (usually `base_opts` unchanged) to run its paths under.
  """
  @callback equivalent_requests(base_opts :: keyword()) :: [equivalence_group]

  @doc """
  Returns the format-negotiation case buckets, all run under `base_opts`
  (through the kit's own config assembly — see the moduledoc).
  """
  @callback format_negotiation_cases(base_opts :: keyword()) :: %{
              same_selection: [{path, accept, accept}],
              different_selection: [{path, accept, accept}],
              explicit_format: [{path, accept}],
              fixed_content_type: [path]
            }

  @doc """
  Returns `{path, opts_with_storage_input, variants}`: a path, the config
  (derived from `base_opts`) with a `:storage_inputs` entry configured, and
  at least two variants of that input's value.
  """
  @callback storage_only_case(base_opts :: keyword()) ::
              {path, opts_with_storage_input :: keyword(), [header_or_cookie_variant]}

  defmacro __using__(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    quote do
      use ExUnit.Case, async: true

      alias ImagePipe.ContractKit.CacheKey, as: ContractKitCacheKey

      @behaviour ImagePipe.ContractKit.CacheKey

      @contract_kit_cache_key_dialect unquote(dialect)

      test "equivalent_requests/1 groups each share a cache key and an ETag" do
        ContractKitCacheKey.assert_equivalent_requests(
          @contract_kit_cache_key_dialect,
          equivalent_requests(ContractKitCacheKey.base_opts())
        )
      end

      test "format_negotiation_cases/1 :same_selection pairs share a cache key + ETag and set Vary: Accept" do
        ContractKitCacheKey.assert_same_selection(
          @contract_kit_cache_key_dialect,
          format_negotiation_cases(ContractKitCacheKey.base_opts()).same_selection
        )
      end

      test "format_negotiation_cases/1 :different_selection pairs differ in cache key and ETag" do
        ContractKitCacheKey.assert_different_selection(
          @contract_kit_cache_key_dialect,
          format_negotiation_cases(ContractKitCacheKey.base_opts()).different_selection
        )
      end

      test "format_negotiation_cases/1 :explicit_format paths ignore Accept and set no Vary" do
        ContractKitCacheKey.assert_explicit_format(
          @contract_kit_cache_key_dialect,
          format_negotiation_cases(ContractKitCacheKey.base_opts()).explicit_format
        )
      end

      test "format_negotiation_cases/1 :fixed_content_type paths set no Vary" do
        ContractKitCacheKey.assert_fixed_content_type(
          @contract_kit_cache_key_dialect,
          format_negotiation_cases(ContractKitCacheKey.base_opts()).fixed_content_type
        )
      end

      test "storage_only_case/1 variants produce different cache keys but the same ETag" do
        ContractKitCacheKey.assert_storage_only(
          @contract_kit_cache_key_dialect,
          storage_only_case(ContractKitCacheKey.base_opts())
        )
      end
    end
  end

  # ── kit-owned config assembly ────────────────────────────────────────────

  @doc false
  @spec base_opts() :: keyword()
  def base_opts do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://contract-kit-cache-key.test",
           byte_identity: :strong,
           req_options: [plug: OriginImage]}
      ]
    ]
  end

  @doc false
  def build_config(dialect, opts) do
    config = dialect.init(Keyword.merge(opts, cache: {CacheProbe, []}))
    Keyword.merge(config, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp request(dialect, path, config, nil), do: dialect.call(conn(:get, path), config)

  defp request(dialect, path, config, accept) do
    conn(:get, path) |> put_req_header("accept", accept) |> then(&dialect.call(&1, config))
  end

  defp request_with_variant(dialect, path, config, {:header, name, value}) do
    conn(:get, path) |> put_req_header(name, value) |> then(&dialect.call(&1, config))
  end

  defp request_with_variant(dialect, path, config, {:cookie, name, value}) do
    conn(:get, path)
    |> put_req_header("cookie", "#{name}=#{value}")
    |> then(&dialect.call(&1, config))
  end

  # ── generated-test bodies ────────────────────────────────────────────────

  @doc false
  def assert_equivalent_requests(dialect, groups) do
    refute Enum.empty?(groups), "equivalent_requests/1 must return at least one group"

    for {paths, opts} <- groups do
      assert length(paths) >= 2,
             "each equivalence group must list at least 2 paths, got: #{inspect(paths)}"

      config = build_config(dialect, opts)

      results =
        for path <- paths do
          conn = dialect.call(conn(:get, path), config)
          assert_receive {:cache_lookup, key}
          assert conn.status == 200, "expected #{path} to return 200, got #{conn.status}"
          {key.hash, get_resp_header(conn, "etag")}
        end

      assert results |> Enum.uniq() |> length() == 1,
             "expected paths #{inspect(paths)} to share a cache key + ETag, got: #{inspect(results)}"
    end
  end

  @doc false
  def assert_same_selection(dialect, cases) do
    refute Enum.empty?(cases), "format_negotiation_cases/1 :same_selection must be non-empty"
    config = build_config(dialect, base_opts())

    for {path, accept_a, accept_b} <- cases do
      conn_a = request(dialect, path, config, accept_a)
      assert_receive {:cache_lookup, key_a}
      conn_b = request(dialect, path, config, accept_b)
      assert_receive {:cache_lookup, key_b}

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert key_a.hash == key_b.hash
      assert get_resp_header(conn_a, "etag") == get_resp_header(conn_b, "etag")
      assert get_resp_header(conn_a, "vary") == ["Accept"]
      assert get_resp_header(conn_b, "vary") == ["Accept"]
    end
  end

  @doc false
  def assert_different_selection(dialect, cases) do
    refute Enum.empty?(cases),
           "format_negotiation_cases/1 :different_selection must be non-empty"

    config = build_config(dialect, base_opts())

    for {path, accept_a, accept_b} <- cases do
      conn_a = request(dialect, path, config, accept_a)
      assert_receive {:cache_lookup, key_a}
      conn_b = request(dialect, path, config, accept_b)
      assert_receive {:cache_lookup, key_b}

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert key_a.hash != key_b.hash
      assert get_resp_header(conn_a, "etag") != get_resp_header(conn_b, "etag")
    end
  end

  @doc false
  def assert_explicit_format(dialect, cases) do
    refute Enum.empty?(cases), "format_negotiation_cases/1 :explicit_format must be non-empty"
    config = build_config(dialect, base_opts())

    for {path, accept} <- cases do
      conn_with = request(dialect, path, config, accept)
      assert_receive {:cache_lookup, key_with}
      conn_without = request(dialect, path, config, nil)
      assert_receive {:cache_lookup, key_without}

      assert conn_with.status == 200
      assert conn_without.status == 200
      assert key_with.hash == key_without.hash
      assert get_resp_header(conn_with, "etag") == get_resp_header(conn_without, "etag")

      assert get_resp_header(conn_with, "content-type") ==
               get_resp_header(conn_without, "content-type")

      assert get_resp_header(conn_with, "vary") == []
      assert get_resp_header(conn_without, "vary") == []
    end
  end

  @doc false
  def assert_fixed_content_type(dialect, paths) do
    refute Enum.empty?(paths),
           "format_negotiation_cases/1 :fixed_content_type must be non-empty"

    config = build_config(dialect, base_opts())

    for path <- paths do
      conn = request(dialect, path, config, "image/avif")
      assert conn.status == 200
      assert get_resp_header(conn, "vary") == []
    end
  end

  @doc false
  def assert_storage_only(dialect, {path, opts, variants}) do
    assert length(variants) >= 2,
           "storage_only_case/1 must return at least 2 variants, got: #{inspect(variants)}"

    config = build_config(dialect, opts)

    results =
      for variant <- variants do
        conn = request_with_variant(dialect, path, config, variant)
        assert_receive {:cache_lookup, key}
        assert conn.status == 200
        assert_storage_vary(variant, get_resp_header(conn, "vary"))
        {key.hash, get_resp_header(conn, "etag")}
      end

    {hashes, etags} = Enum.unzip(results)

    assert hashes |> Enum.uniq() |> length() == length(hashes),
           "expected a distinct cache key per storage-only variant, got: #{inspect(hashes)}"

    assert etags |> Enum.uniq() |> length() == 1,
           "expected the same ETag across storage-only variants, got: #{inspect(etags)}"
  end

  defp assert_storage_vary({:header, name, _value}, vary) do
    assert Enum.any?(vary, &vary_names_include?(&1, name)),
           "expected storage header #{inspect(name)} to appear in Vary, got: #{inspect(vary)}"
  end

  defp assert_storage_vary({:cookie, name, _value}, vary) do
    refute Enum.any?(vary, &vary_names_include?(&1, name)),
           "expected storage cookie #{inspect(name)} to NOT appear in Vary, got: #{inspect(vary)}"
  end

  defp vary_names_include?(vary_value, name) do
    vary_value
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.member?(String.downcase(name))
  end
end
