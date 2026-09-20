defmodule ImagePipe.RunTest.LateFailureEncoder do
  @moduledoc false

  def stream!(_image, _options) do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {["encoded prefix"], :raise}
        :raise -> raise "late encoder failure"
      end,
      fn _state -> send(self(), :encoder_closed) end
    )
  end
end
