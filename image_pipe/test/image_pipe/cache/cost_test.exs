defmodule ImagePipe.Cache.CostTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Cost
  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  defp info(fields \\ []) do
    struct(
      %Info{
        source_format: :jpeg,
        source_width: 4_000,
        source_height: 3_000,
        shrink: %{w: 1.0, h: 1.0},
        output_format: :jpeg,
        output_width: 800,
        output_height: 600
      },
      fields
    )
  end

  defp output(format, fields \\ []) do
    struct(
      %Resolved{
        format: format,
        quality: {:quality, 80},
        response_headers: [],
        strip_metadata: true,
        keep_copyright: false,
        color_profile: :keep
      },
      fields
    )
  end

  test "a larger source costs more to decode" do
    assert Cost.render(info(source_width: 8_000, source_height: 6_000), output(:jpeg)) >
             Cost.render(info(), output(:jpeg))
  end

  test "shrink-on-load lowers a WebP decode, not a JPEG one" do
    shrunk = %{w: 4.0, h: 4.0}

    assert Cost.render(info(source_format: :webp, shrink: shrunk), output(:jpeg)) <
             Cost.render(info(source_format: :webp), output(:jpeg))

    assert Cost.render(info(shrink: shrunk), output(:jpeg)) == Cost.render(info(), output(:jpeg))
  end

  test "an operation before the resize counts decoded pixels, an effect output pixels" do
    small = [source_width: 1_000, source_height: 750]
    plain = fn fields -> Cost.render(info(fields), output(:jpeg)) end
    trim = fn fields -> plain.([pipeline: [:trim]] ++ fields) - plain.(fields) end
    blur = fn fields -> plain.([pipeline: [:blur]] ++ fields) - plain.(fields) end

    assert trim.([]) > trim.(small)
    assert blur.([]) == blur.(small)
    assert blur.([]) > 0
  end

  test "modern encoders cost more than JPEG, and more with higher effort" do
    jpeg = Cost.render(info(), output(:jpeg))
    webp = Cost.render(info(), output(:webp, encoder_options: %{effort: 4}))
    avif = Cost.render(info(), output(:avif, encoder_options: %{effort: 4}))
    slow_avif = Cost.render(info(), output(:avif, encoder_options: %{effort: 9}))

    assert jpeg < webp
    assert webp < avif
    assert avif < slow_avif
  end

  test "each autoquality iteration adds an encode and a score" do
    plain = Cost.render(info(), output(:avif))
    searched = Cost.render(info(aq: %{iterations: 4, scorer: :full}), output(:avif))
    twice = Cost.render(info(aq: %{iterations: 8, scorer: :full}), output(:avif))
    cropped = Cost.render(info(aq: %{iterations: 4, scorer: :crop, tiles: 1}), output(:avif))

    assert searched > plain
    assert_in_delta twice - searched, searched - plain, 1
    assert cropped < searched
    assert cropped > plain
  end

  test "each detecting group adds the same cost" do
    plain = Cost.render(info(), output(:jpeg))
    one = Cost.render(info(detections: 1), output(:jpeg))
    two = Cost.render(info(detections: 2), output(:jpeg))

    assert one > plain
    assert two - one == one - plain
  end

  test "terminals have a positive constant cost" do
    for kind <- [:info, :blurhash, :lqip_css], do: assert(Cost.terminal(kind) > 0)
  end
end
