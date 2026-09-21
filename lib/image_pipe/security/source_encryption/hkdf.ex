defmodule ImagePipe.Security.SourceEncryption.HKDF do
  @moduledoc false

  # HKDF-SHA256, RFC 5869. Only used with fixed protocol parameters.
  def derive(key, salt, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, key)

    {blocks, _last} =
      Enum.map_reduce(1..div(length + 31, 32), <<>>, fn index, previous ->
        block = :crypto.mac(:hmac, :sha256, prk, [previous, info, <<index>>])
        {block, block}
      end)

    blocks |> IO.iodata_to_binary() |> binary_part(0, length)
  end
end
