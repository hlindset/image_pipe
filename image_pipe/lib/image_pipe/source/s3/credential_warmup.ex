defmodule ImagePipe.Source.S3.CredentialWarmup do
  use GenServer

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
                      mount's `:credentials`. Otherwise requests use a different \
                      cache entry, and the warmed credentials are refreshed in \
                      the background without ever being used.
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

  ImagePipe doesn't start it. Add one per bucket. The children need no
  explicit ids. Each warmup starts the fetch without blocking startup, then
  stops. The credentials aren't dropped before the first request for the
  bucket uses them. If the fetch fails, the first request fetches the
  credentials instead.

  Invalid options raise `ArgumentError` from `start_link/1`. A `:provider`
  without `validate_options/1` raises `UndefinedFunctionError`.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """

  # The options can hold secrets, so the id carries only their hash.
  @doc false
  def child_spec(opts) do
    id = {__MODULE__, opts[:provider], opts[:scope], :erlang.phash2(opts[:opts])}
    %{id: id, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

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
    _ = Credentials.warm(state.scope, {:provider, state.provider, state.opts})
    {:stop, :normal, state}
  end
end
