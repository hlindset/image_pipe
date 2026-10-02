defmodule ImagePipe.URLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.{Parser, Path}
  alias ImagePipe.Plan
  alias ImagePipe.Security
  alias ImagePipe.Security.Signature

  @signing_key Base.encode16(:binary.copy(<<31>>, 32))
  @source_key :binary.copy(<<42>>, 32)

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

    assert_raise ArgumentError, fn -> IP.URL.config(encrypt_source: true) end
    assert_raise ArgumentError, fn -> encrypted_config(iv_mode: <<0::128>>) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: []) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: [Base.encode16(@source_key)]) end
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

    known = IP.URL.config(mount_presets: [])
    invalid = IP.URL.new(known) |> IP.URL.group(extend: true)
    assert {:error, {:invalid_request, [_issue]}} = IP.URL.url(invalid, "photo.jpg")
    assert_raise ArgumentError, fn -> IP.URL.url!(invalid, "private-source") end
    assert_raise ArgumentError, fn -> IP.URL.url!(IP.URL.new(), {:binary, "private-source"}) end
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

    error = assert_raise ArgumentError, fn -> IP.URL.config(keys: ["secret!"]) end
    refute Exception.message(error) =~ "secret!"
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

  describe "mount_presets" do
    test "without it the builder checks values only" do
      plan = IP.URL.new() |> IP.URL.group(resize: [fit: :cover])
      assert IP.URL.validate(plan) == :ok
      assert {:ok, "/fit=cover/src/photo.jpg"} = IP.URL.url(plan, "photo.jpg")
    end

    test "known request defaults and presets take part in the check" do
      config =
        IP.URL.config(
          mount_presets: [presets: %{"cover" => "fit=cover"}, request_defaults: "w=400"]
        )

      assert :ok = IP.URL.validate(IP.URL.new(config) |> IP.URL.group(resize: [fit: :cover]))
      assert :ok = IP.URL.validate(IP.URL.new(config) |> IP.URL.group(presets: ["cover"]))

      bare = IP.URL.config(mount_presets: [presets: %{"cover" => "fit=cover"}])

      assert {:error, [_ | _]} =
               IP.URL.validate(IP.URL.new(bare) |> IP.URL.group(presets: ["cover"]))
    end

    test "a name the known presets lack is unknown unless the mount has a lookup" do
      static = IP.URL.config(mount_presets: [presets: %{"card" => "w=30"}])
      lookup = IP.URL.config(mount_presets: [presets: %{"card" => "w=30"}, preset_lookup: true])

      assert {:error, [%{reason: :unknown_preset}]} =
               IP.URL.validate(IP.URL.new(static) |> IP.URL.group(presets: ["remote"]))

      assert {:error, {:invalid_request, _issues}} =
               IP.URL.url(IP.URL.new(static) |> IP.URL.group(presets: ["remote"]), "photo.jpg")

      assert :ok = IP.URL.validate(IP.URL.new(lookup) |> IP.URL.group(presets: ["remote"]))

      assert {:ok, _url} =
               IP.URL.url(IP.URL.new(lookup) |> IP.URL.group(presets: ["remote"]), "photo.jpg")
    end

    test "builder values match their fragment spelling" do
      card = IP.URL.new() |> IP.URL.group(resize: [width: 30, height: 20, fit: :cover])
      as_builder = IP.URL.config(mount_presets: [presets: %{"card" => card}])
      as_string = IP.URL.config(mount_presets: [presets: %{"card" => "w=30/h=20/fit=cover"}])

      assert as_builder.options[:mount_presets] == as_string.options[:mount_presets]
    end

    test "request defaults with groups or presets, and unknown references, fail at init" do
      for options <- [
            [request_defaults: "w=10/-/blur=1"],
            [request_defaults: "preset=card", presets: %{"card" => "w=10"}],
            [presets: %{"card" => "preset=missing"}],
            [presets: %{"card" => "w=nope"}]
          ] do
        assert_raise ArgumentError, ~r/mount_presets/, fn ->
          IP.URL.config(mount_presets: options)
        end
      end
    end

    test "an empty override cannot clear known request defaults" do
      config = IP.URL.config(mount_presets: [request_defaults: "jpeg-options=progressive"])
      builder = IP.URL.new(config) |> IP.URL.output(jpeg_options: [])

      assert IP.URL.url(builder, "photo.jpg") == {:error, :unrepresentable_preset_override}
    end
  end
end
