defmodule ImagePipe.Execution.Staging.Resources.Supervisor do
  @moduledoc false
  use Supervisor

  alias ImagePipe.Execution.Staging.Resources

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    table = :ets.new(__MODULE__, [:set, :public])
    child = %{id: Resources, start: {Resources, :start_link, [table]}}
    Supervisor.init([child], strategy: :one_for_one)
  end
end
