defmodule ImagePipe.Test.SharedIOProbe do
  @moduledoc false

  def wait(name) do
    Process.register(self(), name)

    receive do
      :release -> :released
    end
  end
end
