defmodule ImagePipe.Instance.Publisher do
  # Holds an instance's configuration visible to mounts while it runs.
  @moduledoc false
  use GenServer

  alias ImagePipe.Config

  def start_link({name, config, mounts}),
    do: GenServer.start_link(__MODULE__, {name, config, mounts})

  @impl true
  def init({name, config, mounts}) do
    Process.flag(:trap_exit, true)
    :ok = Config.publish(name, config, mounts)
    {:ok, name}
  end

  @impl true
  def terminate(_reason, name), do: Config.unpublish(name)
end
