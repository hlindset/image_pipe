defmodule ImagePipeFiddle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @demo_signing_key String.duplicate("a1", 32)
  @demo_source_encryption_key :binary.copy(<<42, 73>>, 16)

  @impl true
  def start(_type, _args) do
    :persistent_term.put({__MODULE__, :native_opts}, build_native_opts())
    :persistent_term.put({__MODULE__, :native_signed_opts}, build_native_signed_opts())
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
  # them over OTLP to Jaeger. Off by default so `mise run fiddle` needs no Jaeger.
  defp maybe_attach_tracer do
    if System.get_env("FIDDLE_OTEL") in ~w(1 true) do
      ImagePipe.Telemetry.attach_tracer(
        exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
        extract_inbound: true
      )
    end
  end

  @doc false
  # Source adapters mounted for the native endpoint. The local File source is
  # always available; s3 (via the opt-in s3proxy compose service) lets the demo
  # compare source adapters on byte-identical sample images.
  def source_mounts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")
    s3 = Application.fetch_env!(:image_pipe_fiddle, :s3_source)

    mounts = [
      path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted},
      s3:
        {ImagePipe.Source.S3,
         default: [
           region: Keyword.fetch!(s3, :region),
           endpoint: Keyword.fetch!(s3, :endpoint),
           credentials:
             {:static,
              [
                access_key_id: Keyword.fetch!(s3, :access_key_id),
                secret_access_key: Keyword.fetch!(s3, :secret_access_key)
              ]}
         ],
         buckets: %{"sources" => []}}
    ]

    if Application.fetch_env!(:image_pipe_fiddle, :loopback_http_source) do
      mounts ++
        [
          url:
            {ImagePipe.Source.HTTP,
             allowed_hosts: ["localhost", "127.0.0.1"], address_policy: [allow_loopback: true]}
        ]
    else
      mounts
    end
  end

  defp build_native_opts do
    native_opts()
    |> ImagePipe.Plug.init()
  end

  defp build_native_signed_opts do
    native_opts()
    |> Keyword.merge(
      keys: [@demo_signing_key],
      source_encryption_keys: [@demo_source_encryption_key]
    )
    |> ImagePipe.Plug.init()
  end

  defp native_opts do
    [
      allow_origin: "*",
      allow_debug_headers: true,
      presets: %{
        "card" => "w=400/h=400/fit=cover",
        "framed" => "preset=card/then/pad=20/bg=fff/format=webp"
      },
      sources: source_mounts()
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
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
