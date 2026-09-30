defmodule ImagePipe.Execution.InputsTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Execution.Inputs

  describe "storage_material/2" do
    test "a header contributes its value to storage_only and its name to vary" do
      inputs = Inputs.new!(headers: [{"save-data", "on"}])

      {storage_only, vary} = Inputs.storage_material(inputs, [{:header, "Save-Data"}])

      assert Keyword.fetch!(storage_only, :headers) == [{"save-data", ["on"]}]
      assert Keyword.fetch!(storage_only, :cookies) == []
      assert vary == ["save-data"]
    end

    test "a cookie contributes its value to storage_only and nothing to vary" do
      inputs = Inputs.new!(cookies: %{"session" => "abc"})

      {storage_only, vary} = Inputs.storage_material(inputs, [{:cookie, "session"}])

      assert Keyword.fetch!(storage_only, :cookies) == [{"session", "abc"}]
      assert Keyword.fetch!(storage_only, :headers) == []
      assert vary == []
    end

    test "a missing cookie is omitted from storage_only" do
      inputs = Inputs.new!([])

      {storage_only, _vary} = Inputs.storage_material(inputs, [{:cookie, "session"}])

      assert Keyword.fetch!(storage_only, :cookies) == []
    end

    test "header names are normalized, deduplicated, and deterministically ordered" do
      inputs = Inputs.new!(headers: [{"save-data", "on"}])

      {storage_only_a, vary_a} =
        Inputs.storage_material(inputs, [{:header, "Save-Data"}, {:header, "save-data"}])

      {storage_only_b, vary_b} =
        Inputs.storage_material(inputs, [{:header, "save-data"}, {:header, "SAVE-DATA"}])

      assert vary_a == ["save-data"]
      assert vary_a == vary_b
      assert storage_only_a == storage_only_b
    end

    test "output order does not depend on the configured list's order" do
      inputs = Inputs.new!(headers: [{"save-data", "on"}, {"dpr", "2"}])

      forward = Inputs.storage_material(inputs, [{:header, "save-data"}, {:header, "dpr"}])
      backward = Inputs.storage_material(inputs, [{:header, "dpr"}, {:header, "save-data"}])

      assert forward == backward
    end
  end
end
