defmodule ImagePipe.URLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.{Parser, Path}
  alias ImagePipe.Plan
  alias ImagePipe.Security
  alias ImagePipe.Security.Signature

  @signing_key Base.encode16(:binary.copy(<<31>>, 32))
  @source_key String.duplicate("2a", 32)

  property "root-relative paths have the same plain, signed, and encrypted URLs with a leading slash" do
    check all segments <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 4) do
      source = Enum.join(segments, "/")

      for config <- [IP.URL.config(), IP.URL.config(keys: [@signing_key]), encrypted_config()] do
        builder = IP.URL.new(config)
        assert IP.URL.url!(builder, "/" <> source) == IP.URL.url!(builder, source)
      end
    end
  end

  test "normalizing paths does not reinterpret malformed paths as absolute URLs" do
    for source <- [
          "//photo.jpg",
          "/https://origin.test/photo.jpg",
          "https://origin.test//photo.jpg",
          "s3://bucket//key"
        ] do
      url = IP.URL.url!(IP.URL.new(), source)
      assert {:ok, %{source: {:src, ^source, _}}} = Path.extract(url, "")
    end

    assert IP.URL.url(IP.URL.new(), "/") == {:error, :invalid_source}
  end

  test "encrypted URLs are stable across configurations and processes" do
    plan = IP.URL.new(encrypted_config(), expires: 2_000_000_000) |> IP.URL.group(gray: true)
    source = "https://private.test/bucket/猫.jpg?secret=token"
    expected = IP.URL.url!(plan, source)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        IP.URL.new(encrypted_config(), expires: 2_000_000_000)
        |> IP.URL.group(gray: true)
        |> IP.URL.url!(source)
      end)

    assert Task.await(task) == expected
    refute expected =~ "private.test"

    assert encrypted_token(expected) ==
             encrypted_token(IP.URL.url!(IP.URL.new(encrypted_config()), source))
  end

  test "random and explicit IVs override the generation default and share decoding" do
    source = "private.jpg"
    config = encrypted_config()
    client = IP.URL.new(config)
    first = IP.URL.url!(client, source, iv: :random)
    second = IP.URL.url!(client, source, iv: :random)
    refute first == second
    iv = :binary.copy(<<7>>, 16)
    explicit = IP.URL.url!(client, source, iv: iv)
    assert explicit == IP.URL.url!(client, source, iv: iv)

    assert <<1, ^iv::binary-size(16), _rest::binary>> =
             Base.url_decode64!(encrypted_token(explicit), padding: false)

    for path <- [first, second, explicit] do
      assert decode(path, config) == {:ok, source}
    end

    random_client = IP.URL.new(encrypted_config(iv_mode: :random))
    refute IP.URL.url!(random_client, source) == IP.URL.url!(random_client, source)

    assert IP.URL.url!(random_client, source, iv: :deterministic) == IP.URL.url!(client, source)
  end

  test "encryption configuration and per-call overrides reject mistakes without secrets" do
    for options <- [[iv: <<0::120>>], [iv: <<0::136>>], [iv: nil], [unknown: "private"]] do
      assert IP.URL.url(IP.URL.new(encrypted_config()), "secret-source", options) ==
               {:error, :invalid_encryption_options}
    end

    assert IP.URL.url(IP.URL.new(), "secret-source", iv: :random) ==
             {:error, :source_encryption_disabled}

    for options <- [[iv: nil], [unknown: "private"], [iv: :random, unknown: 1]] do
      assert IP.URL.url(IP.URL.new(), "secret-source", options) ==
               {:error, :invalid_encryption_options}
    end

    assert_raise ArgumentError, fn -> IP.URL.config(encrypt_source: true) end
    assert_raise ArgumentError, fn -> encrypted_config(iv_mode: <<0::128>>) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: []) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: [@source_key]) end
    refute inspect(encrypted_config()) =~ @signing_key
    refute inspect(encrypted_config()) =~ @source_key
  end

  test "plain URLs need no configuration and preserve escaped source bytes" do
    source = "https://origin.test/a b/猫.jpg?token=a+b%2Fc&n=1#frame"
    plan = IP.URL.new() |> IP.URL.group(resize: [width: 40]) |> IP.URL.output(format: :png)
    assert {:ok, path} = IP.URL.url(plan, source)
    assert path == IP.URL.url!(plan, source)
    assert String.starts_with?(path, "/w=40/format=png/src/")
    assert URI.parse(path).query == nil
    assert URI.parse(path).fragment == nil
    assert {:ok, lexed} = Path.extract(path, "")
    assert {:ok, request} = Parser.parse(lexed, presets: %{})
    assert {:ok, ^request} = Plan.to_spec(plan.plan)
  end

  property "built plans and the URLs they serialize to have the same identity" do
    number = StreamData.member_of([0, 0.0, -0.0, 10, 10.0, 12.5])
    angle = StreamData.member_of([0, -0.0, -1.0e-20, -90, 270.0, -360, 359.5, 450, -0.5])

    check all crop <- StreamData.member_of([10, 10.0, 20.5]),
              fx <- StreamData.member_of([0, 0.0, -0.0, 0.25, 1]),
              alpha <- StreamData.member_of([0, -0.0, 0.5, 1]),
              tolerance <- number,
              origin <- number,
              direction <- angle,
              rotate <- angle do
      for group <- [
            [crop: {crop, crop}, focus: {fx, 0.5}],
            [region: {origin, origin, crop, crop}, rotate: rotate],
            [background: {"fff", alpha}, trim: {"red", tolerance}],
            [gradient: [opacity: 1, color: "red", direction: direction]],
            [progressive_blur: [sigma: 4, direction: direction]]
          ] do
        plan = IP.URL.group(IP.URL.new(), group)
        assert {:ok, built} = Plan.to_spec(plan.plan)
        assert {:ok, lexed} = Path.extract(IP.URL.url!(plan, "a.jpg"), "")
        assert {:ok, parsed} = Parser.parse(lexed, presets: %{})
        assert :erlang.term_to_binary(built) == :erlang.term_to_binary(parsed), inspect(group)
      end
    end
  end

  property "random multi-group plans parse back to the spec the builder resolves" do
    check all request <- request_options(),
              groups <- list_of(group_options(), max_length: 3),
              output <- output_options(),
              max_runs: 200 do
      plan =
        groups
        |> Enum.reduce(IP.URL.new(request), &IP.URL.group(&2, &1))
        |> IP.URL.output(output)

      parsed =
        with {:ok, url} <- IP.URL.url(plan, "a.jpg"),
             {:ok, lexed} <- Path.extract(url, ""),
             do: Parser.parse(lexed, presets: %{})

      case {Plan.to_spec(plan.plan), parsed} do
        {{:ok, built}, {:ok, parsed}} ->
          assert :erlang.term_to_binary(built) == :erlang.term_to_binary(parsed),
                 inspect(plan.plan)

        {{:error, _}, {:error, _}} ->
          :ok

        mismatch ->
          flunk("builder and parser disagree: #{inspect(mismatch)} for #{inspect(plan.plan)}")
      end
    end
  end

  test "signatures cover the mount-relative path with stable explicit expiry" do
    for base <- ["", "/images", "images", "https://cdn.test/images/"] do
      config = IP.URL.config(base_url: base, keys: [@signing_key])
      plan = IP.URL.new(config, expires: 2_000_000_000) |> IP.URL.group(gray: true)
      path = IP.URL.url!(plan, "photo.jpg")
      assert path == IP.URL.url!(plan, "photo.jpg")

      prefix = String.trim_trailing(base, "/")
      relative = String.replace_prefix(path, prefix, "")
      {signature, signed_path} = Path.split_signature(relative)
      assert {:ok, 0} = Signature.verify(signature, signed_path, config.options)
      assert signed_path == "/gray/expires=2000000000/src/photo.jpg"
      refute inspect(config) =~ @signing_key
    end
  end

  test "a watermark source loses its optional leading slash, as the main source does" do
    url = &IP.URL.url!(IP.URL.group(IP.URL.new(), watermark_source: &1), "photo.jpg")

    assert url.("/logos/a.png") == url.("logos/a.png")
    refute url.("//host/a.png") == url.("host/a.png")
  end

  test "invalid sources and semantic failures return tagged errors without their content" do
    for source <- ["", "/", "a\0b", <<255>>, {:binary, "private-bytes"}, {:file, "private-path"}] do
      assert IP.URL.url(IP.URL.new(), source) == {:error, :invalid_source}
    end

    known = IP.URL.config(validate_against: [])
    invalid = IP.URL.new(known) |> IP.URL.group(crop: {20, 20}, region: {0, 0, 20, 20})
    assert {:error, {:invalid_request, [_issue]}} = IP.URL.url(invalid, "photo.jpg")
    assert_raise ArgumentError, fn -> IP.URL.url!(invalid, "private-source") end
    assert_raise ArgumentError, fn -> IP.URL.url!(IP.URL.new(), {:binary, "private-source"}) end
  end

  test "url!/3 names the issues without the source or option values" do
    builder = IP.URL.new(filename: "private name") |> IP.URL.group(blur: -1)

    message =
      Exception.message(
        assert_raise(ArgumentError, fn -> IP.URL.url!(builder, "private-source") end)
      )

    assert message =~ "invalid_value"
    assert message =~ ":blur"
    assert message =~ ":filename"
    refute message =~ "private"
    refute message =~ "-1"
  end

  test "base URL and credentials are validated without reflecting secret values" do
    for base <- [
          nil,
          42,
          %{secret: "secret"},
          "https://user:secret@cdn.test/img",
          "//cdn.test/img",
          "/a b",
          "/a/../b",
          "/a//b",
          "https://cdn.test//images",
          "/img?q=secret",
          "/img#fragment",
          "ftp://cdn.test/img"
        ] do
      error = assert_raise ArgumentError, fn -> IP.URL.config(base_url: base) end
      refute Exception.message(error) =~ "secret"
    end

    for keys <- [["secret!"], [""], ["00"], [String.duplicate("ab", 31)]] do
      error = assert_raise ArgumentError, fn -> IP.URL.config(keys: keys) end

      assert Exception.message(error) =~
               "signing keys must be a list of hex strings of at least 64 digits (32 bytes)"

      refute Exception.message(error) =~ "secret!"
    end

    assert %IP.URL.Config{} = IP.URL.config(keys: [String.duplicate("ab", 32)])

    assert_raise ArgumentError, fn -> IP.URL.config(unknown: true) end
  end

  test "option count is limited to paths the HTTP parser accepts" do
    plan = Enum.reduce(1..33, IP.URL.new(), fn _, plan -> IP.URL.group(plan, gray: true) end)
    assert IP.URL.url(plan, "photo.jpg") == {:error, :too_many_options}
  end

  test "dot source identifiers cannot become browser path traversal" do
    for source <- [".", ".."] do
      path = IP.URL.url!(IP.URL.new(), source)
      assert String.starts_with?(path, "/src64/")
      assert {:ok, %{source: {:src64, ^source, _span}}} = Path.extract(path, "")
    end
  end

  property "arbitrary UTF-8 sources round trip without becoming URL syntax" do
    check all source <- string(:utf8, min_length: 1, max_length: 100) do
      source = "asset-" <> source
      path = IP.URL.url!(IP.URL.new(), source)

      assert {:ok, %{source: {_marker, ^source, _span}}} =
               Path.extract(path, "")
    end
  end

  property "UTF-8 encrypted sources round trip across CBC block boundaries" do
    config = encrypted_config()

    check all source <- string(:utf8, min_length: 1, max_length: 100),
              iv <- binary(length: 16) do
      source = "asset-" <> source
      path = IP.URL.url!(IP.URL.new(config), source, iv: iv)

      assert decode(path, config) == {:ok, source}
    end
  end

  defp encrypted_config(options \\ []) do
    [keys: [@signing_key], source_encryption_keys: [@source_key], encrypt_source: true]
    |> Keyword.merge(options)
    |> IP.URL.config()
  end

  # Verifies and decrypts a generated path the way the serving mount does.
  defp decode(path, config) do
    {signature, signed_path} = Path.split_signature(path)
    {:ok, _key_index} = Signature.verify(signature, signed_path, config.options)
    {:ok, %{source: {:enc, token, _span}}} = Path.extract(path, "")
    Security.decrypt_source(token, config.options)
  end

  defp encrypted_token(path), do: path |> String.split("/enc/") |> List.last()

  defp request_options do
    one_of([
      constant([]),
      gen all orient <- member_of([:auto, :none]),
              page <- integer(0..3),
              attachment <- boolean(),
              cachebuster <- string(:alphanumeric, min_length: 1, max_length: 4) do
        [orient: orient, page: page, attachment: attachment, cachebuster: cachebuster]
      end
    ])
  end

  # Each group draws a few option families; families may conflict or be
  # inert together, which the property checks the parser reports alike.
  defp group_options do
    [
      gen all width <- integer(1..4000),
              height <- integer(1..4000),
              fit <- member_of([:cover, :contain, :stretch, :auto]),
              enlarge <- boolean() do
        [resize: [width: width, height: height, fit: fit, enlarge: enlarge]]
      end,
      gen all width <- integer(1..400),
              height <- one_of([integer(1..400), map(integer(1..100), &{:pct, &1})]),
              anchor <- member_of([:center, :top_left, :bottom_right, :smart, :smart_face]) do
        [crop: {width, height}, anchor: anchor]
      end,
      map(member_of([0, 90, -90, 180, 270.0, 45.5, -0.0]), &[rotate: &1]),
      map(member_of([:horizontal, :vertical, :both]), &[flip: &1]),
      map(float(min: 0.0, max: 50.0), &[blur: &1]),
      map(integer(1..10), &[sharpen: &1]),
      map(integer(1..50), &[pixelate: &1]),
      map(integer(-255..255), &[brightness: &1]),
      map(float(min: 0.1, max: 4.0), &[contrast: &1, saturation: &1]),
      map(float(min: 0.1, max: 8.0), &[dpr: &1]),
      constant(gray: true),
      gen all padding <- list_of(integer(0..100), length: 4),
              alpha <- float(min: 0.0, max: 1.0) do
        [padding: List.to_tuple(padding), background: {"white", alpha}]
      end,
      map(integer(0..100), &[trim: {"red", &1}]),
      gen all opacity <- float(min: 0.0, max: 1.0),
              direction <- float(min: -360.0, max: 360.0) do
        [
          colorize: [opacity: opacity, color: "green"],
          gradient: [opacity: opacity, color: "black", direction: direction]
        ]
      end
    ]
    |> member_of()
    |> bind(& &1)
    |> list_of(min_length: 1, max_length: 4)
    |> map(&(&1 |> List.flatten() |> Enum.uniq_by(fn {key, _value} -> key end)))
  end

  defp output_options do
    fixed_list([
      member_of([[], [format: :webp], [format: :avif], [format: :jpeg], [format: :png]]),
      one_of([constant([]), map(integer(1..100), &[quality: &1])]),
      one_of([constant([]), map(integer(1..100), &[autoquality: &1])]),
      one_of([constant([]), map(member_of([:strip, :copyright, :keep]), &[metadata: &1])])
    ])
    |> map(&List.flatten/1)
  end

  describe "validate_against" do
    test "without it the builder checks values only" do
      plan = IP.URL.new() |> IP.URL.group(resize: [fit: :cover])
      assert IP.URL.validate(plan) == {:ok, []}
      assert {:ok, "/fit=cover/src/photo.jpg"} = IP.URL.url(plan, "photo.jpg")
    end

    test "known request defaults and presets take part in the check" do
      config =
        IP.URL.config(
          validate_against: [presets: %{"cover" => "fit=cover"}, request_defaults: "w=400"]
        )

      assert {:ok, []} =
               IP.URL.validate(IP.URL.new(config) |> IP.URL.group(resize: [fit: :cover]))

      assert {:ok, []} = IP.URL.validate(IP.URL.new(config) |> IP.URL.group(presets: ["cover"]))

      bare = IP.URL.config(validate_against: [presets: %{"cover" => "fit=cover"}])

      assert {:ok, [_ | _]} =
               IP.URL.validate(IP.URL.new(bare) |> IP.URL.group(resize: [fit: :cover]))
    end

    test "a name the known presets lack is unknown unless the server has a lookup" do
      static = IP.URL.config(validate_against: [presets: %{"card" => "w=30"}])

      lookup =
        IP.URL.config(validate_against: [presets: %{"card" => "w=30"}, preset_lookup: true])

      assert {:error, [%{reason: :unknown_preset}]} =
               IP.URL.validate(IP.URL.new(static) |> IP.URL.group(presets: ["remote"]))

      assert {:error, {:invalid_request, _issues}} =
               IP.URL.url(IP.URL.new(static) |> IP.URL.group(presets: ["remote"]), "photo.jpg")

      assert {:ok, []} = IP.URL.validate(IP.URL.new(lookup) |> IP.URL.group(presets: ["remote"]))

      assert {:ok, _url} =
               IP.URL.url(IP.URL.new(lookup) |> IP.URL.group(presets: ["remote"]), "photo.jpg")
    end

    test "under a lookup, groups without an unknown preset are still checked" do
      lookup =
        IP.URL.config(validate_against: [presets: %{"card" => "w=30"}, preset_lookup: true])

      bad =
        IP.URL.new(lookup)
        |> IP.URL.group(presets: ["remote"])
        |> IP.URL.group(resize: [fit: :cover])

      assert {:ok, [%{reason: :inert_option, locations: [{:group, 1, :fit}]}]} =
               IP.URL.validate(bad)

      assert {:ok, _url} = IP.URL.url(bad, "photo.jpg")

      # With every named preset known, request-wide options are checked too.
      assert {:ok, [%{locations: [{:request, :jpeg_options}]}]} =
               IP.URL.new(lookup)
               |> IP.URL.group(presets: ["card"])
               |> IP.URL.output(format: :webp, jpeg_options: [interlace: true])
               |> IP.URL.validate()

      # Validation drops inert options as serving does, so dependents cascade.
      assert {:ok, warnings} =
               IP.URL.new(lookup)
               |> IP.URL.group(presets: ["remote"])
               |> IP.URL.group(crop_ratio: {3, 2}, crop_ratio_enlarge: true)
               |> IP.URL.validate()

      assert warnings |> Enum.flat_map(& &1.locations) |> Enum.sort() ==
               [{:group, 1, :crop_ratio}, {:group, 1, :crop_ratio_enlarge}]

      # The unknown preset may supply the width that `fit` needs.
      assert {:ok, []} =
               IP.URL.validate(
                 IP.URL.new(lookup)
                 |> IP.URL.group(presets: ["remote"], resize: [fit: :cover])
               )
    end

    test "under a lookup, conflicts between options the plan sets are still checked" do
      lookup =
        IP.URL.config(validate_against: [presets: %{"a" => "blur=1"}, preset_lookup: true])

      assert {:error, [%{reason: :mutually_exclusive_options} = request]} =
               IP.URL.new(lookup)
               |> IP.URL.group(presets: ["unknown"])
               |> IP.URL.output(quality: 80, autoquality: true)
               |> IP.URL.validate()

      assert Enum.sort(request.locations) == [{:request, :autoquality}, {:request, :quality}]

      assert {:error, [%{reason: :mutually_exclusive_options}]} =
               IP.URL.new(lookup)
               |> IP.URL.group(presets: ["a"])
               |> IP.URL.output(quality: 80, autoquality: true)
               |> IP.URL.validate()

      group =
        IP.URL.new(lookup)
        |> IP.URL.group(resize: [width: 10])
        |> IP.URL.group(presets: ["unknown"], anchor: :top, detect: ["face"], crop: {10, 10})

      assert {:error, [%{reason: :mutually_exclusive_options} = conflict]} =
               IP.URL.validate(group)

      assert Enum.sort(conflict.locations) == [{:group, 1, :anchor}, {:group, 1, :detect}]
      assert {:error, {:invalid_request, _issues}} = IP.URL.url(group, "photo.jpg")
    end

    test "issues name the builder's own groups when an unset-only group drops out" do
      static = IP.URL.config(validate_against: [presets: %{}])
      lookup = IP.URL.config(validate_against: [presets: %{}, preset_lookup: true])

      plan = fn config ->
        IP.URL.new(config)
        |> IP.URL.group(watermark: :unset)
        |> IP.URL.group(resize: [fit: :cover])
      end

      # Under a lookup, a group naming an unknown preset takes the other check.
      for plan <- [plan.(static), plan.(lookup), IP.URL.group(plan.(lookup), presets: ["remote"])] do
        assert {:ok, [%{reason: :inert_option, locations: [{:group, 1, :fit}]}]} =
                 IP.URL.validate(plan)
      end

      watermark = IP.URL.config(validate_against: [watermarks: [:logo]])

      assert {:error, [%{reason: :unknown_watermark, locations: [{:group, 1, :watermark}]}]} =
               IP.URL.new(watermark)
               |> IP.URL.group(watermark: :unset)
               |> IP.URL.group(watermark: :other)
               |> IP.URL.validate()
    end

    test "watermark names are checked when validate_against lists them" do
      named = IP.URL.config(validate_against: [watermarks: [:logo]])
      unnamed = IP.URL.config(validate_against: [])

      assert {:ok, []} = IP.URL.new(named) |> IP.URL.group(watermark: :logo) |> IP.URL.validate()

      other = &(IP.URL.new(&1) |> IP.URL.group(watermark: :other))

      assert {:error, [%{reason: :unknown_watermark, locations: [{:group, 0, :watermark}]}]} =
               IP.URL.validate(other.(named))

      assert {:error, {:invalid_request, [%{reason: :unknown_watermark}]}} =
               IP.URL.url(other.(named), "photo.jpg")

      assert {:ok, []} = IP.URL.validate(other.(unnamed))

      assert {:ok, []} =
               IP.URL.new(named)
               |> IP.URL.group(watermark_source: "brand/mark.png")
               |> IP.URL.validate()
    end

    test "watermark sources are checked when validate_against says whether requests may name them" do
      plan = &(IP.URL.new(&1) |> IP.URL.group(watermark_source: "brand/mark.png"))

      for options <- [
            [request_watermarks: false],
            [request_watermarks: false, watermarks: [:logo]]
          ] do
        assert {:error, [%{reason: :watermark_source_disabled}]} =
                 IP.URL.validate(plan.(IP.URL.config(validate_against: options)))
      end

      assert {:ok, []} =
               IP.URL.validate(plan.(IP.URL.config(validate_against: [request_watermarks: true])))

      assert {:ok, []} =
               IP.URL.new(IP.URL.config(validate_against: [request_watermarks: false]))
               |> IP.URL.group(watermark: :anything)
               |> IP.URL.validate()
    end

    test "a preset with a group holding only unsets is a pipeline preset" do
      config = IP.URL.config(validate_against: [presets: %{"p" => "blur=unset/-/w=100"}])

      assert {:error, [%{reason: :pipeline_preset_with_group_options}]} =
               IP.URL.new(config)
               |> IP.URL.group(presets: ["p"], blur: 1)
               |> IP.URL.validate()
    end

    test "builder values match their fragment spelling" do
      card = IP.URL.new() |> IP.URL.group(resize: [width: 30, height: 20, fit: :cover])
      as_builder = IP.URL.config(validate_against: [presets: %{"card" => card}])
      as_string = IP.URL.config(validate_against: [presets: %{"card" => "w=30/h=20/fit=cover"}])

      assert as_builder.options[:validate_against] == as_string.options[:validate_against]
    end

    test "request defaults with groups or presets, and unknown references, fail at init" do
      for options <- [
            [request_defaults: "w=10/-/blur=1"],
            [request_defaults: "preset=card", presets: %{"card" => "w=10"}],
            [presets: %{"card" => "preset=missing"}],
            [presets: %{"card" => "w=nope"}],
            [presets: %{"card" => IP.URL.new() |> IP.URL.group(blur: -1)}],
            [request_defaults: IP.URL.new() |> IP.URL.output(quality: 101)]
          ] do
        assert_raise ArgumentError, ~r/validate_against/, fn ->
          IP.URL.config(validate_against: options)
        end
      end
    end

    test "presets and request defaults whose own options conflict fail at init" do
      for fragment <- [
            "anchor=top/detect=face",
            "q=80/autoquality=50",
            "w=10/h=10/extend/extend-ratio",
            "crop=10,10/region=0,0,5,5",
            "anchor=top/focus=0.5,0.5"
          ],
          options <- [[presets: %{"card" => fragment}], [request_defaults: fragment]] do
        assert_raise ArgumentError, ~r/mutually_exclusive_options/, fn ->
          IP.URL.config(validate_against: options)
        end
      end

      for options <- [
            [presets: %{"card" => "wm=other"}, watermarks: [:logo]],
            [request_defaults: "wm=other", watermarks: [:logo]],
            [
              presets: %{"card" => "wm-src64=#{Base.url_encode64("logo.png", padding: false)}"},
              request_watermarks: false
            ]
          ] do
        assert_raise ArgumentError, ~r/validate_against.*watermark/, fn ->
          IP.URL.config(validate_against: options)
        end
      end
    end

    test "presets may set options that do nothing on their own or that a later layer replaces" do
      config =
        IP.URL.config(
          validate_against: [
            request_defaults: "anchor=top/fit=cover",
            presets: %{
              "partial" => "w=auto/fit=cover/anchor=left",
              "top" => "anchor=top",
              "faces" => "preset=top/detect=face",
              "branded" => "wm=logo"
            }
          ]
        )

      assert {:ok, _warnings} =
               IP.URL.new(config)
               |> IP.URL.group(presets: ["partial", "faces"], resize: [height: 10])
               |> IP.URL.validate()
    end

    test "unset options are written as key=unset and clear presets" do
      config =
        IP.URL.config(
          validate_against: [
            request_defaults: "jpeg-options=progressive/format=webp",
            presets: %{"brand" => "w=300/h=200/fit=cover/wm=logo"}
          ]
        )

      builder =
        IP.URL.new(config, filename: :unset)
        |> IP.URL.group(presets: ["brand"], resize: [width: :unset], watermark: :unset)
        |> IP.URL.output(jpeg_options: :unset, format: :unset)

      assert {:ok, []} = IP.URL.validate(builder)

      assert IP.URL.url(builder, "photo.jpg") ==
               {:ok,
                "/preset=brand/w=unset/wm=unset/format=unset/jpeg-options=unset/filename=unset/src/photo.jpg"}
    end

    test "a leading :unset resets encoder options and format qualities before setting them" do
      builder =
        IP.URL.new()
        |> IP.URL.group(resize: [width: 800])
        |> IP.URL.output(
          jpeg_options: [:unset, interlace: true],
          format_qualities: [:unset, avif: 50]
        )

      assert IP.URL.url(builder, "photo.jpg") ==
               {:ok, "/w=800/format-q=unset,avif:50/jpeg-options=unset,progressive/src/photo.jpg"}
    end

    test "empty encoder options and format qualities are rejected" do
      for options <- [[jpeg_options: []], [format_qualities: []]] do
        builder = IP.URL.new() |> IP.URL.output(options)
        assert {:error, [%{reason: :invalid_value, detail: detail}]} = IP.URL.validate(builder)
        assert detail =~ ":unset"
      end
    end
  end
end
