defmodule ImagePipe.API.PresetCompositionTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.API

  defp parse(path, presets) do
    config = ImagePipe.Plug.init(presets: presets)
    {result, _metadata} = API.parse(conn(:get, path <> "/src/images/cat.jpg"), config)

    case result do
      {:ok, request, _source} -> {:ok, request}
      {:error, _} = error -> error
    end
  end

  test "nested presets resolve with default, named and explicit precedence" do
    presets = %{
      "default" => "q=60/blur=1",
      "base" => "w=200/format=webp",
      "card" => "preset=base/h=100/fit=cover/q=80"
    }

    assert {:ok, request} = parse("/preset=card/w=300/q=90", presets)
    assert {:ok, ^request} = parse("/w=300/h=100/fit=cover/blur=1/format=webp/q=90", %{})
  end

  test "effect options replace earlier preset values per key" do
    presets = %{
      "base" =>
        "sharpen=1/pixelate=8/brightness=10/contrast=1.5/monochrome=0.5,red/gradient=1,blue,left",
      "tone" => "brightness=-20/monochrome=1,blue/colorize=0.5,red,keep-alpha"
    }

    assert {:ok, expected} =
             parse(
               "/sharpen=1/pixelate=8/brightness=-20/contrast=2/monochrome=1,blue/colorize=0.5,red,keep-alpha/gradient=1,blue,left",
               %{}
             )

    assert {:ok, ^expected} = parse("/preset=base,tone/contrast=2", presets)
  end

  test "q and autoquality form one atomic preset override family" do
    presets = %{
      "fixed" => "q=80",
      "adaptive" => "autoquality=ssimulacra2,target:78",
      "off" => "q=75/autoquality=none"
    }

    assert {:ok, expected_none} = parse("/autoquality=none", %{})
    assert {:ok, ^expected_none} = parse("/preset=fixed/autoquality=none", presets)

    assert {:ok, expected_fixed} = parse("/q=90", %{})
    assert {:ok, ^expected_fixed} = parse("/preset=adaptive/q=90", presets)

    assert {:ok, expected_off} = parse("/q=75/autoquality=none", %{})
    assert {:ok, ^expected_off} = parse("/preset=off", presets)
  end

  test "presets carry info delivery and storage controls with ordinary per-key precedence" do
    presets = %{
      "download" =>
        "output=info/filename=from-preset/attachment/cb=preset-v1/expires=1999999999/debug"
    }

    assert {:ok, request} =
             parse(
               "/preset=download/filename=explicit/attachment=false/cb=explicit-v2",
               presets
             )

    assert request.output.terminal == :info
    assert request.filename == "explicit"
    assert request.attachment? == false
    assert request.cachebuster == "explicit-v2"
    assert request.expires == 1_999_999_999
    assert request.debug?
  end

  test "an explicit guide replaces a preset's alternative guide" do
    for {preset_guide, explicit_guide} <- [
          {"anchor=top-left", "focus=0.75,0.25"},
          {"focus=0.75,0.25", "anchor=top-left"},
          {"anchor=top-left/anchor-offset=2,3", "detect=face"},
          {"detect=all:1,face:3", "anchor=top-left"}
        ] do
      presets = %{"card" => "crop=60,40/#{preset_guide}"}

      assert {:ok, request} = parse("/preset=card/#{explicit_guide}", presets)
      assert {:ok, ^request} = parse("/crop=60,40/#{explicit_guide}", %{})
    end
  end

  test "later and nested presets replace earlier guide alternatives" do
    presets = %{
      "base" => "crop=60,40/anchor=top-left",
      "focus" => "focus=0.75,0.25",
      "card" => "preset=base/focus=0.75,0.25"
    }

    assert {:ok, expected} = parse("/crop=60,40/focus=0.75,0.25", %{})
    assert {:ok, ^expected} = parse("/preset=base,focus", presets)
    assert {:ok, ^expected} = parse("/preset=card", presets)
  end

  test "later and nested detection presets replace inherited guide alternatives" do
    presets = %{
      "base" => "crop=60,40/anchor=top-left/anchor-offset=2,3",
      "detect" => "detect=all:1,face:3",
      "card" => "preset=base/detect=all:1,face:3"
    }

    assert {:ok, expected} = parse("/crop=60,40/detect=all:1,face:3", %{})
    assert {:ok, ^expected} = parse("/preset=base,detect", presets)
    assert {:ok, ^expected} = parse("/preset=card", presets)
  end

  test "guide overrides replace inherited anchor offsets" do
    presets = %{
      "anchor" => "crop=60,40/anchor=top-left/anchor-offset=5,6",
      "focus" => "focus=0.75,0.25",
      "nested" => "preset=anchor/focus=0.75,0.25"
    }

    assert {:ok, focus_expected} = parse("/crop=60,40/focus=0.75,0.25", %{})
    assert {:ok, ^focus_expected} = parse("/preset=anchor/focus=0.75,0.25", presets)
    assert {:ok, ^focus_expected} = parse("/preset=anchor,focus", presets)
    assert {:ok, ^focus_expected} = parse("/preset=nested", presets)

    assert {:ok, anchor_expected} =
             parse("/crop=60,40/anchor=bottom-right/anchor-offset=-2,3", %{})

    assert {:ok, ^anchor_expected} =
             parse("/preset=anchor/anchor=bottom-right/anchor-offset=-2,3", presets)
  end

  test "a region replacement prunes preset crop-ratio modifiers" do
    presets = %{
      "crop" => "crop=60,40/crop-ratio=3:2/crop-ratio-enlarge",
      "region" => "region=10,20,30,40"
    }

    assert {:ok, expected} = parse("/region=10,20,30,40", %{})
    assert {:ok, ^expected} = parse("/preset=crop/region=10,20,30,40", presets)
    assert {:ok, ^expected} = parse("/preset=crop,region", presets)
  end

  test "a region replacement prunes an inherited guide without another consumer" do
    presets = %{
      "crop" => "crop=60,40/anchor=top-left",
      "detected" => "crop=60,40/detect=face",
      "region" => "region=10,20,30,40",
      "nested" => "preset=crop/region=10,20,30,40",
      "cover" => "crop=60,40/anchor=top-left/w=100/h=100/fit=cover"
    }

    assert {:ok, expected} = parse("/region=10,20,30,40", %{})
    assert {:ok, ^expected} = parse("/preset=crop/region=10,20,30,40", presets)
    assert {:ok, ^expected} = parse("/preset=crop,region", presets)
    assert {:ok, ^expected} = parse("/preset=nested", presets)
    assert {:ok, ^expected} = parse("/preset=detected/region=10,20,30,40", presets)

    assert {:ok, cover_expected} =
             parse("/region=10,20,30,40/w=100/h=100/fit=cover/anchor=top-left", %{})

    assert {:ok, ^cover_expected} = parse("/preset=cover/region=10,20,30,40", presets)

    assert {:error, {:invalid_request, diagnostics}} =
             parse("/preset=crop/region=10,20,30,40/anchor=bottom-right", presets)

    assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
  end

  test "a crop replacement removes an earlier region" do
    presets = %{
      "region" => "region=10,20,30,40",
      "crop" => "crop=60,40"
    }

    assert {:ok, expected} = parse("/crop=60,40", %{})
    assert {:ok, ^expected} = parse("/preset=region/crop=60,40", presets)
    assert {:ok, ^expected} = parse("/preset=region,crop", presets)
  end

  test "canvas overrides replace inherited mode, placement and offset together" do
    presets = %{
      "box" => "w=60/h=40/extend/extend-at=top-left/extend-offset=2,3",
      "ratio" => "extend-ratio/extend-at=bottom-right/extend-offset=-4,5",
      "nested" => "preset=box/extend-ratio/extend-at=bottom-right/extend-offset=-4,5"
    }

    assert {:ok, disabled_expected} = parse("/w=60/h=40", %{})
    assert {:ok, ^disabled_expected} = parse("/preset=box/extend=false", presets)

    assert {:ok, ratio_expected} =
             parse(
               "/w=60/h=40/extend-ratio/extend-at=bottom-right/extend-offset=-4,5",
               %{}
             )

    assert {:ok, ^ratio_expected} = parse("/preset=box,ratio", presets)
    assert {:ok, ^ratio_expected} = parse("/preset=nested", presets)
  end

  test "same-layer canvas contradictions and stranded dependents remain errors" do
    for {fragment, reason} <- [
          {"w=60/h=40/extend/extend-ratio", :mutually_exclusive_options},
          {"w=60/h=40/extend=false/extend-at=top", :inert_option}
        ] do
      assert {:error, {:invalid_request, diagnostics}} =
               parse("/preset=bad", %{"bad" => fragment})

      assert Enum.any?(diagnostics, &(&1.reason == reason))
    end
  end

  test "contradictory alternatives in one layer remain errors" do
    for fragment <- [
          "crop=60,40/region=10,20,30,40",
          "crop=60,40/anchor=top-left/focus=0.75,0.25",
          "crop=60,40/anchor=top-left/detect=face",
          "crop=60,40/focus=0.75,0.25/detect=face"
        ] do
      assert {:error, {:invalid_request, diagnostics}} =
               parse("/preset=bad", %{"bad" => fragment})

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end
  end

  test "configured preset names must be selectable by the URL grammar" do
    for name <- ["", "bad/name", "two,names", "has space", "bad\n"] do
      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(presets: %{name => "w=100"})
      end
    end

    assert {:ok, request} = parse("/preset=Card_v2.small-1", %{"Card_v2.small-1" => "w=100"})
    assert hd(request.groups).resize.w == 100
  end

  test "pipeline presets expand completely and allow output overrides" do
    presets = %{"small" => "w=300/-/w=100/pad=5/format=webp"}
    assert {:ok, request} = parse("/preset=small/format=png", presets)
    assert {:ok, ^request} = parse("/w=300/-/w=100/pad=5/format=png", %{})
  end

  test "single-group defaults and presets contribute to the first pipeline group" do
    presets = %{
      "default" => "blur=1",
      "padding" => "pad=5",
      "small" => "w=300/-/w=100"
    }

    assert {:ok, request} = parse("/preset=small,padding", presets)
    assert {:ok, ^request} = parse("/w=300/blur=1/pad=5/-/w=100", %{})
  end

  test "a nested pipeline can be named without repeating its groups" do
    presets = %{"small" => "w=300/-/w=100", "web" => "preset=small/format=webp"}
    assert {:ok, request} = parse("/preset=web", presets)
    assert {:ok, ^request} = parse("/w=300/-/w=100/format=webp", %{})
  end

  test "pipeline presets reject ambiguous group composition" do
    presets = %{"a" => "w=300/-/w=100", "b" => "blur=2/-/pad=5"}

    for path <- ["/preset=a/w=200", "/preset=a/blur=0", "/preset=a/-/w=100", "/preset=a,b"] do
      assert {:error, {:invalid_request, diagnostics}} = parse(path, presets)
      assert Enum.any?(diagnostics, &(&1.reason == :conflicting_preset_pipeline))
    end
  end

  test "configuration rejects unknown references, cycles, malformed groups and sources" do
    for presets <- [
          %{"a" => "preset=missing"},
          %{"a" => "preset=a"},
          %{"a" => "preset=b", "b" => "preset=a"},
          %{"a" => "w=100/-"},
          %{"a" => "w=100/src/secret.jpg"},
          %{"a" => "src64=aHR0cHM6Ly9leGFtcGxlLmNvbQ"},
          %{"a" => "sig=abc/w=100"},
          %{"a" => "w=200/-/w=100", "b" => "preset=a/w=50"}
        ] do
      assert_raise ArgumentError, fn -> ImagePipe.Plug.init(presets: presets) end
    end
  end

  test "validation runs against expanded request-scoped options" do
    assert {:error, {:invalid_request, diagnostics}} =
             parse("/preset=text", %{"text" => "output=blurhash/format=png"})

    assert [%{reason: :inert_option, spans: [{1, 11}]}] = diagnostics
  end
end
