# IIIF Validator Server
#
# Starts an HTTP server on port 4000 (or $PORT) that serves the reference image
# via the ImagePipe IIIF parser for use by the `iiif-validate.py` validator.
#
# Run with:
#   mise exec -- mix run validator/server.exs
#
# The server mounts ImagePipe.Parser.IIIF at /iiif with the reference fixture
# image (validator/fixtures/67352ccc-d1b0-11e1-89ae-279075081939.png) mapped to
# the identifier "67352ccc-d1b0-11e1-89ae-279075081939".

defmodule ValidatorServer.RefImageOrigin do
  @moduledoc false

  # Serves the reference image bytes for any GET request.
  @fixture_path Path.join([
                  __DIR__,
                  "fixtures",
                  "67352ccc-d1b0-11e1-89ae-279075081939.png"
                ])

  def init(opts), do: opts

  def call(conn, _opts) do
    body = File.read!(@fixture_path)

    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, body)
  end
end

defmodule ValidatorServer.IIIFPlug do
  @moduledoc false

  alias ImagePipe.Parser.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @image_id "67352ccc-d1b0-11e1-89ae-279075081939"

  @behaviour Plug

  @impl Plug
  def init(_opts) do
    ImagePipe.Plug.init(
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver:
          {StaticResolver,
           map: %{
             @image_id => %SourcePath{segments: ["ref.png"]}
           }}
      ],
      allow_origin: "*",
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.local",
           req_options: [plug: ValidatorServer.RefImageOrigin]}
      ]
    )
  end

  @impl Plug
  def call(conn, opts), do: ImagePipe.Plug.call(conn, opts)
end

defmodule ValidatorServer.Router do
  @moduledoc false

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # forward/2 strips the matched prefix from path_info and sets script_name,
  # which is exactly what IIIF Path.base_uri/1 reads to build the id URL.
  forward("/iiif", to: ValidatorServer.IIIFPlug)

  match _ do
    send_resp(conn, 404, "not found")
  end
end

port = System.get_env("PORT", "4000") |> String.to_integer()

IO.puts("Starting IIIF validator server on port #{port}...")
IO.puts("Reference image: 67352ccc-d1b0-11e1-89ae-279075081939")
IO.puts("")
IO.puts("Verify with:")
IO.puts("  curl -s http://localhost:#{port}/iiif/67352ccc-d1b0-11e1-89ae-279075081939/info.json | jq .")
IO.puts("")

{:ok, _} =
  Bandit.start_link(
    plug: ValidatorServer.Router,
    scheme: :http,
    port: port,
    ip: {0, 0, 0, 0}
  )

# Keep running until Ctrl+C or SIGTERM
Process.sleep(:infinity)
