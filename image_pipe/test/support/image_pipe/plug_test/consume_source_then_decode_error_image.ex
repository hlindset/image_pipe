defmodule ImagePipe.PlugTest.ConsumeSourceThenDecodeErrorImage do
  @moduledoc false
  def open(_input, _decode_options) do
    {:error, :forced_decode_error}
  end
end
