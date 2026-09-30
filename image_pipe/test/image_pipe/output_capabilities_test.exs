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

  describe "supports?/2 with an injected capability map" do
    # The override branch (injected verdict decides) is exercised end-to-end at
    # the consumer layer (output negotiation, output policy, wire conformance).
    # Only the fall-through branch — a format absent from a non-empty map still
    # gets its real capability — is pinned directly here.
    test "a format absent from the injected map falls through to the real capability" do
      opts = [output_capabilities: %{avif: false}]
      assert Capabilities.supports?(:jpeg, opts)
    end
  end

  describe "probe/0" do
    test "returns :ok and is idempotent" do
      assert Capabilities.probe() == :ok
      assert Capabilities.probe() == :ok
    end
  end
end
