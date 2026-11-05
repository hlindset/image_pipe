defmodule ImagePipe.Cache.MemoryLimit do
  # The memory limit of the container this node runs in, from its cgroup,
  # or nil when it has none. The default caps on what an instance remembers
  # in memory are lowered to fit it.
  @moduledoc false

  import Bitwise

  # cgroup v1 reports no limit as the largest page-aligned 64-bit value.
  @unlimited 1 <<< 60

  @spec bytes(Path.t()) :: pos_integer() | nil
  def bytes(cgroup \\ "/sys/fs/cgroup") do
    read(Path.join(cgroup, "memory.max")) ||
      read(Path.join(cgroup, "memory/memory.limit_in_bytes"))
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {bytes, ""} when bytes > 0 and bytes < @unlimited <- Integer.parse(String.trim(text)) do
      bytes
    else
      _none -> nil
    end
  end
end
