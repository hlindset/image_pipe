defmodule ImagePipe.Dialect.TwicPics.NegotiationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Negotiation
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Source.Path

  defp request!(chain) do
    {:ok, request} =
      RequestBuilder.build(%Path{segments: ["images", "cat.jpg"]}, chain, Config.validate!([]))

    request
  end

  test "explicit output selects the requested format without Vary" do
    request = request!([{"output", "avif"}])
    conn = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/webp")
    config = Config.validate!(output_capabilities: %{avif: true})

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request, config)
    assert negotiation.selected == {:image, :avif}
    assert negotiation.vary? == false
    assert negotiation.policy.headers == []
  end

  test "automatic output selects the configured first accepted modern format" do
    request = request!([])

    conn =
      :get
      |> conn("/")
      |> Plug.Conn.put_req_header("accept", "image/avif,image/webp")

    config =
      Config.validate!(
        auto_avif: true,
        format_order: [:webp, :avif],
        output_capabilities: %{avif: true, webp: true}
      )

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request, config)
    assert negotiation.selected == {:image, :webp}
    assert negotiation.vary? == true
    assert negotiation.policy.headers == [{"vary", "Accept"}]
  end

  # Hosted imagepipe.twic.pics output=auto probes (2026-07-19): a Chrome Accept
  # (image/avif,image/webp,...) returns image/webp, and Accept: image/avif alone
  # returns the source format (image/png), i.e. auto never selects AVIF. The
  # dialect defaults auto_avif/auto_jpeg_xl off so its default auto negotiation
  # matches hosted; explicit output=avif still bypasses (covered elsewhere).
  test "automatic output defaults to WebP over AVIF, matching hosted TwicPics" do
    request = request!([])

    conn =
      :get
      |> conn("/")
      |> Plug.Conn.put_req_header(
        "accept",
        "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
      )

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request, Config.validate!([]))
    assert negotiation.selected == {:image, :webp}
    assert negotiation.vary? == true
  end

  test "an AVIF-only Accept defers to source negotiation (auto never selects AVIF)" do
    request = request!([])
    conn = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif")

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request, Config.validate!([]))
    assert negotiation.selected == {:image, :source_negotiated}
    assert negotiation.vary? == true
  end

  test "a host may re-enable AVIF auto negotiation" do
    request = request!([])

    conn =
      :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/avif,image/webp")

    assert {:ok, negotiation} =
             Negotiation.negotiate(conn, request, Config.validate!(auto_avif: true))

    assert negotiation.selected == {:image, :avif}
  end

  test "automatic output with no modern candidate defers to source negotiation" do
    request = request!([])
    conn = :get |> conn("/") |> Plug.Conn.put_req_header("accept", "image/jpeg")
    config = Config.validate!([])

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request, config)
    assert negotiation.selected == {:image, :source_negotiated}
    assert negotiation.vary? == true
  end

  test "unsupported configured explicit capability is rejected before source work" do
    request = request!([{"output", "avif"}])
    config = Config.validate!(output_capabilities: %{avif: false})

    assert Negotiation.negotiate(conn(:get, "/"), request, config) ==
             {:error, {:unsupported_output_format, :avif}}
  end

  test "one Policy term supplies identity material and final output resolution" do
    request = request!([{"output", "jpeg"}, {"quality", "42"}])
    config = Config.validate!([])

    assert {:ok, negotiation} = Negotiation.negotiate(conn(:get, "/"), request, config)
    assert negotiation.policy_material == Policy.identity_material(negotiation.policy)
    assert Keyword.fetch!(negotiation.policy_material, :quality) == {:quality, 42}

    assert {:ok, resolved} =
             Negotiate.negotiate_output(negotiation.policy, :jpeg, fn -> false end,
               telemetry_prefix: [:image_pipe, :twic_pics_negotiation_test]
             )

    assert resolved.format == :jpeg
    assert resolved.quality == {:quality, 42}
    assert resolved.response_headers === negotiation.policy.headers
  end
end
