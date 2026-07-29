defmodule ImagePipe.Test.Differential.Harness do
  @moduledoc """
  Shared live-render machinery for differential suites. Builds a request pipeline
  that serves committed source bytes over a local function plug, so a suite's
  conformance test, report, and diagnose tasks all render identically.
  Suite-specific wrappers supply the dialect and the per-case path.

  An arm is an opaque `{plug_module, initialized_opts}` pair built by
  `dialect_plug_opts/2`; `render/2` dispatches on the pair, so callers thread an
  arm through without knowing how it was built. Each arm carries its own
  initialized opts — nothing (no cache, no counter) is shared between two arms
  built from separate calls.
  """
  use Boundary, top_level?: true, check: [out: false]

  import Plug.Test
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @doc """
  Dialect arm: `dialect` mounted through the shared `ImagePipe.Plug` runner
  over the same local source wiring — `ImagePipe.Plug, dialect: dialect,
  <flat config>`, the same unified mount every dialect uses in production.
  """
  def dialect_plug_opts(dialect, sources_dir) do
    {ImagePipe.Plug, ImagePipe.Plug.init(dialect: dialect, sources: sources(sources_dir))}
  end

  @doc "Render `request_path` through an arm → `{body_bytes, content_type}`."
  def render(request_path, {plug, plug_opts}) do
    conn = :get |> conn(request_path) |> plug.call(plug_opts)

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {conn.resp_body, content_type}
  end

  @doc "Render `request_path` to a decoded `Vix.Vips.Image` (random access)."
  def render_image(request_path, plug_opts) do
    {body, _ct} = render(request_path, plug_opts)
    Image.open!(body, access: :random, fail_on: :error)
  end

  @doc "Local `path:` source config serving `sources_dir`'s committed files."
  def sources(sources_dir) do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", req_options: [plug: source_plug(sources_dir)]}
    ]
  end

  defp source_plug(sources_dir) do
    fn conn ->
      file = Path.basename(conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(content_type(file))
      |> Plug.Conn.send_resp(200, File.read!(Path.join(sources_dir, file)))
    end
  end

  defp content_type(file) do
    case Path.extname(file) do
      ".jpg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end
end
