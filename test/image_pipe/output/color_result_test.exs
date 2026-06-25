defmodule ImagePipe.Output.ColorResultTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Transform.InputColorManagement, as: ICM
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/imgproxy_differential/sources"
  @p3_fixture "#{@sources}/icc_p3.png"
  @plain_srgb_fixture "#{@sources}/small.png"

  # The carry the encoder consumes: a realized image carrying the two private
  # fields the delivery-boundary stamp writes (`Processor.materialize_for_delivery/2`).
  # Built by importing a Display-P3 source (so a real `icc_import` runs) and
  # stamping the recorded source profile + imported marker, mirroring the live
  # stamp site. The live `icc-profile-data` is removed to reproduce the libvips
  # 8.15+ profile-loss the encoder's restore step exists to repair — so the test
  # discriminates the restore+export path from "keep whatever is embedded".
  defp p3_carrier do
    img = Image.open!(@p3_fixture, access: :sequential)
    {:ok, state} = ICM.condition(%State{image: img}, supports_hdr?: false)
    true = state.color_imported?
    {:ok, mem} = VixImage.copy_memory(state.image)

    {:ok, stamped} =
      VixImage.mutate(mem, fn mut ->
        MutableImage.remove(mut, "icc-profile-data")
        MutableImage.set(mut, "imagepipe-icc-backup", :VipsBlob, state.source_color_profile)
        MutableImage.set(mut, "imagepipe-icc-imported", :gint, 1)
        :ok
      end)

    {stamped, state.source_color_profile}
  end

  defp resolved(format, color_profile, opts \\ []) do
    %Resolved{
      format: format,
      quality: :default,
      response_headers: [],
      strip_metadata: Keyword.get(opts, :strip_metadata, true),
      keep_copyright: Keyword.get(opts, :keep_copyright, true),
      color_profile: color_profile
    }
  end

  defp decode(stream) do
    stream
    |> Enum.into(<<>>)
    |> Image.open!(access: :random, fail_on: :error)
  end

  defp header(image, field) do
    case VixImage.header_value(image, field) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  test ":preserve_source + imported re-embeds the source profile (jpeg)" do
    {carrier, p3_bytes} = p3_carrier()

    assert {:ok, stream, "image/jpeg", _meta} =
             Encoder.stream_output(carrier, resolved(:jpeg, :preserve_source), [])

    out = decode(stream)
    assert header(out, "icc-profile-data") == p3_bytes
  end

  test ":preserve_source re-embeds even with strip_metadata: false" do
    {carrier, p3_bytes} = p3_carrier()

    assert {:ok, stream, _, _meta} =
             Encoder.stream_output(
               carrier,
               resolved(:jpeg, :preserve_source, strip_metadata: false),
               []
             )

    assert decode(stream) |> header("icc-profile-data") == p3_bytes
  end

  test ":strip drops the ICC profile even for an imported source" do
    {carrier, _p3_bytes} = p3_carrier()

    assert {:ok, stream, _, _meta} = Encoder.stream_output(carrier, resolved(:jpeg, :strip), [])

    assert decode(stream) |> header("icc-profile-data") == nil
  end

  test "untagged :strip with strip_metadata: false is pixel-identical (no spurious transform)" do
    base = Image.open!(@plain_srgb_fixture, access: :random)

    assert {:ok, stream, _, _meta} =
             Encoder.stream_output(base, resolved(:png, :strip, strip_metadata: false), [])

    out = decode(stream)

    assert {:ok, difference, _diff_image} = Image.compare(base, out, metric: :ae)
    assert difference == +0.0
  end

  describe "color_profile {:convert, target}" do
    test "converts to the target and embeds its profile (untagged sRGB source, N1)" do
      {:ok, image} = Operation.black(16, 16, bands: 3)

      {:ok, stream, _, _meta} =
        Encoder.stream_output(image, resolved(:png, {:convert, :display_p3}), [])

      assert decode(stream) |> header("icc-profile-data") != nil
    end

    test "greyscale source converts to a 3-band RGB target (N2)" do
      {:ok, grey} = Operation.black(16, 16, bands: 1)
      {:ok, grey} = Operation.colourspace(grey, :VIPS_INTERPRETATION_B_W)

      {:ok, stream, _, _meta} =
        Encoder.stream_output(grey, resolved(:png, {:convert, :display_p3}), [])

      out = decode(stream)

      assert VixImage.bands(out) == 3
      assert header(out, "icc-profile-data") != nil
    end

    test "embedded target survives metadata strip (not dropped by maybe_drop_profile)" do
      {:ok, image} = Operation.black(16, 16, bands: 3)
      res = resolved(:jpeg, {:convert, :adobe_rgb}, strip_metadata: true)

      {:ok, stream, _, _meta} = Encoder.stream_output(image, res, [])

      assert decode(stream) |> header("icc-profile-data") != nil
    end

    test "each target embeds its own profile bytes (named-target contract)" do
      {:ok, image} = Operation.black(16, 16, bands: 3)

      embedded = fn target ->
        {:ok, stream, _, _meta} =
          Encoder.stream_output(image, resolved(:png, {:convert, target}), [])

        decode(stream) |> header("icc-profile-data")
      end

      assert embedded.(:srgb) == File.read!(ColorProfile.path!(:srgb))
      assert embedded.(:adobe_rgb) == File.read!(ColorProfile.path!(:adobe_rgb))
      assert embedded.(:display_p3) == File.read!(ColorProfile.path!(:display_p3))
      refute embedded.(:adobe_rgb) == embedded.(:display_p3)
    end
  end
end
