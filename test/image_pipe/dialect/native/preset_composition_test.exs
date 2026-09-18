defmodule ImagePipe.Native.PresetCompositionTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Native

  defp parse(path, presets) do
    config = ImagePipe.Plug.init(presets: presets)
    {result, _metadata} = Native.parse(conn(:get, path <> "/src/images/cat.jpg"), config)
    result
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
    presets = %{"small" => "w=300/then/w=100/pad=5/format=webp"}
    assert {:ok, request} = parse("/preset=small/format=png", presets)
    assert {:ok, ^request} = parse("/w=300/then/w=100/pad=5/format=png", %{})
  end

  test "single-group defaults and presets contribute to the first pipeline group" do
    presets = %{
      "default" => "blur=1",
      "padding" => "pad=5",
      "small" => "w=300/then/w=100"
    }

    assert {:ok, request} = parse("/preset=small,padding", presets)
    assert {:ok, ^request} = parse("/w=300/blur=1/pad=5/then/w=100", %{})
  end

  test "a nested pipeline can be named without repeating its groups" do
    presets = %{"small" => "w=300/then/w=100", "web" => "preset=small/format=webp"}
    assert {:ok, request} = parse("/preset=web", presets)
    assert {:ok, ^request} = parse("/w=300/then/w=100/format=webp", %{})
  end

  test "pipeline presets reject ambiguous group composition" do
    presets = %{"a" => "w=300/then/w=100", "b" => "blur=2/then/pad=5"}

    for path <- ["/preset=a/w=200", "/preset=a/blur=0", "/preset=a/then/w=100", "/preset=a,b"] do
      assert {:error, {:invalid_request, diagnostics}} = parse(path, presets)
      assert Enum.any?(diagnostics, &(&1.reason == :conflicting_preset_pipeline))
    end
  end

  test "configuration rejects unknown references, cycles, malformed groups and sources" do
    for presets <- [
          %{"a" => "preset=missing"},
          %{"a" => "preset=a"},
          %{"a" => "preset=b", "b" => "preset=a"},
          %{"a" => "w=100/then"},
          %{"a" => "w=100/src/secret.jpg"},
          %{"a" => "src64=aHR0cHM6Ly9leGFtcGxlLmNvbQ"},
          %{"a" => "sig=abc/w=100"},
          %{"a" => "w=200/then/w=100", "b" => "preset=a/w=50"}
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
