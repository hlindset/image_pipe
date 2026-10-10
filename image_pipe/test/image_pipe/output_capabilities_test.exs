defmodule ImagePipe.Output.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Capabilities

  describe "supports?/1" do
    test "baseline jpeg and png are always supported without probing" do
      assert Capabilities.supports?(:jpeg)
      assert Capabilities.supports?(:png)
    end

    test "returns a boolean for the probed modern formats" do
      assert is_boolean(Capabilities.supports?(:avif))
      assert is_boolean(Capabilities.supports?(:webp))
    end

    test "unknown formats are unsupported" do
      refute Capabilities.supports?(:gif)
    end
  end

  describe "writable/0" do
    test "lists the baseline formats and each probed format the build can write" do
      writable = Capabilities.writable()

      assert [:jpeg, :png] -- writable == []
      assert Enum.all?([:avif, :webp], &(&1 in writable == Capabilities.supports?(&1)))
    end
  end

  describe "probe/0" do
    test "returns :ok and is idempotent" do
      assert Capabilities.probe() == :ok
      assert Capabilities.probe() == :ok
    end
  end
end
