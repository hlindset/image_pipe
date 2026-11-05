defmodule ImagePipeServer.Warmup do
  @moduledoc false
  # Processes a small image once in each output format before the listener
  # starts, so the first requests don't wait for the processing code to load
  # or for libvips to set up an encoder. Then it loads the rest of the request
  # path's code: the listener, the Plug, URL parsing, sources, the cache, and
  # the HTTP client. The release runs in interactive mode, which loads each
  # module on first use. Started as a supervisor child that returns :ignore
  # once it's done, or once its deadline passes. A failure is logged and
  # doesn't stop the server.

  require Logger

  @formats [:jpeg, :png, :webp, :avif]
  # Its own prefix keeps these requests out of the server's logs and traces.
  @telemetry_prefix [:image_pipe_server, :warmup]
  @deadline 5_000
  # About 5 MB of code. Every module in the release would be about 140 MB.
  @request_path [
    :image_pipe,
    :image_pipe_url,
    :bandit,
    :thousand_island,
    :plug,
    :plug_crypto,
    :mime,
    :req,
    :finch,
    :mint,
    :hpax,
    :nimble_pool
  ]

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
  # Without the request defaults, so the warmup never fetches a watermark or
  # runs a detector a default names, and a slow origin can't hold the
  # listener closed. The deadline bounds whatever else could stall it.
  @spec run(atom(), non_neg_integer()) :: :ok
  def run(instance, deadline \\ @deadline) do
    {pid, ref} = spawn_monitor(fn -> warm(instance) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.warning("warmup: crashed: #{Exception.format_exit(reason)}")
    after
      deadline ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        Logger.warning("warmup: didn't finish within #{deadline} ms, starting anyway")
    end

    :ok
  end

  defp warm(instance) do
    source = Image.new!(16, 16, color: [200, 120, 40]) |> Image.write!(:memory, suffix: ".png")

    for format <- @formats do
      plan =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(resize: [width: 8])
        |> ImagePipe.URL.output(format: format)

      options = [telemetry_prefix: @telemetry_prefix, request_defaults: nil]

      case ImagePipe.run(instance, plan, {:binary, source}, options) do
        {:ok, _result} -> :ok
        {:error, reason} -> Logger.warning("warmup: #{format} failed: #{inspect(reason)}")
      end
    end

    modules = Enum.flat_map(@request_path, &Application.spec(&1, :modules))

    case :code.ensure_modules_loaded(modules) do
      :ok -> :ok
      {:error, failed} -> Logger.warning("warmup: modules failed to load: #{inspect(failed)}")
    end
  end
end
