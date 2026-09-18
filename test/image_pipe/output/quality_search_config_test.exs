defmodule ImagePipe.Output.QualitySearchConfigTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Config
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  test "configured search iterations reach encoding and representation identity" do
    image = Image.open!("priv/static/images/beach.jpg") |> Image.thumbnail!(128)
    {_policy, reference} = resolved_output(quality: 50)
    {:ok, encoded, "image/jpeg", nil} = Encoder.stream_output(image, reference, [])
    target = encoded |> Enum.to_list() |> IO.iodata_to_binary() |> byte_size()

    opts = [
      autoquality_method: :size,
      autoquality_target: %{size: target},
      autoquality_min_quality: 1,
      autoquality_max_quality: 95
    ]

    {short_policy, short} = resolved_output([autoquality_max_iterations: 1] ++ opts)
    {long_policy, long} = resolved_output([autoquality_max_iterations: 12] ++ opts)
    refute Policy.identity_material(short_policy) == Policy.identity_material(long_policy)

    {:ok, [_short_body], "image/jpeg", short_meta} = Encoder.stream_output(image, short, [])
    {:ok, [_long_body], "image/jpeg", long_meta} = Encoder.stream_output(image, long, [])
    assert short_meta.iterations < long_meta.iterations
    refute short_meta.quality == long_meta.quality
  end

  test "an inactive iteration limit does not fragment identity" do
    {short, _resolved} = resolved_output(autoquality_max_iterations: 1)
    {long, _resolved} = resolved_output(autoquality_max_iterations: 12)
    assert Policy.identity_material(short) == Policy.identity_material(long)
  end

  test "native JPEG XL byte-budget descent respects the configured attempt limit" do
    image = Image.open!("priv/static/images/beach.jpg") |> Image.thumbnail!(128)
    opts = [autoquality_method: :butteraugli, jxl_options: %Output.JxlOptions{effort: 1}]
    {short_policy, short} = resolved_output([autoquality_max_iterations: 1] ++ opts, :jpeg_xl, 1)
    {long_policy, long} = resolved_output([autoquality_max_iterations: 12] ++ opts, :jpeg_xl, 1)
    {_policy, baseline} = resolved_output(opts, :jpeg_xl)
    {:ok, [short_body], "image/jxl", short_meta} = Encoder.stream_output(image, short, [])
    {:ok, [long_body], "image/jxl", long_meta} = Encoder.stream_output(image, long, [])
    {:ok, [baseline_body], "image/jxl", _meta} = Encoder.stream_output(image, baseline, [])
    assert short_body == baseline_body
    assert byte_size(long_body) < byte_size(short_body)
    assert short_meta.outcome == :best_effort
    assert long_meta.outcome == :best_effort
    refute Policy.identity_material(short_policy) == Policy.identity_material(long_policy)
  end

  test "native JPEG XL without a byte budget has no iterative limit in identity" do
    opts = [autoquality_method: :butteraugli]
    {short, _resolved} = resolved_output([autoquality_max_iterations: 1] ++ opts, :jpeg_xl)
    {long, _resolved} = resolved_output([autoquality_max_iterations: 12] ++ opts, :jpeg_xl)
    assert Policy.identity_material(short) == Policy.identity_material(long)
  end

  test "negotiated native JPEG XL also omits the unused iteration limit" do
    policies =
      for iterations <- [1, 12] do
        config =
          Config.resolve!(
            autoquality_method: :butteraugli,
            autoquality_max_iterations: iterations
          )

        {:ok, output} = Config.apply_to_output(%Output{mode: :automatic}, config)
        conn = Plug.Conn.put_req_header(conn(:get, "/"), "accept", "image/jxl")
        policy = Policy.from_output_plan(conn, output, [])
        assert Policy.identity_selection(policy) == {:auto_head, :jpeg_xl}
        Policy.identity_material(policy)
      end

    assert [material, material] = policies
  end

  test "PNG does not search or retain an unused iteration limit in identity" do
    opts = [autoquality_method: :ssimulacra2]
    {short, resolved} = resolved_output([autoquality_max_iterations: 1] ++ opts, :png)
    {long, _resolved} = resolved_output([autoquality_max_iterations: 12] ++ opts, :png)
    assert Policy.identity_material(short) == Policy.identity_material(long)
    image = Image.new!(8, 8, color: :red)
    assert {:ok, _stream, "image/png", nil} = Encoder.stream_output(image, resolved, [])
  end

  defp resolved_output(opts, format \\ :jpeg, max_bytes \\ nil) do
    config = Config.resolve!(opts)

    {:ok, output} =
      Config.apply_to_output(%Output{mode: {:explicit, format}, max_bytes: max_bytes}, config)

    policy = Policy.from_output_plan(conn(:get, "/"), output, [])
    {:ok, resolved} = Policy.resolve(policy, format)
    {policy, resolved}
  end
end
