defmodule ImagePipe.Dialect.Declarative.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Declarative

  test "config_keys/0 lists exactly the keys the tier reads" do
    assert Enum.sort(Declarative.config_keys()) ==
             Enum.sort([:http_cache, :detector, :detector_required, :storage_inputs])
  end

  describe "http_cache" do
    test "defaults to disabled" do
      assert Declarative.validate_config!([])[:http_cache] == [mode: :disabled]
    end

    test "accepts enabled mode" do
      assert Declarative.validate_config!(http_cache: [mode: :enabled])[:http_cache] ==
               [mode: :enabled]
    end

    test "rejects an unknown mode" do
      assert_raise ArgumentError, ~r/invalid ImagePipe declarative dialect options/, fn ->
        Declarative.validate_config!(http_cache: [mode: :public])
      end
    end
  end

  describe "detector" do
    test "defaults to :default with detector_required false" do
      validated = Declarative.validate_config!([])

      assert validated[:detector] == :default
      assert validated[:detector_required] == false
    end

    test "accepts a host module and detector_required: true" do
      validated =
        Declarative.validate_config!(detector: __MODULE__, detector_required: true)

      assert validated[:detector] == __MODULE__
      assert validated[:detector_required] == true
    end

    test "accepts nil to disable detection" do
      assert Declarative.validate_config!(detector: nil)[:detector] == nil
    end

    test "detector_required rejects non-boolean values" do
      assert_raise ArgumentError, ~r/detector_required/, fn ->
        Declarative.validate_config!(detector_required: :yes)
      end
    end
  end

  describe "storage_inputs" do
    test "defaults to an empty list" do
      assert Declarative.validate_config!([])[:storage_inputs] == []
    end

    test "accepts header and cookie entries" do
      inputs = [{:header, "x-tenant"}, {:cookie, "variant"}]

      assert Declarative.validate_config!(storage_inputs: inputs)[:storage_inputs] == inputs
    end

    test "rejects a malformed entry" do
      assert_raise ArgumentError, ~r/storage_inputs/, fn ->
        Declarative.validate_config!(storage_inputs: [{:header, ""}])
      end
    end
  end
end
