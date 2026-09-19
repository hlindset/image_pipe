defmodule ImagePipe.API.CacheContractTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]
  import Plug.Test, only: [conn: 2]

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias ImagePipe.Test.PlugFixture.OriginImage

  test "equivalent_requests/1 groups each share a cache key and an ETag" do
    assert_equivalent_requests(equivalent_requests(base_opts()))
  end

  test "format_negotiation_cases/1 :same_selection pairs share a cache key + ETag and set Vary: Accept" do
    assert_same_selection(format_negotiation_cases(base_opts()).same_selection)
  end

  test "format_negotiation_cases/1 :different_selection pairs differ in cache key and ETag" do
    assert_different_selection(format_negotiation_cases(base_opts()).different_selection)
  end

  test "format_negotiation_cases/1 :explicit_format paths ignore Accept and set no Vary" do
    assert_explicit_format(format_negotiation_cases(base_opts()).explicit_format)
  end

  test "format_negotiation_cases/1 :fixed_content_type paths set no Vary" do
    assert_fixed_content_type(format_negotiation_cases(base_opts()).fixed_content_type)
  end

  test "storage_only_case/1 variants produce different cache keys but the same ETag" do
    assert_storage_only(storage_only_case(base_opts()))
  end

  defp equivalent_requests(base_opts) do
    [
      # default `fit` (:contain) vs. its explicit spelling.
      {["/w=800/src/images/cat.jpg", "/fit=contain/w=800/src/images/cat.jpg"], base_opts},
      # default `anchor` (:center, once a guide consumer is present) vs. its
      # explicit spelling.
      {
        [
          "/crop=600,400/src/images/cat.jpg",
          "/crop=600,400/anchor=center/src/images/cat.jpg"
        ],
        base_opts
      },
      # `bg` color aliases (aqua/cyan) normalize to the same canonical sRGB
      # channel tuple (the full CSS Color Module Level 4 list).
      {["/bg=aqua/w=64/src/images/cat.jpg", "/bg=cyan/w=64/src/images/cat.jpg"], base_opts}
    ]
  end

  defp format_negotiation_cases(_base_opts) do
    %{
      same_selection: [
        # no-modern bucket: neither spelling names a modern format, so both
        # negotiate the `:source_negotiated` sentinel — load-bearing here.
        {"/w=64/src/images/cat.jpg", "image/jpeg", nil},
        # modern bucket: both select avif (webp only appears second).
        {"/w=64/src/images/cat.jpg", "image/avif", "image/avif,image/webp"}
      ],
      different_selection: [
        {"/w=64/src/images/cat.jpg", "image/avif", nil}
      ],
      explicit_format: [
        {"/format=webp/w=64/src/images/cat.jpg", "image/avif"}
      ],
      fixed_content_type: [
        "/w=32/output=blurhash/src/images/cat.jpg"
      ]
    }
  end

  defp storage_only_case(base_opts) do
    opts = Keyword.put(base_opts, :storage_inputs, [{:header, "x-tenant"}])

    variants = [
      {:header, "x-tenant", "team-a"},
      {:header, "x-tenant", "team-b"}
    ]

    {"/w=64/src/images/cat.jpg", opts, variants}
  end

  @spec base_opts() :: keyword()
  defp base_opts do
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

  defp build_config(opts) do
    config =
      ImagePipe.Plug.init(Keyword.merge(opts, cache: {CacheProbe, []}))

    Keyword.merge(config, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp request(path, config, nil), do: ImagePipe.Plug.call(conn(:get, path), config)

  defp request(path, config, accept) do
    conn(:get, path) |> put_req_header("accept", accept) |> then(&ImagePipe.Plug.call(&1, config))
  end

  defp request_with_variant(path, config, {:header, name, value}) do
    conn(:get, path) |> put_req_header(name, value) |> then(&ImagePipe.Plug.call(&1, config))
  end

  defp request_with_variant(path, config, {:cookie, name, value}) do
    conn(:get, path)
    |> put_req_header("cookie", "#{name}=#{value}")
    |> then(&ImagePipe.Plug.call(&1, config))
  end

  # ── generated-test bodies ────────────────────────────────────────────────

  defp assert_equivalent_requests(groups) do
    refute Enum.empty?(groups), "equivalent_requests/1 must return at least one group"

    for {paths, opts} <- groups do
      assert length(paths) >= 2,
             "each equivalence group must list at least 2 paths, got: #{inspect(paths)}"

      config = build_config(opts)

      results =
        for path <- paths do
          conn = ImagePipe.Plug.call(conn(:get, path), config)
          assert_receive {:cache_lookup, key}
          assert conn.status == 200, "expected #{path} to return 200, got #{conn.status}"
          {key.hash, get_resp_header(conn, "etag")}
        end

      assert results |> Enum.uniq() |> length() == 1,
             "expected paths #{inspect(paths)} to share a cache key + ETag, got: #{inspect(results)}"
    end
  end

  defp assert_same_selection(cases) do
    refute Enum.empty?(cases), "format_negotiation_cases/1 :same_selection must be non-empty"
    config = build_config(base_opts())

    for {path, accept_a, accept_b} <- cases do
      conn_a = request(path, config, accept_a)
      assert_receive {:cache_lookup, key_a}
      conn_b = request(path, config, accept_b)
      assert_receive {:cache_lookup, key_b}

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert key_a.hash == key_b.hash
      assert get_resp_header(conn_a, "etag") == get_resp_header(conn_b, "etag")
      assert get_resp_header(conn_a, "vary") == ["Accept"]
      assert get_resp_header(conn_b, "vary") == ["Accept"]
    end
  end

  defp assert_different_selection(cases) do
    refute Enum.empty?(cases),
           "format_negotiation_cases/1 :different_selection must be non-empty"

    config = build_config(base_opts())

    for {path, accept_a, accept_b} <- cases do
      conn_a = request(path, config, accept_a)
      assert_receive {:cache_lookup, key_a}
      conn_b = request(path, config, accept_b)
      assert_receive {:cache_lookup, key_b}

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert key_a.hash != key_b.hash
      assert get_resp_header(conn_a, "etag") != get_resp_header(conn_b, "etag")
    end
  end

  defp assert_explicit_format(cases) do
    refute Enum.empty?(cases), "format_negotiation_cases/1 :explicit_format must be non-empty"
    config = build_config(base_opts())

    for {path, accept} <- cases do
      conn_with = request(path, config, accept)
      assert_receive {:cache_lookup, key_with}
      conn_without = request(path, config, nil)
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

  defp assert_fixed_content_type(paths) do
    refute Enum.empty?(paths),
           "format_negotiation_cases/1 :fixed_content_type must be non-empty"

    config = build_config(base_opts())

    for path <- paths do
      conn = request(path, config, "image/avif")
      assert conn.status == 200
      assert get_resp_header(conn, "vary") == []
    end
  end

  defp assert_storage_only({path, opts, variants}) do
    assert length(variants) >= 2,
           "storage_only_case/1 must return at least 2 variants, got: #{inspect(variants)}"

    config = build_config(opts)

    results =
      for variant <- variants do
        conn = request_with_variant(path, config, variant)
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
