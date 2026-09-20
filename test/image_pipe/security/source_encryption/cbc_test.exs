defmodule ImagePipe.Security.SourceEncryption.CBCTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Security.SourceEncryption.CBC

  # RFC 7518, Appendix B.3 (A256CBC-HS512).
  test "matches the published encryption and authentication vector" do
    key = :binary.list_to_bin(Enum.to_list(0..63))
    iv = hex("1af38c2dc2b96ffdd86694092341bc04")
    aad = "The second principle of Auguste Kerckhoffs"

    plaintext =
      "A cipher system must not be required to be secret, and it must be able to fall into the hands of the enemy without inconvenience"

    ciphertext =
      hex("""
      4affaaadb78c31c5da4b1b590d10ffbd3dd8d5d302423526912da037ecbcc7bd
      822c301dd67c373bccb584ad3e9279c2e6d12a1374b77f077553df829410446b
      36ebd97066296ae6427ea75c2e0846a11a09ccf5370dc80bfecbad28c73f09b3
      a3b75e662a2594410ae496b2e2e6609e31e6e02cc837f053d21f37ff4f51950b
      be2638d09dd7a4930930806d0703b1f6
      """)

    tag = hex("4dd3b4c088a7f45c216839645b2012bf2e6269a8c56a816dbc1b267761955bc5")
    assert CBC.encrypt(plaintext, key, iv, aad) == {ciphertext, tag}
    assert CBC.decrypt(ciphertext, tag, key, iv, aad) == {:ok, plaintext}
    assert CBC.decrypt(ciphertext, tag, key, iv, "different context") == :error
    assert CBC.decrypt(ciphertext, tag, key, <<0::128>>, aad) == :error
  end

  defp hex(value), do: value |> String.replace(~r/\s/, "") |> Base.decode16!(case: :lower)
end
