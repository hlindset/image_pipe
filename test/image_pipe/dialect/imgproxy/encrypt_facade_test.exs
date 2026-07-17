defmodule ImagePipe.Dialect.Imgproxy.EncryptFacadeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy, as: D

  @aes128_key "000102030405060708090a0b0c0d0e0f"
  @fixed_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  @source_url "images/beach.jpg"
  @expected_segment "EBESExQVFhcYGRobHB0eH8rMlFATFrQRB9W8yCuS192Vp3lXrVGFOgzMq2IzxKSZ"

  test "encrypt_source_url/3 encrypts a source URL into an imgproxy source segment" do
    assert D.encrypt_source_url(@source_url, @aes128_key, iv: @fixed_iv) ==
             {:ok, @expected_segment}
  end

  test "encrypt_source_url/3 returns stable errors for malformed runtime input" do
    assert D.encrypt_source_url(:not_binary, @aes128_key) == {:error, :invalid_source_url}
    assert D.encrypt_source_url(@source_url, :not_binary) == {:error, :invalid_key}
    assert D.encrypt_source_url(@source_url, "not-hex") == {:error, :invalid_key}
    assert {:ok, _segment} = D.encrypt_source_url(@source_url, @aes128_key, [])

    assert D.encrypt_source_url(@source_url, @aes128_key, %{iv: @fixed_iv}) ==
             {:error, :invalid_options}

    assert D.encrypt_source_url(@source_url, @aes128_key, unknown: true) ==
             {:error, :invalid_options}
  end
end
