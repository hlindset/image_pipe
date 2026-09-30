defmodule ImagePipe.Test.HeaderDimensions.RecordingOpen do
  @moduledoc false

  def open(path, options) do
    pid =
      case Process.get(:"$callers") do
        [caller | _] -> caller
        _ -> self()
      end

    send(pid, {:loader_open, options})
    Image.open(path, options)
  end
end
