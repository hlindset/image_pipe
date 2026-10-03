defmodule ImagePipe.Instance.Publisher do
  # Holds an instance's configuration visible to mounts while it runs.
  @moduledoc false
  use GenServer

  alias ImagePipe.Config

  def start_link({name, config, urls}), do: GenServer.start_link(__MODULE__, {name, config, urls})

  @impl true
  def init({name, config, urls}) do
    Process.flag(:trap_exit, true)
    :ok = Config.publish(name, config, urls)
    {:ok, name}
  end

  @impl true
  def terminate(_reason, name), do: Config.unpublish(name)
end
