defmodule ImagePipe.Dialect.TwicPics.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.CustomAdapter

  test "applies dialect, neutral, and shared defaults with no opts" do
    validated = Config.validate!([])

    assert validated[:storage_inputs] == []
    assert validated[:detector] == :default
    assert validated[:detector_required] == false
    assert validated[:allow_debug_headers] == false
    assert validated[:quality] == 80
    assert validated[:max_body_bytes] == 10_000_000
  end

  test "init delegates the flat option list to Config" do
    opts = [quality: 42, allow_debug_headers: true]

    assert TwicPics.init(opts) == Config.validate!(opts)
  end

  test "a neutral quality override resolves through ImagePipe.Config" do
    assert Config.validate!(quality: 42)[:quality] == 42
  end

  test "accepts every shared runtime key through SharedConfig" do
    validated =
      Config.validate!(
        cache: {CacheProbe, []},
        sources: [path: {CustomAdapter, adapter: :path}],
        max_body_bytes: 123,
        max_input_pixels: 456,
        telemetry_prefix: [:image_pipe, :twic_pics_test],
        auto_avif: false,
        auto_webp: false,
        auto_jpeg_xl: false,
        format_order: [:webp, :avif],
        output_capabilities: %{avif: false},
        max_result_width: 789,
        max_result_height: 654,
        max_result_pixels: 123_456,
        allow_origin: "https://images.example"
      )

    assert validated[:cache] == {CacheProbe, []}
    assert validated[:sources] == %{path: {CustomAdapter, [adapter: :path, validated: true]}}
    assert validated[:max_body_bytes] == 123
    assert validated[:max_input_pixels] == 456
    assert validated[:telemetry_prefix] == [:image_pipe, :twic_pics_test]
    assert validated[:auto_avif] == false
    assert validated[:auto_webp] == false
    assert validated[:auto_jpeg_xl] == false
    assert validated[:format_order] == [:webp, :avif]
    assert validated[:output_capabilities] == %{avif: false}
    assert validated[:max_result_width] == 789
    assert validated[:max_result_height] == 654
    assert validated[:max_result_pixels] == 123_456
    assert validated[:allow_origin] == "https://images.example"
  end

  test "accepts all four dialect keys" do
    validated =
      Config.validate!(
        storage_inputs: [{:header, "X-Tenant"}, {:cookie, "session"}],
        detector: __MODULE__,
        detector_required: true,
        allow_debug_headers: true
      )

    assert validated[:storage_inputs] == [{:header, "X-Tenant"}, {:cookie, "session"}]
    assert validated[:detector] == __MODULE__
    assert validated[:detector_required] == true
    assert validated[:allow_debug_headers] == true
  end

  test "storage_inputs rejects malformed lists and entries" do
    for storage_inputs <- [:not_a_list, [{:query, "tenant"}], [{:header, ""}]] do
      assert_raise ArgumentError, ~r/invalid ImagePipe.Dialect.TwicPics options/, fn ->
        Config.validate!(storage_inputs: storage_inputs)
      end
    end
  end

  test "detector and debug options reject malformed values" do
    for {key, value} <- [
          detector: 123,
          detector_required: :yes,
          allow_debug_headers: "yes"
        ] do
      assert_raise ArgumentError, ~r/invalid ImagePipe.Dialect.TwicPics options/, fn ->
        Config.validate!([{key, value}])
      end
    end
  end

  test "rejects unknown top-level options" do
    assert_raise ArgumentError, ~r/unknown ImagePipe.Dialect.TwicPics option/, fn ->
      Config.validate!(bogus_option: true)
    end
  end

  test "rejects the legacy nested twicpics config" do
    assert_raise ArgumentError, ~r/unknown ImagePipe.Dialect.TwicPics option/, fn ->
      Config.validate!(twicpics: [quality: 42])
    end
  end
end
