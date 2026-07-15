defmodule ImagePipe.Dialect.Native.PresetsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.Presets

  describe "validate_config/1" do
    test "an empty presets map is valid" do
      assert Presets.validate_config(%{}) == {:ok, %{}}
    end

    test "every fragment parses as a group-scoped-only option fragment" do
      presets = %{"card" => "w=300/h=200/fit=cover", "square" => "crop=1,1"}

      assert Presets.validate_config(presets) == {:ok, presets}
    end

    test "an unknown key in a preset fragment is a config-time error" do
      assert {:error, message} = Presets.validate_config(%{"bad" => "bogus=1"})
      assert message =~ "bad"
    end

    test "a then segment in a preset fragment is a config-time error" do
      assert {:error, message} = Presets.validate_config(%{"bad" => "w=300/then/h=200"})
      assert is_binary(message)
    end

    test "a request-scoped key in a preset fragment is a config-time error" do
      assert {:error, _message} = Presets.validate_config(%{"bad" => "w=300/format=webp"})
    end

    test "a src segment in a preset fragment is a config-time error" do
      assert {:error, _message} = Presets.validate_config(%{"bad" => "w=300/src"})
    end
  end

  describe "expand/4 — no-op cases" do
    test "no presets configured, no preset names requested" do
      assert Presets.expand(%{"w" => 800}, [], %{}, {0, 0}) == {%{"w" => 800}, []}
    end

    test "presets configured but none requested and no default preset" do
      config = %{"card" => "w=300"}

      assert Presets.expand(%{"w" => 800}, [], config, {0, 0}) == {%{"w" => 800}, []}
    end
  end

  describe "expand/4 — precedence chain" do
    test "a named preset contributes a key absent from the explicit group map" do
      config = %{"card" => "w=300/fit=cover"}

      assert Presets.expand(%{}, ["card"], config, {0, 0}) ==
               {%{"w" => 300, "fit" => :cover}, []}
    end

    test "the default preset applies even without an explicit preset= request" do
      config = %{"default" => "blur=2"}

      assert Presets.expand(%{"w" => 800}, [], config, {0, 0}) ==
               {%{"w" => 800, "blur" => 2.0}, []}
    end

    test "a named preset displaces the default preset's value for a shared key" do
      config = %{"default" => "blur=2", "card" => "blur=5"}

      assert Presets.expand(%{}, ["card"], config, {0, 0}) == {%{"blur" => 5.0}, []}
    end

    test "later-listed named presets displace earlier ones for a shared key" do
      config = %{"a" => "blur=2", "b" => "blur=5"}

      assert Presets.expand(%{}, ["a", "b"], config, {0, 0}) == {%{"blur" => 5.0}, []}
      assert Presets.expand(%{}, ["b", "a"], config, {0, 0}) == {%{"blur" => 2.0}, []}
    end

    test "the explicit group map displaces every preset level for a shared key" do
      config = %{"default" => "w=100", "card" => "w=300"}

      assert Presets.expand(%{"w" => 800}, ["card"], config, {0, 0}) == {%{"w" => 800}, []}
    end

    test "non-conflicting keys across levels all survive into the merged map" do
      config = %{"default" => "trim=auto", "card" => "fit=cover"}

      assert Presets.expand(%{"w" => 800}, ["card"], config, {0, 0}) ==
               {%{"w" => 800, "fit" => :cover, "trim" => :auto}, []}
    end
  end

  describe "expand/4 — unknown preset" do
    test "an unknown preset name yields an :unknown_preset diagnostic and leaves the map unchanged" do
      {map, diagnostics} = Presets.expand(%{"w" => 800}, ["nope"], %{}, {3, 6})

      assert map == %{"w" => 800}
      assert [%{reason: :unknown_preset, spans: [{3, 6}]}] = diagnostics
    end

    test "one diagnostic per unknown name, known names do not also error" do
      config = %{"card" => "w=300"}

      {_map, diagnostics} = Presets.expand(%{}, ["card", "nope1", "nope2"], config, {0, 0})

      assert length(diagnostics) == 2
      assert Enum.all?(diagnostics, &(&1.reason == :unknown_preset))
    end
  end
end
