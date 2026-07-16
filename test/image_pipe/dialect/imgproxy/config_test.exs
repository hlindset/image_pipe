defmodule ImagePipe.Dialect.Imgproxy.ConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.Config
  alias ImagePipe.Dialect.Imgproxy.Presets
  alias ImagePipe.Dialect.Imgproxy.Signature

  test "applies dialect, neutral, and shared defaults with no opts" do
    validated = Config.validate!([])

    # dialect defaults
    assert validated[:signature] == Signature.disabled()
    assert validated[:source_url_encryption] == nil
    assert validated[:base64_url_includes_filename] == false
    assert validated[:source_schemes] == %{}
    assert validated[:presets] == Presets.empty()
    assert validated[:storage_inputs] == []
    assert is_function(validated[:clock], 0)

    # neutral (ImagePipe.Config) defaults
    assert validated[:quality] == 80

    # shared (SharedConfig) defaults
    assert validated[:max_body_bytes] == 10_000_000
  end

  test "an unknown top-level option raises" do
    assert_raise ArgumentError, ~r/unknown ImagePipe.Dialect.Imgproxy option/, fn ->
      Config.validate!(bogus_option: true)
    end
  end

  test "normalizes a signature config into a Signature struct" do
    validated =
      Config.validate!(
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ]
      )

    assert %Signature{mode: :enabled} = validated[:signature]
  end

  test "validates a presets config into a Presets struct" do
    validated = Config.validate!(presets: %{"square" => "rs:fill:200:200"})

    assert {:ok, [["rs:fill:200:200"]]} = Presets.fetch(validated[:presets], "square")
  end

  test "rejects an invalid presets config" do
    assert_raise ArgumentError, fn ->
      Config.validate!(presets: %{"square" => 123})
    end
  end

  test "a neutral key (quality) resolves through ImagePipe.Config" do
    validated = Config.validate!(quality: 42)

    assert validated[:quality] == 42
  end

  test "source_url_encryption_key normalizes to source_url_encryption" do
    validated = Config.validate!(source_url_encryption_key: "000102030405060708090a0b0c0d0e0f")

    assert validated[:source_url_encryption_key] == nil
    refute is_nil(validated[:source_url_encryption])
  end

  test "storage_inputs accepts header/cookie entries" do
    validated =
      Config.validate!(storage_inputs: [{:header, "X-Client"}, {:cookie, "session"}])

    assert validated[:storage_inputs] == [{:header, "X-Client"}, {:cookie, "session"}]
  end

  test "storage_inputs rejects an invalid entry" do
    assert_raise ArgumentError, fn ->
      Config.validate!(storage_inputs: [{:query, "whatever"}])
    end
  end

  test "clock accepts a caller-supplied zero-arity function" do
    clock = fn -> DateTime.from_unix!(101) end
    validated = Config.validate!(clock: clock)

    assert validated[:clock] == clock
  end

  test "clock rejects a non-zero-arity value" do
    assert_raise ArgumentError, fn ->
      Config.validate!(clock: :not_a_function)
    end
  end

  test "rejects malformed source scheme translators" do
    assert_raise ArgumentError, fn ->
      Config.validate!(source_schemes: %{"s3" => {NotAModule, []}})
    end
  end
end
