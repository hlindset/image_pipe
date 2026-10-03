defmodule ImagePipe.Source.S3.CredentialWarmup do
  use GenServer, restart: :transient

  alias ImagePipe.Source.S3.Credentials

  @options_schema NimbleOptions.new!(
                    provider: [
                      type: :atom,
                      required: true,
                      doc: "The provider module, as in the mount's `:credentials`."
                    ],
                    scope: [
                      type: :string,
                      required: true,
                      doc: "The bucket whose credentials to fetch."
                    ],
                    opts: [
                      type: :keyword_list,
                      default: [],
                      doc: """
                      The provider's options. They must equal the options in the \
                      mount's `:credentials`, or requests use a different cache \
                      entry and the warmup has no effect.
                      """
                    ]
                  )

  @moduledoc """
  Fetches S3 credentials from a provider at startup, so the first request
  for a bucket doesn't wait for them.

      children = [
        {ImagePipe.Source.S3.CredentialWarmup,
         provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"},
        MyAppWeb.Endpoint
      ]

  ImagePipe doesn't start it. It fetches once without blocking startup, then
  stops. If the fetch fails, the first request fetches the credentials
  instead. Invalid options raise `ArgumentError` from `start_link/1`.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @options_schema),
         state = Map.new(opts),
         {:ok, _credentials} <- Credentials.validate({:provider, state.provider, state.opts}) do
      GenServer.start_link(__MODULE__, state)
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, Exception.message(error)

      {:error, _reason} ->
        raise ArgumentError, "invalid credential provider configuration"
    end
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :warm_then_stop}}

  @impl true
  def handle_continue(:warm_then_stop, state) do
    _ = Credentials.fetch(state.scope, {:provider, state.provider, state.opts}, [])
    {:stop, :normal, state}
  end
end
