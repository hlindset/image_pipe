defmodule ImagePipe.API.SourceEncryption.HKDFTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.SourceEncryption.HKDF

  test "matches RFC 5869 SHA-256 test case 1" do
    assert HKDF.derive(
             :binary.copy(<<11>>, 22),
             bytes(0..12),
             bytes(240..249),
             42
           ) ==
             Base.decode16!(
               "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
               case: :lower
             )
  end

  test "matches RFC 5869 SHA-256 test case 2 across three expansion blocks" do
    assert HKDF.derive(bytes(0..79), bytes(96..175), bytes(176..255), 82) ==
             Base.decode16!(
               "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87",
               case: :lower
             )
  end

  defp bytes(range), do: range |> Enum.to_list() |> :binary.list_to_bin()
end
