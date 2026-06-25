defmodule ImagePipe.Request.SourceSessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias ImagePipe.Request.SourceSession
  alias ImagePipe.Request.SourceSession.Request

  @type supervisor() :: Supervisor.supervisor()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])

    DynamicSupervisor.start_link(__MODULE__, init_opts, start_link_opts(start_opts))
  end

  @spec start_session(Request.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(request, opts \\ [])

  def start_session(%Request{} = request, opts) do
    start_session(__MODULE__, request, opts)
  end

  @spec start_session(supervisor(), Request.t()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor, %Request{} = request) do
    start_session(supervisor, request, [])
  end

  @spec start_session(supervisor(), Request.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor, %Request{} = request, opts) do
    opts = Keyword.put_new(opts, :owner, self())

    DynamicSupervisor.start_child(supervisor, {SourceSession, {request, opts}})
  end

  @spec stop_session(supervisor(), pid()) :: :ok
  def stop_session(supervisor, pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_link_opts([]), do: [name: __MODULE__]
  defp start_link_opts(name: nil), do: []
  defp start_link_opts(opts), do: opts
end
