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
               :max_result_pixels,
               :allow_origin,
               :allow_debug_headers
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

    assert_raise ArgumentError, fn ->
      SharedConfig.validate_runtime!(
        sources: [path: {ImagePipe.SourceTest.CustomAdapter, :not_options}]
      )
    end
  end

  describe "request safety limits" do
    test "accept explicit valid overrides" do
      validated =
        SharedConfig.validate_runtime!(
          max_body_bytes: 123,
          max_input_pixels: 456,
          max_result_width: 78,
          max_result_height: 90,
          max_result_pixels: 1_234
        )

      assert validated[:max_body_bytes] == 123
      assert validated[:max_input_pixels] == 456
      assert validated[:max_result_width] == 78
      assert validated[:max_result_height] == 90
      assert validated[:max_result_pixels] == 1_234
    end

    test "reject malformed values" do
      for {key, value} <- [
            max_body_bytes: 0,
            max_input_pixels: 0,
            max_result_width: 0,
            max_result_height: -1,
            max_result_pixels: "40MP"
          ] do
        assert_raise ArgumentError, ~r/invalid ImagePipe shared runtime options/, fn ->
          SharedConfig.validate_runtime!([{key, value}])
        end
      end
    end
  end

  describe "auto format options" do
    test "default to true" do
      validated = SharedConfig.validate_runtime!([])

      assert validated[:auto_avif] == true
      assert validated[:auto_webp] == true
      assert validated[:auto_jpeg_xl] == true
    end

    test "accept explicit booleans" do
      validated =
        SharedConfig.validate_runtime!(auto_avif: false, auto_webp: false, auto_jpeg_xl: false)

      assert validated[:auto_avif] == false
      assert validated[:auto_webp] == false
      assert validated[:auto_jpeg_xl] == false
    end

    test "reject non-boolean values" do
      for key <- [:auto_avif, :auto_webp, :auto_jpeg_xl] do
        assert_raise ArgumentError, ~r/invalid ImagePipe shared runtime options/, fn ->
          SharedConfig.validate_runtime!([{key, "yes"}])
        end
      end
    end
  end

  describe "format_order" do
    test "is absent by default (negotiation supplies the default order)" do
      refute Keyword.has_key?(SharedConfig.validate_runtime!([]), :format_order)
    end

    test "accepts a list of distinct modern formats" do
      assert SharedConfig.validate_runtime!(format_order: [:jpeg_xl, :avif, :webp])[:format_order] ==
               [:jpeg_xl, :avif, :webp]
    end

    test "accepts a partial list" do
      assert SharedConfig.validate_runtime!(format_order: [:jpeg_xl])[:format_order] == [:jpeg_xl]
    end

    test "rejects unknown formats, duplicates, and an empty list" do
      for order <- [[:avif, :jpeg], [:avif, :avif], []] do
        assert_raise ArgumentError, ~r/format_order/, fn ->
          SharedConfig.validate_runtime!(format_order: order)
        end
      end
    end
  end

  test "allow_origin is absent by default (CORS off)" do
    validated = SharedConfig.validate_runtime!([])
    refute Keyword.has_key?(validated, :allow_origin)
  end

  test "allow_origin accepts a non-empty string" do
    validated = SharedConfig.validate_runtime!(allow_origin: "*")
    assert Keyword.fetch!(validated, :allow_origin) == "*"
  end

  test "allow_origin rejects an empty string" do
    assert_raise ArgumentError, ~r/allow_origin/, fn ->
      SharedConfig.validate_runtime!(allow_origin: "")
    end
  end

  test "allow_origin rejects control characters (fails at init, not per-request)" do
    assert_raise ArgumentError, ~r/allow_origin/, fn ->
      SharedConfig.validate_runtime!(allow_origin: "*\r\nSet-Cookie: x=1")
    end
  end

  test "allow_debug_headers defaults to false and validates as a boolean" do
    assert SharedConfig.validate_runtime!([])[:allow_debug_headers] == false
    assert SharedConfig.validate_runtime!(allow_debug_headers: true)[:allow_debug_headers] == true

    assert_raise ArgumentError, ~r/invalid ImagePipe shared runtime options/, fn ->
      SharedConfig.validate_runtime!(allow_debug_headers: "yes")
    end
  end
end
