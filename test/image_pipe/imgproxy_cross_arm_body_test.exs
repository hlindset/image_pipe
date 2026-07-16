defmodule ImagePipe.ImgproxyCrossArmBodyTest do
  @moduledoc """
  Cross-arm raw body-hash equality: for every differential constellation, the
  framework stack (`ImagePipe.Plug` + `ImagePipe.Parser.Imgproxy`) and the inverted
  dialect stack (`ImagePipe.Dialect.Imgproxy`) must emit byte-identical bodies.

  This is a *stricter* net than the differential suite's pixel comparison and the
  wire suite's contract assertions: those allow encoder-level slack, this allows
  none. It is deliberately stricter than the spec's pixel/wire criteria — byte
  identity across two independent control paths is a stronger attempted invariant
  than determinism within one stack, so a mismatch here is classified before it is
  treated as a blocker (see `@excluded`).

  Per-arm isolation is load-bearing for this test's validity: if the two arms shared
  a cache, arm B would serve arm A's stored bytes and every hash would match
  trivially, proving nothing. `isolation_test` below proves the arms are independent
  rather than assuming it.
  """
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Harness}

  @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"

  # Constellations whose bodies are NOT expected to match byte-for-byte across arms.
  # Every entry must carry a classification (semantic bug / benign encoded-byte
  # variation / nondeterministic fixture) — an exclusion is named, never silently
  # dropped. Empty: no case proved nondeterministic or arm-sensitive.
  @excluded %{}

  setup_all do
    {:ok, framework: Harness.plug_opts(:framework), dialect: Harness.plug_opts(:dialect)}
  end

  test "framework and dialect produce byte-identical bodies", ctx do
    mismatches =
      Constellations.all()
      |> Enum.reject(&Map.has_key?(@excluded, &1.id))
      |> Enum.flat_map(fn c ->
        path = Constellations.imgproxy_path(c)
        {fw_body, fw_ct} = Harness.render(c, ctx.framework)
        {di_body, di_ct} = Harness.render(c, ctx.dialect)

        if hash(fw_body) == hash(di_body) and fw_ct == di_ct do
          []
        else
          [
            "#{c.id} (#{path})\n" <>
              "    framework: #{byte_size(fw_body)}B #{inspect(fw_ct)} sha256=#{hash_hex(fw_body)}\n" <>
              "    dialect:   #{byte_size(di_body)}B #{inspect(di_ct)} sha256=#{hash_hex(di_body)}"
          ]
        end
      end)

    assert mismatches == [],
           "cross-arm body divergence in #{length(mismatches)} constellation(s) — classify " <>
             "before excluding (semantic parity bug / benign encoded-byte variation / " <>
             "nondeterministic fixture):\n\n" <> Enum.join(mismatches, "\n\n")
  end

  # The equality test above is only meaningful if each arm generates its own bytes.
  # Two independent proofs:
  #
  #   1. Structural — neither arm's initialized opts carry a `:cache` key at all, so
  #      there is no store for one arm to read the other's output from.
  #   2. Behavioral — each arm fetches the origin itself. A shared cache would let the
  #      second arm answer without touching the origin; both fetches arriving proves
  #      the arms are generating independently.
  describe "per-arm isolation (this file's validity depends on it)" do
    test "neither arm configures a cache", ctx do
      {ImagePipe.Plug, framework_opts} = ctx.framework
      {ImagePipe.Dialect.Imgproxy, dialect_opts} = ctx.dialect

      refute Keyword.has_key?(framework_opts, :cache)
      refute Keyword.has_key?(dialect_opts, :cache)
    end

    test "each arm fetches the origin itself — neither serves the other's bytes" do
      path = "/unsafe/rs:fit:80:80/f:png/plain/local:///marker.png"

      fw_body = render_counting(:framework, path)
      assert_received {:origin_fetch, :framework}

      di_body = render_counting(:dialect, path)

      assert_received {:origin_fetch, :dialect},
                      "the dialect arm did not fetch the origin — it answered from state " <>
                        "shared with the framework arm, which would make the body-hash " <>
                        "equality above trivially true"

      # Same bytes, but each arm demonstrably produced them from its own fetch.
      assert hash(fw_body) == hash(di_body)
    end
  end

  defp render_counting(arm, path) do
    test_pid = self()

    counting_origin = fn conn ->
      send(test_pid, {:origin_fetch, arm})

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, File.read!(Path.join(@sources_dir, "marker.png")))
    end

    sources = [
      path:
        {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: counting_origin]}
    ]

    {plug, opts} =
      case arm do
        :framework ->
          {ImagePipe.Plug,
           ImagePipe.Plug.init(parser: ImagePipe.Parser.Imgproxy, sources: sources)}

        :dialect ->
          {ImagePipe.Dialect.Imgproxy, ImagePipe.Dialect.Imgproxy.init(sources: sources)}
      end

    conn = :get |> conn(path) |> plug.call(opts)
    assert conn.status == 200
    conn.resp_body
  end

  defp hash(body), do: :crypto.hash(:sha256, body)
  defp hash_hex(body), do: body |> hash() |> Base.encode16(case: :lower)
end
