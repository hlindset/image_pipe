defmodule ImagePipe.Dialect.SharedConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.SharedConfig

  test "keys/0 lists exactly the shared runtime keys" do
    assert Enum.sort(SharedConfig.keys()) ==
             Enum.sort([
               :cache,
               :sources,
               :max_body_bytes,
               :max_input_pixels,
               :telemetry_prefix,
               :auto_avif,
               :auto_webp,
               :auto_jpeg_xl,
               :format_order,
               :output_capabilities,
               :max_result_width,
               :max_result_height,
               :max_result_pixels
             ])
  end

  test "validate_runtime!/1 applies defaults" do
    validated = SharedConfig.validate_runtime!([])
    assert validated[:max_body_bytes] == 10_000_000
    assert validated[:max_input_pixels] == 40_000_000
    assert validated[:auto_avif] == true
    assert validated[:max_result_width] == 8_192
    assert validated[:max_result_height] == 8_192
    assert validated[:max_result_pixels] == 40_000_000
  end

  test "validate_runtime!/1 rejects invalid values" do
    assert_raise ArgumentError, ~r/max_body_bytes/, fn ->
      SharedConfig.validate_runtime!(max_body_bytes: -1)
    end
  end

  test "validate_runtime!/1 delegates cache and sources validation" do
    assert_raise ArgumentError, fn ->
      SharedConfig.validate_runtime!(cache: :not_a_cache_config)
    end
  end
end
