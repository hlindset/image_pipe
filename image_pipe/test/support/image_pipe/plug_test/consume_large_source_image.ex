defmodule ImagePipe.PlugTest.ConsumeLargeSourceImage do
  @moduledoc false
  def open(_input, decode_options) do
    "priv/static/images/beach.jpg"
    |> File.read!()
    |> Image.open(decode_options)
  end
end
