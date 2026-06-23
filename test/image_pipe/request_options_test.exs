defmodule ImagePipe.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Request.Options
  alias ImagePipe.SourceTest.CustomAdapter

  @base_opts [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {CustomAdapter, adapter: :path}
    ]
  ]

  test "validate! accepts clock as a zero-arity function" do
    clock = fn -> DateTime.utc_now() end

    assert Options.validate!(Keyword.put(@base_opts, :clock, clock))[:clock] == clock
  end

  test "http_cache defaults to disabled" do
    opts = Options.validate!(@base_opts)

    assert Keyword.fetch!(opts, :http_cache) == [mode: :disabled]
  end

  test "http_cache accepts enabled mode" do
    opts = Options.validate!(Keyword.put(@base_opts, :http_cache, mode: :enabled))

    assert Keyword.fetch!(opts, :http_cache) == [mode: :enabled]
  end

  test "http_cache rejects unknown mode" do
    assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
      Options.validate!(Keyword.put(@base_opts, :http_cache, mode: :public))
    end
  end

  test "validate! rejects a near-miss typo of a validated option" do
    assert_raise ArgumentError, ~r/did you mean :max_input_pixels/, fn ->
      Options.validate!(Keyword.put(@base_opts, :max_input_pixles, 100))
    end
  end

  test "validate! rejects a near-miss typo of a source-runtime option" do
    assert_raise ArgumentError, ~r/did you mean :receive_timeout/, fn ->
      Options.validate!(Keyword.put(@base_opts, :recieve_timeout, 1_000))
    end
  end

  test "validate! rejects a near-miss typo of a modern-format option" do
    assert_raise ArgumentError, ~r/did you mean :auto_webp/, fn ->
      Options.validate!(Keyword.put(@base_opts, :auto_webpp, false))
    end
  end

  test "validate! ignores an unknown option that is not close to any known option" do
    # Parser config namespaces and DI/runtime seams are far from every known
    # key, so they pass through untouched (preserving today's behavior).
    opts =
      Options.validate!(Keyword.merge(@base_opts, imgproxy: [], image_open_module: __MODULE__))

    assert Keyword.fetch!(opts, :imgproxy) == []
    assert Keyword.fetch!(opts, :image_open_module) == __MODULE__
  end

  test "request safety limits have defaults" do
    opts = Options.validate!(@base_opts)

    assert Keyword.fetch!(opts, :max_body_bytes) == 10_000_000
    assert Keyword.fetch!(opts, :max_input_pixels) == 40_000_000
    assert Keyword.fetch!(opts, :max_result_width) == 8_192
    assert Keyword.fetch!(opts, :max_result_height) == 8_192
    assert Keyword.fetch!(opts, :max_result_pixels) == 40_000_000
  end

  test "request safety limits accept explicit valid overrides" do
    opts =
      Options.validate!(
        Keyword.merge(@base_opts,
          max_body_bytes: 123,
          max_input_pixels: 456,
          max_result_width: 78,
          max_result_height: 90,
          max_result_pixels: 1_234
        )
      )

    assert Keyword.fetch!(opts, :max_body_bytes) == 123
    assert Keyword.fetch!(opts, :max_input_pixels) == 456
    assert Keyword.fetch!(opts, :max_result_width) == 78
    assert Keyword.fetch!(opts, :max_result_height) == 90
    assert Keyword.fetch!(opts, :max_result_pixels) == 1_234
  end

  test "request safety limits reject malformed values" do
    for {key, value} <- [
          max_body_bytes: 0,
          max_input_pixels: 0,
          max_result_width: 0,
          max_result_height: -1,
          max_result_pixels: "40MP"
        ] do
      assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
        Options.validate!(Keyword.put(@base_opts, key, value))
      end
    end
  end

  test "validate! rejects malformed clock values before call opts are used" do
    for clock <- [:bad, ~U[2026-05-05 12:00:00Z], 100, fn value -> value end] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePipe options: invalid value for :clock option/,
                   fn ->
                     Options.validate!(Keyword.put(@base_opts, :clock, clock))
                   end
    end
  end

  test "detector options default to :default and false" do
    opts = Options.validate!(@base_opts)

    assert Keyword.fetch!(opts, :detector) == :default
    assert Keyword.fetch!(opts, :detector_required) == false
  end

  test "detector options accept a host module and detector_required: true" do
    opts =
      Options.validate!(
        Keyword.merge(@base_opts, detector: CustomAdapter, detector_required: true)
      )

    assert Keyword.fetch!(opts, :detector) == CustomAdapter
    assert Keyword.fetch!(opts, :detector_required) == true
  end

  test "detector accepts nil to disable detection" do
    opts = Options.validate!(Keyword.put(@base_opts, :detector, nil))

    assert Keyword.fetch!(opts, :detector) == nil
  end

  test "detector_required rejects non-boolean values" do
    assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
      Options.validate!(Keyword.put(@base_opts, :detector_required, :yes))
    end
  end

  test "auto format options default to true" do
    opts = Options.validate!(@base_opts)

    assert Keyword.fetch!(opts, :auto_avif) == true
    assert Keyword.fetch!(opts, :auto_webp) == true
    assert Keyword.fetch!(opts, :auto_jpeg_xl) == true
  end

  test "auto format options accept explicit booleans" do
    opts =
      Options.validate!(
        Keyword.merge(@base_opts, auto_avif: false, auto_webp: false, auto_jpeg_xl: false)
      )

    assert Keyword.fetch!(opts, :auto_avif) == false
    assert Keyword.fetch!(opts, :auto_webp) == false
    assert Keyword.fetch!(opts, :auto_jpeg_xl) == false
  end

  test "auto format options reject non-boolean values" do
    for key <- [:auto_avif, :auto_webp, :auto_jpeg_xl] do
      assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
        Options.validate!(Keyword.put(@base_opts, key, "yes"))
      end
    end
  end

  test "request options accept sources without root_url" do
    assert opts =
             Options.validate!(
               parser: ImagePipe.Parser.Imgproxy,
               sources: [
                 path: {CustomAdapter, adapter: :path}
               ]
             )

    assert opts[:sources][:path]
    refute Keyword.has_key?(opts, :root_url)
  end

  test "request options reject invalid source adapter config during init" do
    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {CustomAdapter, :not_options}]
      )
    end
  end

  test "request options reject stale origin configuration after source integration" do
    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {CustomAdapter, adapter: :path}],
        root_url: "https://origin.example"
      )
    end

    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {CustomAdapter, adapter: :path}],
        origin_req_options: [plug: OriginImage]
      )
    end
  end
end
