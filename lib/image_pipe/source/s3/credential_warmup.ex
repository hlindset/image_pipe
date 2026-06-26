defmodule ImagePipe.Source.S3.CredentialWarmup do
  @moduledoc """
  Optional one-shot worker that primes an S3 credential cache entry at boot, so
  the first image request for a bucket does not pay the provider round-trip.

  Host-wired (ImagePipe does not start it):

      {ImagePipe.Source.S3.CredentialWarmup,
       provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"}

  Warms once in `handle_continue/2` (so host boot is never blocked) then stops
  `:normal`. A warm-up failure is non-fatal: the entry is left cold and the first
  real request falls through to the lazy path.
  """
  use GenServer, restart: :transient

  alias ImagePipe.Source.S3.Credentials

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      provider: Keyword.fetch!(opts, :provider),
      opts: Keyword.get(opts, :opts, []),
      scope: Keyword.fetch!(opts, :scope)
    }

    {:ok, state, {:continue, :warm_then_stop}}
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    _ = Credentials.fetch(state.scope, {:provider, state.provider, state.opts}, [])
    {:stop, :normal, state}
  end
end
