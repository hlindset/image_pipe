defmodule ImagePipe.ExDnaConfigTest do
  use ExUnit.Case, async: true

  test "the authoritative ExDNA options stay narrow and duplicate-free" do
    options = ImagePipe.MixProject.ex_dna_options()

    assert options[:excluded_macros] == [:alias]

    assert options[:ignore] == [
             "lib/image_pipe/decode.ex",
             "lib/image_pipe/decode/source_format.ex",
             "lib/image_pipe/dialect/shared_config.ex",
             "lib/image_pipe/plug/debug_builder.ex",
             "lib/image_pipe/response/cache_policy.ex",
             "lib/image_pipe/response/conditional.ex"
           ]

    assert Enum.uniq(options[:ignore]) == options[:ignore]
  end
end
