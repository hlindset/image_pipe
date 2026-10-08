defmodule ImagePipe.URLWithIssuesTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan.Spec.Issue

  test "a valid plan gives the same URL as url!/3 and no issues" do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 300, fit: :cover])

    assert ImagePipe.URL.url_with_issues(builder, "cat.jpg") ==
             {ImagePipe.URL.url!(builder, "cat.jpg"), []}
  end

  test "a repaired mistake gives the repaired URL and its warning" do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.group(blur: 1, blur: 2)

    assert {"/blur=2/src/cat.jpg", [%Issue{reason: :repeated_option, severity: :warning}]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  test "a rejected option is written as given, marked so the server rejects it" do
    for {builder, url, location} <- [
          {ImagePipe.URL.group(ImagePipe.URL.new(), resize: [width: 300, fit: :fill]),
           "/w=300/fit=!fill/src/cat.jpg", {:group, 0, :fit}},
          {ImagePipe.URL.group(ImagePipe.URL.new(), crop: {0, 20}), "/crop=!0,20/src/cat.jpg",
           {:group, 0, :crop}},
          {ImagePipe.URL.output(ImagePipe.URL.new(), format: :bmp), "/format=!bmp/src/cat.jpg",
           {:request, :format}},
          {ImagePipe.URL.new(orient: :sideways), "/orient=!sideways/src/cat.jpg",
           {:request, :orient}},
          {ImagePipe.URL.group(ImagePipe.URL.new(), extend_at: :top_middle),
           "/extend-at=!top-middle/src/cat.jpg", {:group, 0, :extend_at}}
        ] do
      assert {^url, [%Issue{reason: :invalid_value, locations: [^location]}]} =
               ImagePipe.URL.url_with_issues(builder, "cat.jpg")
    end
  end

  test "an unknown option is written under its own name" do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.group(blur: 1, shape_mode: :round)

    assert {"/blur=1/shape-mode=!round/src/cat.jpg", [%Issue{reason: :unknown_option}]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  test "rejected options stay in their group" do
    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(blur: -1)
      |> ImagePipe.URL.group(sharpen: 1, flip: :diag)
      |> ImagePipe.URL.output(quality: 101)

    assert {"/blur=!-1/-/sharpen=1/flip=!diag/q=!101/src/cat.jpg", [_, _, _]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  test "every rejected option gives a URL the server refuses" do
    for options <- [
          [resize: [width: 0]],
          [resize: [width: "400"]],
          [resize: 400],
          [blur: -1],
          [progressive_blur: [sigma: -1]],
          [progressive_blur: [direction: 90]],
          [dpr: 0],
          [crop: {0, 20}],
          [region: {-1, 0, 20, 20}],
          [region: {0, {:pct, -5}, 20, 20}],
          [gray: "true"],
          [detect: []],
          [detect: ["face", "face"]],
          [background: {"red", 2}],
          [gradient: [opacity: 0.5, color: "red", start: -1]],
          [presets: ["bad/name"]],
          [watermark: "logo"],
          [watermark_source: ""],
          [mystery: 1]
        ] do
      builder = ImagePipe.URL.group(ImagePipe.URL.new(), options)
      {url, [_ | _]} = ImagePipe.URL.url_with_issues(builder, "cat.jpg")
      assert {:error, _reason} = parse(url), "#{inspect(options)} gave #{url}"
    end

    for options <- [
          [quality: 101],
          [format: :bmp],
          [jpeg_options: []],
          [jpeg_options: [quant_table: 9]],
          [format_qualities: []],
          [autoquality: 0],
          [terminal: {:info, [:image]}],
          [mystery: 1]
        ] do
      builder = ImagePipe.URL.output(ImagePipe.URL.new(), options)
      {url, [_ | _]} = ImagePipe.URL.url_with_issues(builder, "cat.jpg")
      assert {:error, _reason} = parse(url), "#{inspect(options)} gave #{url}"
    end
  end

  test "options that don't combine are written as given, with their issue" do
    config = ImagePipe.URL.config(validate_against: [])

    builder =
      ImagePipe.URL.new(config) |> ImagePipe.URL.group(crop: {20, 20}, region: {0, 0, 20, 20})

    assert {"/crop=20,20/region=0,0,20,20/src/cat.jpg", [%Issue{severity: :error}]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  test "an invalid source is written as given, with an issue" do
    builder = ImagePipe.URL.group(ImagePipe.URL.new(), blur: 1)

    for {source, url} <- [
          {"", "/blur=1/src/"},
          {<<255>>, "/blur=1/src/%FF"},
          {nil, "/blur=1/src/"}
        ] do
      assert {^url, [%Issue{reason: :invalid_source, locations: [], severity: :error}]} =
               ImagePipe.URL.url_with_issues(builder, source)
    end
  end

  test "the URL is signed and keeps the base URL" do
    config =
      ImagePipe.URL.config(
        base_url: "/images",
        keys: [String.duplicate("00112233445566778899aabbccddeeff", 2)]
      )

    builder = ImagePipe.URL.new(config) |> ImagePipe.URL.group(blur: -1)

    assert {"/images/sig=" <> _, [_]} = ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  test "a plan with too many segments is written in full" do
    builder =
      Enum.reduce(1..70, ImagePipe.URL.new(), fn _i, builder ->
        ImagePipe.URL.group(builder, blur: 1)
      end)

    assert {:error, :too_many_options} = ImagePipe.URL.url(builder, "cat.jpg")

    assert {url, [%Issue{reason: :too_many_options}]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")

    assert length(String.split(url, "/-/")) == 70
  end

  test "invalid url options raise, whatever the source" do
    for source <- ["cat.jpg", ""], options <- [[iv: :bogus], [iv: :random], [mystery: 1]] do
      assert_raise ArgumentError, fn ->
        ImagePipe.URL.url_with_issues(ImagePipe.URL.new(), source, options)
      end
    end

    builder = ImagePipe.URL.new(encrypted_config())

    assert_raise ArgumentError, fn ->
      ImagePipe.URL.url_with_issues(builder, "cat.jpg", iv: :bogus)
    end
  end

  test "with source encryption, no source is written in plain text" do
    builder =
      ImagePipe.URL.new(encrypted_config())
      |> ImagePipe.URL.group(watermark_source: :private_mark)

    {url, [%Issue{reason: :invalid_value}, %Issue{reason: :invalid_source}]} =
      ImagePipe.URL.url_with_issues(builder, <<"private", 255>>)

    refute url =~ "private"
    assert url =~ "/wm-src64=!/src/"
  end

  test "an unknown option name is escaped" do
    builder = ImagePipe.URL.group(ImagePipe.URL.new(), [{:"a/b=c", 1}])

    assert {"/a%2Fb%3Dc=!1/src/cat.jpg", [%Issue{reason: :unknown_option}]} =
             ImagePipe.URL.url_with_issues(builder, "cat.jpg")
  end

  defp encrypted_config do
    ImagePipe.URL.config(
      keys: [Base.encode16(:binary.copy(<<31>>, 32))],
      source_encryption_keys: [String.duplicate("2a", 32)],
      encrypt_source: true
    )
  end

  defp parse(url) do
    with {:ok, lexed} <- Path.extract(url, ""),
         do: Parser.parse(lexed, ImagePipe.URL.config().options)
  end
end
