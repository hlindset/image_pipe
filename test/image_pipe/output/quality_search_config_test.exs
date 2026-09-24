defmodule ImagePipe.Output.QualitySearchConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy, as: APIOutput
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plug.Config

  test "configured search iterations reach encoding and representation identity" do
    image = Image.open!("priv/static/images/beach.jpg") |> Image.thumbnail!(128)
    {_policy, reference} = resolved_output(quality: 50)
    {:ok, encoded, "image/jpeg", nil} = Encoder.stream_output(image, reference, nil, [])
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

    {:ok, [_short_body], "image/jpeg", short_meta} = Encoder.stream_output(image, short, nil, [])
    {:ok, [_long_body], "image/jpeg", long_meta} = Encoder.stream_output(image, long, nil, [])
    assert short_meta.iterations < long_meta.iterations
    refute short_meta.quality == long_meta.quality
  end

  test "an inactive iteration limit does not fragment identity" do
    {short, _resolved} = resolved_output(autoquality_max_iterations: 1)
    {long, _resolved} = resolved_output(autoquality_max_iterations: 12)
    assert Policy.identity_material(short) == Policy.identity_material(long)
  end

  test "PNG does not search or retain an unused iteration limit in identity" do
    opts = [autoquality_method: :ssimulacra2]
    {short, resolved} = resolved_output([autoquality_max_iterations: 1] ++ opts, :png)
    {long, _resolved} = resolved_output([autoquality_max_iterations: 12] ++ opts, :png)
    assert Policy.identity_material(short) == Policy.identity_material(long)
    image = Image.new!(8, 8, color: :red)
    assert {:ok, _stream, "image/png", nil} = Encoder.stream_output(image, resolved, nil, [])
  end

  test "lossless WebP omits its unused iteration limit from explicit and negotiated identity" do
    opts = [
      autoquality_method: :ssimulacra2,
      webp_options: %Output.WebpOptions{lossless: true}
    ]

    explicit_materials =
      for iterations <- [1, 12] do
        {policy, _resolved} =
          resolved_output([autoquality_max_iterations: iterations] ++ opts, :webp)

        Policy.identity_material(policy)
      end

    negotiated_materials =
      for iterations <- [1, 12] do
        config = Config.validate!([autoquality_max_iterations: iterations] ++ opts)
        policy = output_policy(config, nil, nil, "image/webp")
        assert Policy.identity_selection(policy) == {:auto_head, :webp}
        Policy.identity_material(policy)
      end

    assert [material, material] = explicit_materials
    assert [material, material] = negotiated_materials
  end

  defp resolved_output(opts, format \\ :jpeg, max_bytes \\ nil) do
    config = Config.validate!(opts)
    policy = output_policy(config, format, max_bytes)
    {:ok, resolved} = Policy.resolve(policy, format)
    {policy, resolved}
  end

  defp output_policy(config, format, max_bytes, accept_header \\ "") do
    segments =
      []
      |> maybe_add_format(format)
      |> maybe_add_max_bytes(max_bytes)

    source = "images/test.jpg"

    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, source, {0, byte_size(source)}}
    }

    assert {:ok, request} = Parser.parse(lexed, config)
    assert {:ok, output} = APIOutput.resolve(request.output, config, accept_header)
    output
  end

  defp maybe_add_format(segments, nil), do: segments
  defp maybe_add_format(segments, format), do: segments ++ ["format=#{format}"]

  defp maybe_add_max_bytes(segments, nil), do: segments
  defp maybe_add_max_bytes(segments, max_bytes), do: segments ++ ["max-bytes=#{max_bytes}"]
end
