defmodule ImagePipe.Cache.Resources.Supervisor do
  @moduledoc false
  use Supervisor

  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.Resources.Registration

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    table = Registration.new()
    child = %{id: Resources, start: {Resources, :start_link, [table]}}
    Supervisor.init([child], strategy: :one_for_one)
  end
end
