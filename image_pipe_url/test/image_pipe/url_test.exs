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

  test "invalid sources and semantic failures return tagged errors without their content" do
    for source <- ["", <<255>>, {:binary, "private-bytes"}, {:file, "private-path"}] do
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

    for keys <- [["secret!"], [""]] do
      error = assert_raise ArgumentError, fn -> IP.URL.config(keys: keys) end
      assert Exception.message(error) =~ "signing keys must be a list of non-empty hex strings"
      refute Exception.message(error) =~ "secret!"
    end

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
