defmodule ImagePipe.Plan.Output.EncoderOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}

  test "structs default every field to nil" do
    assert %JpegOptions{
             interlace: nil,
             subsample_mode: nil,
             trellis_quant: nil,
             overshoot_deringing: nil,
             optimize_scans: nil,
             quant_table: nil
           } = %JpegOptions{}

    assert %PngOptions{interlace: nil, palette: nil, bitdepth: nil, filter: nil} = %PngOptions{}

    assert %WebpOptions{
             lossless: nil,
             near_lossless: nil,
             smart_subsample: nil,
             preset: nil,
             effort: nil
           } = %WebpOptions{}

    assert %AvifOptions{subsample_mode: nil, effort: nil} = %AvifOptions{}
    assert %JxlOptions{effort: nil} = %JxlOptions{}
  end

  test "merge/2 lets non-nil override fields win, nil keeps base" do
    base = %JpegOptions{interlace: true, quant_table: 3}
    over = %JpegOptions{quant_table: 5, trellis_quant: true}

    assert JpegOptions.merge(base, over) ==
             %JpegOptions{interlace: true, quant_table: 5, trellis_quant: true}
  end

  test "merge/2 with all-nil override is a no-op" do
    base = %WebpOptions{preset: :photo, effort: 6}
    assert WebpOptions.merge(base, %WebpOptions{}) == base
  end

  test "all_nil?/1 reports whether any field is set" do
    assert JpegOptions.all_nil?(%JpegOptions{})
    refute JpegOptions.all_nil?(%JpegOptions{interlace: true})
  end
end
