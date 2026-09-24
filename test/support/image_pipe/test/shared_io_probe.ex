defmodule ImagePipe.Test.SharedIOProbe do
  @moduledoc false

  def wait(name) do
    Process.register(self(), name)

    receive do
      :release -> :released
    end
  end

  def cleanup(path, blocker) do
    case File.exists?(blocker) do
      true -> {:error, :eacces}
      false -> File.rm(path)
    end
  end
end
