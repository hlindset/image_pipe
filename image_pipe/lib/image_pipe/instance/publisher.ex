defmodule ImagePipe.Instance.Publisher do
  # Holds an instance's configuration visible to mounts while it runs.
  @moduledoc false
  use GenServer

  alias ImagePipe.Config

  def start_link({name, config}), do: GenServer.start_link(__MODULE__, {name, config})

  @impl true
  def init({name, config}) do
    Process.flag(:trap_exit, true)
    :ok = Config.publish(name, config)
    {:ok, name}
  end

  @impl true
  def terminate(_reason, name), do: Config.unpublish(name)
end
