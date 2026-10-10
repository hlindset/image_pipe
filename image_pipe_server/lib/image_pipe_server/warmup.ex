defmodule ImagePipeServer.Warmup do
  @moduledoc false
  # Processes a small image once in each output format before the listener
  # starts, so the first requests don't wait for the processing code to load
  # or for libvips to set up an encoder. Started as a supervisor child that
  # returns :ignore once it's done. A failure is logged and doesn't stop the
  # server.

  require Logger

  @formats [:jpeg, :png, :webp, :avif]
  # Its own prefix keeps these requests out of the server's logs and traces.
  @telemetry_prefix [:image_pipe_server, :warmup]

  @doc false
  def child_spec(instance) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [instance]}, restart: :temporary}
  end

  @doc false
  def start_link(instance) do
    run(instance)
    :ignore
  end

  @doc false
  @spec run(atom()) :: :ok
  def run(instance) do
    source = Image.new!(16, 16, color: [200, 120, 40]) |> Image.write!(:memory, suffix: ".png")

    for format <- @formats do
      plan =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(resize: [width: 8])
        |> ImagePipe.URL.output(format: format)

      case ImagePipe.run(instance, plan, {:binary, source}, telemetry_prefix: @telemetry_prefix) do
        {:ok, _result} -> :ok
        {:error, reason} -> Logger.warning("warmup: #{format} failed: #{inspect(reason)}")
      end
    end

    :ok
  end
end
