defmodule ImagePipe.URLTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.{Parser, Path, Signature}
  alias ImagePipe.Plan

  @signing_key Base.encode16(:binary.copy(<<31>>, 32))
  @source_key :binary.copy(<<42>>, 32)

  test "encrypted URLs are stable across configurations and processes" do
    plan = IP.new(expires: 2_000_000_000) |> IP.group(gray: true)
    source = "https://private.test/bucket/猫.jpg?secret=token"
    expected = IP.url!(plan, source, encrypted_config())
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        IP.url!(plan, source, encrypted_config())
      end)

    assert Task.await(task) == expected
    refute expected =~ "private.test"

    assert encrypted_token(expected) ==
             encrypted_token(IP.url!(IP.new(), source, encrypted_config()))
  end

  test "random and explicit IVs override the generation default and share decoding" do
    source = "private.jpg"
    config = encrypted_config()
    first = IP.url!(IP.new(), source, config, iv: :random)
    second = IP.url!(IP.new(), source, config, iv: :random)
    refute first == second
    iv = :binary.copy(<<7>>, 16)
    explicit = IP.url!(IP.new(), source, config, iv: iv)
    assert explicit == IP.url!(IP.new(), source, config, iv: iv)

    assert <<1, ^iv::binary-size(16), _rest::binary>> =
             Base.url_decode64!(encrypted_token(explicit), padding: false)

    mount =
      ImagePipe.API.validate_config!(keys: [@signing_key], source_encryption_keys: [@source_key])

    for path <- [first, second, explicit] do
      assert {{:ok, %{source: ^source}}, _meta} =
               ImagePipe.API.parse(Plug.Test.conn(:get, path), mount)
    end

    random_config = encrypted_config(iv_mode: :random)
    refute IP.url!(IP.new(), source, random_config) == IP.url!(IP.new(), source, random_config)

    assert IP.url!(IP.new(), source, random_config, iv: :deterministic) ==
             IP.url!(IP.new(), source, config)
  end

  test "encryption configuration and per-call overrides reject mistakes without secrets" do
    for options <- [[iv: <<0::120>>], [iv: <<0::136>>], [iv: nil], [unknown: "private"]] do
      assert IP.url(IP.new(), "secret-source", encrypted_config(), options) ==
               {:error, :invalid_encryption_options}
    end

    assert IP.url(IP.new(), "secret-source", IP.url_config(), iv: :random) ==
             {:error, :source_encryption_disabled}

    assert_raise ArgumentError, fn -> IP.url_config(encrypt_source: true) end
    assert_raise ArgumentError, fn -> encrypted_config(iv_mode: <<0::128>>) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: []) end
    assert_raise ArgumentError, fn -> encrypted_config(keys: [Base.encode16(@source_key)]) end
    refute inspect(encrypted_config()) =~ @signing_key
    refute inspect(encrypted_config()) =~ @source_key
  end

  test "plain URLs need no configuration and preserve escaped source bytes" do
    source = "https://origin.test/a b/猫.jpg?token=a+b%2Fc&n=1#frame"
    plan = IP.new() |> IP.group(resize: [width: 40]) |> IP.output(format: :png)
    assert {:ok, path} = IP.url(plan, source)
    assert path == IP.url!(plan, source)
    assert String.starts_with?(path, "/w=40/format=png/src/")
    assert URI.parse(path).query == nil
    assert URI.parse(path).fragment == nil
    assert {:ok, lexed} = Path.extract(Plug.Test.conn(:get, path))
    assert {:ok, request} = Parser.parse(lexed, presets: %{})
    assert {:ok, ^request} = Plan.to_request(plan, source)
  end

  test "signatures cover the mount-relative path with stable explicit expiry" do
    plan = IP.new(expires: 2_000_000_000) |> IP.group(gray: true)

    for base <- ["", "/images", "images", "https://cdn.test/images/"] do
      config = IP.url_config(base_url: base, keys: [@signing_key])
      path = IP.url!(plan, "photo.jpg", config)

      assert path ==
               IP.url!(plan, "photo.jpg", IP.url_config(base_url: base, keys: [@signing_key]))

      prefix = String.trim_trailing(base, "/")
      relative = String.replace_prefix(path, prefix, "")
      {signature, signed_path} = Path.split_signature(Plug.Test.conn(:get, relative))
      mount = ImagePipe.API.validate_config!(keys: [@signing_key])
      assert {:ok, 0} = Signature.verify(signature, signed_path, mount)
      assert signed_path == "/gray/expires=2000000000/src/photo.jpg"
      refute inspect(config) =~ @signing_key
    end
  end

  test "invalid sources and semantic failures return tagged errors without their content" do
    for source <- ["", <<255>>, {:binary, "private-bytes"}, {:file, "private-path"}] do
      assert IP.url(IP.new(), source) == {:error, :invalid_source}
    end

    invalid = IP.new() |> IP.group(extend: true)
    assert {:error, {:invalid_request, [_issue]}} = IP.url(invalid, "photo.jpg")
    assert_raise ArgumentError, fn -> IP.url!(invalid, "private-source") end
    assert_raise ArgumentError, fn -> IP.url!(IP.new(), {:binary, "private-source"}) end
  end

  test "base URL and credentials are validated without reflecting secret values" do
    for base <- [
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
      error = assert_raise ArgumentError, fn -> IP.url_config(base_url: base) end
      refute Exception.message(error) =~ "secret"
    end

    error = assert_raise ArgumentError, fn -> IP.url_config(keys: ["secret!"]) end
    refute Exception.message(error) =~ "secret!"
    assert_raise ArgumentError, fn -> IP.url_config(unknown: true) end
  end

  test "option count is limited to paths the HTTP parser accepts" do
    plan = Enum.reduce(1..33, IP.new(), fn _, plan -> IP.group(plan, gray: true) end)
    assert IP.url(plan, "photo.jpg") == {:error, :too_many_options}
  end

  test "dot source identifiers cannot become browser path traversal" do
    for source <- [".", ".."] do
      path = IP.url!(IP.new(), source)
      assert String.starts_with?(path, "/src64/")
      assert {:ok, %{source: {:src64, ^source, _span}}} = Path.extract(Plug.Test.conn(:get, path))
    end
  end

  property "arbitrary UTF-8 sources round trip without becoming URL syntax" do
    check all source <- string(:utf8, min_length: 1, max_length: 100) do
      path = IP.url!(IP.new(), source)

      assert {:ok, %{source: {_marker, ^source, _span}}} =
               Path.extract(Plug.Test.conn(:get, path))
    end
  end

  property "UTF-8 encrypted sources round trip across CBC block boundaries" do
    config = encrypted_config()

    mount =
      ImagePipe.API.validate_config!(keys: [@signing_key], source_encryption_keys: [@source_key])

    check all source <- string(:utf8, min_length: 1, max_length: 100),
              iv <- binary(length: 16) do
      path = IP.url!(IP.new(), source, config, iv: iv)

      assert {{:ok, %{source: ^source}}, _meta} =
               ImagePipe.API.parse(Plug.Test.conn(:get, path), mount)
    end
  end

  defp encrypted_config(options \\ []) do
    [keys: [@signing_key], source_encryption_keys: [@source_key], encrypt_source: true]
    |> Keyword.merge(options)
    |> IP.url_config()
  end

  defp encrypted_token(path), do: path |> String.split("/enc/") |> List.last()
end
