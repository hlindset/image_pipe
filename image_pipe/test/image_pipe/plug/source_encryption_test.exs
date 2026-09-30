defmodule ImagePipe.Plug.SourceEncryptionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plug.Config
  alias ImagePipe.Plug.Errors
  alias ImagePipe.Plug.Request, as: ParsedRequest
  alias ImagePipe.Security.Signature

  @key_a :binary.list_to_bin(Enum.to_list(0..31))
  @source "https://example.test/a.jpg"

  setup do
    url_config =
      ImagePipe.URL.config(keys: [String.duplicate("a1", 32)], source_encryption_keys: [@key_a])

    %{config: Config.validate!(url: url_config), url_config: url_config}
  end

  test "the public helper returns a token that parse authenticates into plaintext", %{
    config: config,
    url_config: url_config
  } do
    assert {:ok, token} = ImagePipe.URL.encrypt_source(@source, url_config)
    signed_path = "/w=12/enc/#{token}"
    signature = Signature.sign(signed_path, config)
    conn = Plug.Test.conn(:get, "/sig=#{signature}#{signed_path}")

    assert {{:ok, _request, source}, %{result: :ok, sig_key_index: 0}} =
             ParsedRequest.parse(conn, config)

    assert source == @source
  end

  test "signature validation precedes token validation", %{config: config} do
    invalid_conn = Plug.Test.conn(:get, "/sig=invalid/w=12/enc/not/a/token")

    assert {{:error, :invalid_signature}, %{result: :error}} =
             ParsedRequest.parse(invalid_conn, config)

    signed_path = "/w=12/enc/not/a/token"
    signature = Signature.sign(signed_path, config)
    signed_conn = Plug.Test.conn(:get, "/sig=#{signature}#{signed_path}")

    assert {{:error, :invalid_concealed_source}, %{result: :error}} =
             ParsedRequest.parse(signed_conn, config)
  end

  test "concealment failures render and classify as a fixed parser-side 404" do
    conn = Errors.send(Plug.Test.conn(:get, "/enc/private"), :invalid_concealed_source)

    assert conn.status == 404
    assert conn.resp_body == "not found"

    assert ImagePipe.Telemetry.request_result({:error, :invalid_concealed_source}) ==
             :parser_error
  end
end
