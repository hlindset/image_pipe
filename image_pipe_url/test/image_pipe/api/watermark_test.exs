defmodule ImagePipe.API.WatermarkTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Group
  alias ImagePipe.Security

  @signing_key Base.encode16(:binary.copy(<<31>>, 32))
  @source_key String.duplicate("2a", 32)
  @hosted [watermarks: %{"logo" => [], "badge" => []}, request_watermarks: true]

  defp parse(segments, config \\ @hosted) do
    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, "cat.jpg", {0, 7}}
    }

    Parser.parse(lexed, ImagePipe.URL.config().options ++ config)
  end

  defp reasons({:error, {:invalid_request, diagnostics}}), do: Enum.map(diagnostics, & &1.reason)
  defp reasons({:ok, request}), do: Enum.map(request.ignored, & &1.reason)

  defp watermark(segments, config \\ @hosted) do
    {:ok, %Spec{groups: [%Group{watermark: watermark}]}} = parse(segments, config)
    watermark
  end

  defp source64(source), do: Base.url_encode64(source, padding: false)

  defp token_iv(token) do
    <<_version, iv::binary-size(16), _rest::binary>> = Base.url_decode64!(token, padding: false)
    iv
  end

  test "a named asset resolves its placement defaults" do
    assert watermark(["wm=logo"]) == %{
             asset: {:name, "logo"},
             opacity: 1.0,
             scale: nil,
             at: :center,
             offset: {{:px, 0}, {:px, 0}},
             tile: false,
             gap: {{:px, 0}, {:px, 0}}
           }
  end

  test "every option contributes canonical intent" do
    assert watermark([
             "wm-src64=#{source64("https://brand.test/mark.png")}",
             "wm-opacity=0.5",
             "wm-scale=0.25",
             "wm-at=bottom-right",
             "wm-offset=10,-5pct",
             "wm-tile",
             "wm-gap=0,20"
           ]) == %{
             asset: {:src, "https://brand.test/mark.png"},
             opacity: 0.5,
             scale: 0.25,
             at: :bottom_right,
             offset: {{:px, 10.0}, {:pct, -5.0}},
             tile: true,
             gap: {{:px, 0}, {:px, 20.0}}
           }

    assert %{asset: {:enc, "AQIDBA"}} = watermark(["wm-enc=AQIDBA"])
  end

  property "option order within a group does not change the request" do
    options = ["wm=logo", "wm-opacity=0.4", "wm-at=top", "wm-offset=3,4", "wm-tile", "wm-gap=5,6"]

    check all shuffled <- constant(options) |> map(&Enum.shuffle/1) do
      assert parse(shuffled) == parse(options)
    end
  end

  test "zero opacity shares identity with the absent watermark" do
    assert parse(["wm=logo", "wm-opacity=0", "wm-scale=0.5"]) == parse([])
  end

  test "watermarks reset at a group boundary" do
    assert {:ok,
            %Spec{groups: [%Group{watermark: %{asset: {:name, "logo"}}}, %Group{watermark: nil}]}} =
             parse(["wm=logo", "-", "w=10"])
  end

  test "asset forms are mutually exclusive" do
    for options <- [
          ["wm=logo", "wm-src64=#{source64("mark.png")}"],
          ["wm=logo", "wm-enc=AQIDBA"],
          ["wm-src64=#{source64("mark.png")}", "wm-enc=AQIDBA"]
        ] do
      assert :mutually_exclusive_options in reasons(parse(options))
    end
  end

  test "placement options require an asset and gaps require tiling" do
    for option <- [
          "wm-opacity=0.5",
          "wm-scale=0.5",
          "wm-at=top",
          "wm-offset=1,1",
          "wm-tile",
          "wm-gap=1,1"
        ] do
      assert :inert_option in reasons(parse([option]))
    end

    assert :inert_option in reasons(parse(["wm=logo", "wm-gap=1,1"]))
    assert :inert_option in reasons(parse(["wm=logo", "wm-tile=false", "wm-gap=1,1"]))
  end

  test "malformed values fail at the request boundary" do
    for {segment, reason} <- [
          {"wm=Logo", :invalid_watermark},
          {"wm=", :invalid_watermark},
          {"wm-src64=bWFyaw==", :invalid_watermark_source},
          {"wm-src64=_w", :invalid_watermark_source},
          {"wm-enc=a.b", :invalid_watermark_token},
          {"wm-opacity=1.5", :invalid_watermark_opacity},
          {"wm-scale=0", :invalid_watermark_scale},
          {"wm-scale=1.1", :invalid_watermark_scale},
          {"wm-at=smart", :invalid_anchor},
          {"wm-offset=1", :invalid_offset},
          {"wm-gap=-1,0", :invalid_watermark_gap}
        ] do
      assert reason in reasons(parse(["wm=logo", segment])) or
               reason in reasons(parse([segment]))
    end
  end

  test "host configuration rejects unknown names and disabled request sources" do
    assert :unknown_watermark in reasons(parse(["wm=other"]))

    gated = Keyword.put(@hosted, :request_watermarks, false)
    assert {:ok, _request} = parse(["wm=logo"], gated)

    for segment <- ["wm-src64=#{source64("mark.png")}", "wm-enc=AQIDBA"] do
      assert :watermark_source_disabled in reasons(parse([segment], gated))
    end
  end

  test "diagnostic paths mask concealed watermark tokens" do
    assert Path.diagnostic_path("/w=10/wm-enc=secret/src/cat.jpg") ==
             "/w=10/wm-enc=******/src/cat.jpg"
  end

  describe "builder" do
    test "serializes every option and parses back to the same intent" do
      builder =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(
          watermark: :logo,
          watermark_opacity: 0.5,
          watermark_scale: 0.25,
          watermark_at: :bottom_right,
          watermark_offset: {10, {:pct, -5}},
          watermark_tile: true,
          watermark_gap: {0, 20}
        )

      url = ImagePipe.URL.url!(builder, "cat.jpg")

      assert url ==
               "/wm=logo/wm-opacity=0.5/wm-scale=0.25/wm-at=bottom-right/wm-offset=10,-5pct/wm-tile/wm-gap=0,20/src/cat.jpg"

      {:ok, %{segments: segments, source: source}} = Path.extract(url, "")
      assert {:ok, request} = Parser.parse(%{segments: segments, source: source}, @hosted)
      assert {:ok, request} == ImagePipe.Plan.to_spec(builder.plan)
    end

    test "watermark sources use src64, or wm-enc when sources are concealed" do
      plain =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(watermark_source: "brand/mark.png")
        |> ImagePipe.URL.url!("cat.jpg")

      assert plain == "/wm-src64=#{source64("brand/mark.png")}/src/cat.jpg"

      config =
        ImagePipe.URL.config(
          keys: [@signing_key],
          source_encryption_keys: [@source_key],
          encrypt_source: true
        )

      concealed =
        ImagePipe.URL.new(config)
        |> ImagePipe.URL.group(watermark_source: "brand/mark.png")
        |> ImagePipe.URL.url!("cat.jpg")

      [_, token] = Regex.run(~r{/wm-enc=([A-Za-z0-9_-]+)/enc/}, concealed)
      assert Security.decrypt_source(token, config.options) == {:ok, "brand/mark.png"}
    end

    test "an explicit IV conceals the main source and salts each watermark source" do
      config =
        ImagePipe.URL.config(
          keys: [@signing_key],
          source_encryption_keys: [@source_key],
          encrypt_source: true
        )

      iv = :binary.copy(<<7>>, 16)

      url = fn watermark ->
        ImagePipe.URL.new(config)
        |> ImagePipe.URL.group(watermark_source: watermark)
        |> ImagePipe.URL.url!("cat.jpg", iv: iv)
      end

      first = url.("brand/a.png")
      assert first == url.("brand/a.png")

      [_, mark] = Regex.run(~r{/wm-enc=([A-Za-z0-9_-]+)/}, first)
      [_, main] = Regex.run(~r{/enc/([A-Za-z0-9_-]+)$}, first)
      [_, other] = Regex.run(~r{/wm-enc=([A-Za-z0-9_-]+)/}, url.("brand/b.png"))

      assert token_iv(main) == iv
      assert token_iv(mark) not in [iv, token_iv(other)]
      assert Security.decrypt_source(mark, config.options) == {:ok, "brand/a.png"}
      assert Security.decrypt_source(main, config.options) == {:ok, "cat.jpg"}

      {:ok, deterministic} = Security.encrypt_source("brand/a.png", config.options, [])
      refute token_iv(deterministic) == token_iv(mark)
    end

    test "rejects malformed builder values" do
      for options <- [
            [watermark: "logo"],
            [watermark: :Logo],
            [watermark_source: ""],
            [watermark_scale: 0],
            [watermark_gap: {-1, 0}]
          ] do
        assert_raise ArgumentError, fn -> ImagePipe.URL.group(ImagePipe.URL.new(), options) end
      end
    end
  end
end
