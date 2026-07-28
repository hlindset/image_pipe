defmodule ImagePipe.Dialect.TwicPics.NegotiationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Source.Path

  # This file's assertions now run against the promoted
  # `ImagePipe.Dialect.Negotiation.negotiate/3` seam (Phase A). Assertions that
  # merely duplicated `test/image_pipe/dialect/negotiation_test.exs` (explicit
  # format bypass, no-Vary) or `test/image_pipe/twic_pics_wire_conformance_test.exs`'s
  # "output=auto matches hosted TwicPics format selection" describe block (the
  # WebP-over-AVIF default, AVIF-only fallback, host AVIF re-enable, and
  # no-modern-candidate fallback) were deleted rather than kept as
  # post-migration parity pins. What remains is TwicPics-specific behavior not
  # pinned anywhere else: the `format_order` config knob, explicit-format
  # capability rejection, and the "one Policy term" identity/resolution
  # invariant.

  defp request!(chain) do
    {:ok, request} =
      RequestBuilder.build(%Path{segments: ["images", "cat.jpg"]}, chain, Config.validate!([]))

    request
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

    assert {:ok, negotiation} = Negotiation.negotiate(conn, request.output, config)
    assert negotiation.selected == {:image, :webp}
    assert negotiation.vary? == true
    assert negotiation.policy.headers == [{"vary", "Accept"}]
  end

  test "unsupported configured explicit capability is rejected before source work" do
    request = request!([{"output", "avif"}])
    config = Config.validate!(output_capabilities: %{avif: false})

    assert Negotiation.negotiate(conn(:get, "/"), request.output, config) ==
             {:error, {:unsupported_output_format, :avif}}
  end

  test "one Policy term supplies identity material and final output resolution" do
    request = request!([{"output", "jpeg"}, {"quality", "42"}])
    config = Config.validate!([])

    assert {:ok, negotiation} = Negotiation.negotiate(conn(:get, "/"), request.output, config)
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
