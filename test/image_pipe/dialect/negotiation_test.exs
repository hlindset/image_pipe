defmodule ImagePipe.Dialect.NegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Plan.Output

  @config [
    auto_avif: true,
    auto_webp: true,
    auto_jpeg_xl: true,
    output_capabilities: %{avif: true, webp: true, jpeg_xl: true}
  ]

  test "explicit format selects without Vary and carries the plan output" do
    conn = Plug.Test.conn(:get, "/")
    plan_output = %Output{mode: {:explicit, :webp}, quality: :default}

    assert {:ok, %Negotiation{} = negotiation} =
             Negotiation.negotiate(conn, plan_output, @config)

    assert negotiation.selected == {:image, :webp}
    refute negotiation.vary?
    assert negotiation.plan_output == plan_output
    assert is_list(negotiation.policy_material)
    assert negotiation.policy != nil
  end

  test "terminal/1 carries no policy, no vary, empty material" do
    negotiation = Negotiation.terminal(:blurhash)

    assert negotiation.selected == {:terminal, :blurhash}
    refute negotiation.vary?
    assert negotiation.policy_material == []
    assert negotiation.policy == nil
    assert negotiation.plan_output == nil
  end
end
