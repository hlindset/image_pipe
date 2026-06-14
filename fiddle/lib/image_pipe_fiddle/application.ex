defmodule ImagePipeFiddle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :persistent_term.put({__MODULE__, :imgproxy_opts}, build_imgproxy_opts())
    :persistent_term.put({__MODULE__, :iiif_opts}, build_iiif_opts())
    ImagePipe.Telemetry.attach_default_logger(events: :all, level: :debug, debug: true)
    maybe_attach_tracer()

    children =
      [
        ImagePipeFiddleWeb.Telemetry,
        {DNSCluster,
         query: Application.get_env(:image_pipe_fiddle, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ImagePipeFiddle.PubSub},
        ImagePipeFiddleWeb.Endpoint,
        {ImagePipe.Transform.Detector.Warmup, detector: :default, classes: ["face"]}
      ] ++ cache_children(Application.get_env(:image_pipe_fiddle, :cache))

    opts = [strategy: :one_for_one, name: ImagePipeFiddle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImagePipeFiddleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Opt-in OpenTelemetry tracing: with FIDDLE_OTEL=1 (and Jaeger running — see
  # docker-compose.yml), replay ImagePipe's spans into the OTel SDK, which exports
  # them over OTLP to Jaeger. Off by default so `mise run server` needs no Jaeger.
  defp maybe_attach_tracer do
    if System.get_env("FIDDLE_OTEL") in ~w(1 true) do
      ImagePipe.Telemetry.attach_tracer(
        exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
        extract_inbound: true
      )
    end
  end

  defp build_imgproxy_opts do
    imgproxy = Application.fetch_env!(:image_pipe_fiddle, :imgproxy)
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      imgproxy: imgproxy,
      # Graceful fallback: detection failures degrade to attention crop (200) rather
      # than erroring; the default Logger surfaces any detection fallback.
      detector_required: false
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end

  defp build_iiif_opts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()},
        max_width: 4000,
        max_height: 4000
      ],
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ]
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end

  # Maps each sample image to a slash-free, extension-stripped IIIF identifier
  # (images/dog.jpg -> "dog"). Sample filenames are URL-safe by convention, so the
  # id needs no encoding. Stems must be unique across the set; raises if not.
  defp iiif_source_map do
    files =
      :image_pipe_fiddle
      |> Application.app_dir("priv/static/images")
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) in ~w(.avif .jpeg .jpg .png .webp)))

    map =
      Map.new(files, fn file ->
        {Path.rootname(file), %ImagePipe.Plan.Source.Path{segments: ["images", file]}}
      end)

    if map_size(map) < length(files) do
      raise "IIIF identifier stem collision among sample images (two files share a basename)"
    end

    map
  end

  defp maybe_put_cache(opts, nil), do: opts
  defp maybe_put_cache(opts, cache), do: Keyword.put(opts, :cache, cache)

  defp cache_children(nil), do: []

  defp cache_children({module, opts}) do
    case module.child_spec(opts) do
      :ignore -> []
      spec -> [spec]
    end
  end
end
