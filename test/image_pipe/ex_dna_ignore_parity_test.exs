defmodule ImagePipe.ExDnaConfigTest do
  use ExUnit.Case, async: true

  test "the authoritative ExDNA options stay narrow" do
    options = ImagePipe.MixProject.ex_dna_options()

    assert options[:excluded_macros] == [:alias]
    assert options[:ignore] == []
  end
end
