defmodule ImagePipe.Dialect.Declarative.IdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePipe.Dialect.Declarative.Identity
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Representation

  # These build a %Plan{} through the real constructors (Operation.resize/4 and
  # friends) — never a hand-rolled struct literal — so every shape asserted here
  # is one a parse_plan/2 can actually produce.

  defp key(plan, opts \\ []) do
    negotiation = Keyword.get(opts, :negotiation, negotiation_for(plan))
    config = Keyword.get(opts, :config, [])
    conn = Keyword.get(opts, :conn, conn(:get, "/x"))
    detector = Keyword.get(opts, :detector)

    material = Identity.material(SomeDialect, plan, negotiation, conn, config, detector)
    Representation.build([source: "seed"], material, {:strong, "seed"})
  end

  test "the cachebuster moves the cache key but not the ETag" do
    base = key(plan())
    busted = key(%{plan() | cachebuster: "v2"})

    assert base.cache_key.hash != busted.cache_key.hash
    assert base.etag == busted.etag
  end

  test "a configured storage-input header value moves the key but not the ETag" do
    config = [storage_inputs: [{:header, "accept-language"}]]
    en = key(plan(), config: config, conn: conn_with_header("accept-language", "en"))
    de = key(plan(), config: config, conn: conn_with_header("accept-language", "de"))

    assert en.cache_key.hash != de.cache_key.hash
    assert en.etag == de.etag
  end

  test "the detector identity moves both the key and the ETag" do
    without = key(plan())
    with_detector = key(plan(), detector: {SomeDetector, "model-v3"})

    assert without.cache_key.hash != with_detector.cache_key.hash
    assert without.etag != with_detector.etag
  end

  test "plan.response never moves either digest" do
    debug = %{plan() | response: %ImagePipe.Plan.Response{debug?: true}}

    assert key(plan()).cache_key.hash == key(debug).cache_key.hash
    assert key(plan()).etag == key(debug).etag
  end

  test "plan.expires never moves either digest" do
    expiring = %{plan() | expires: 1_800_000_000}

    assert key(plan()).cache_key.hash == key(expiring).cache_key.hash
    assert key(plan()).etag == key(expiring).etag
  end

  test "derivation is stable across repeated calls" do
    assert key(plan()).cache_key.hash == key(plan()).cache_key.hash
    assert key(plan()).etag == key(plan()).etag
  end

  test "a configured storage-input header name enters Vary alongside Accept" do
    automatic = plan_with_output(%Output{mode: :automatic})

    material =
      Identity.material(
        SomeDialect,
        automatic,
        negotiation_for(automatic),
        conn_with_header("accept-language", "en"),
        [storage_inputs: [{:header, "Accept-Language"}]],
        nil
      )

    assert material.vary_header_names == ["accept-language", "Accept"]
  end

  property "any byte-affecting difference separates the cache key" do
    check all({left, right} <- distinct_plan_pair(), max_runs: 200) do
      assert hash(left) != hash(right)
    end
  end

  # -- generators -------------------------------------------------------------

  defp hash({plan, opts}), do: key(plan, opts).cache_key.hash

  defp distinct_plan_pair do
    one_of([
      operation_parameter_pair(),
      operation_list_pair(),
      auto_rotate_pair(),
      output_mode_pair(),
      output_quality_pair(),
      encoder_option_pair(),
      negotiation_selection_pair(),
      render_terminal_pair()
    ])
  end

  defp operation_parameter_pair do
    gen all(left <- integer(1..4000), right <- integer(1..4000), left != right) do
      {inputs(plan([resize(left)])), inputs(plan([resize(right)]))}
    end
  end

  defp operation_list_pair do
    gen all(left <- integer(0..3), right <- integer(0..3), left != right) do
      {inputs(plan(operations(left))), inputs(plan(operations(right)))}
    end
  end

  defp auto_rotate_pair do
    constant({inputs(%{plan() | auto_rotate: false}), inputs(%{plan() | auto_rotate: true})})
  end

  defp output_mode_pair do
    gen all(left <- member_of(output_modes()), right <- member_of(output_modes()), left != right) do
      {inputs(plan_with_output(%Output{mode: left})),
       inputs(plan_with_output(%Output{mode: right}))}
    end
  end

  defp output_modes, do: [:automatic, {:explicit, :jpeg}, {:explicit, :png}]

  defp output_quality_pair do
    gen all(left <- integer(1..100), right <- integer(1..100), left != right) do
      {inputs(plan_with_output(%Output{mode: {:explicit, :jpeg}, quality: {:quality, left}})),
       inputs(plan_with_output(%Output{mode: {:explicit, :jpeg}, quality: {:quality, right}}))}
    end
  end

  defp encoder_option_pair do
    gen all(left <- integer(0..8), right <- integer(0..8), left != right) do
      {inputs(plan_with_output(jpeg_output(left))), inputs(plan_with_output(jpeg_output(right)))}
    end
  end

  defp jpeg_output(quant_table) do
    %Output{
      mode: {:explicit, :jpeg},
      encoder_options: %{jpeg: %JpegOptions{quant_table: quant_table}}
    }
  end

  # The plan is held constant (automatic output mode) so only
  # `negotiation.selected` differs — driven by two different `Accept` headers
  # negotiated against that same plan's own output, the way a real request
  # produces it.
  defp negotiation_selection_pair do
    automatic = plan_with_output(%Output{mode: :automatic})

    constant({
      {automatic, [negotiation: image_negotiation(automatic.output, conn(:get, "/x"))]},
      {automatic,
       [
         negotiation:
           image_negotiation(automatic.output, conn_with_header("accept", "image/webp"))
       ]}
    })
  end

  # A render terminal's identity is the renderer module + params, carried on the
  # Plan rather than on the negotiation.
  defp render_terminal_pair do
    one_of([
      constant({inputs(render_plan(RendererA, %{})), inputs(render_plan(RendererB, %{}))}),
      constant(
        {inputs(render_plan(RendererA, %{scale: 1})), inputs(render_plan(RendererA, %{scale: 2}))}
      )
    ])
  end

  # -- plan builders ----------------------------------------------------------

  defp plan, do: plan([resize(100)])

  defp plan(operations), do: plan(operations, %Output{mode: {:explicit, :jpeg}})

  defp plan_with_output(%Output{} = output), do: plan([resize(100)], output)

  defp plan(operations, output) do
    %Plan{
      source: %SourcePath{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: output
    }
  end

  defp render_plan(module, params) do
    %Plan{
      source: %SourcePath{segments: ["images", "cat.jpg"]},
      pipelines: [],
      output: nil,
      render: {:custom, module, params}
    }
  end

  defp operations(0), do: []
  defp operations(1), do: [resize(100)]
  defp operations(2), do: [resize(100), blur(1.5)]
  defp operations(3), do: [blur(1.5), resize(100)]

  defp resize(width) do
    {:ok, operation} = Operation.resize(:fit, {:px, width}, :auto)
    operation
  end

  defp blur(sigma) do
    {:ok, operation} = Operation.blur(sigma)
    operation
  end

  # -- negotiation ------------------------------------------------------------

  defp inputs(plan), do: {plan, []}

  defp negotiation_for(%Plan{output: nil}), do: Negotiation.terminal(:render)
  defp negotiation_for(%Plan{output: output}), do: image_negotiation(output)

  defp image_negotiation(%Output{} = output), do: image_negotiation(output, conn(:get, "/x"))

  defp image_negotiation(%Output{} = output, conn) do
    {:ok, negotiation} = Negotiation.negotiate(conn, output, [])
    negotiation
  end

  defp conn_with_header(name, value),
    do: conn(:get, "/x") |> Plug.Conn.put_req_header(name, value)
end
