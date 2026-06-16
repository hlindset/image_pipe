defmodule ImagePipe.Test.Differential.Harness do
  @moduledoc """
  Shared live-render machinery for differential suites. Builds an `ImagePipe.Plug`
  pipeline that serves committed source bytes over a local function plug, so a
  suite's conformance test, report, and diagnose tasks all render identically.
  Suite-specific wrappers supply the parser and the per-case request path.
  """
  use Boundary, top_level?: true, check: [out: false]

  import Plug.Test
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @doc "`ImagePipe.Plug` opts serving `sources_dir`'s files locally for `parser`."
  def plug_opts(parser, sources_dir) do
    ImagePipe.Plug.init(
      parser: parser,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: source_plug(sources_dir)]}
      ]
    )
  end

  @doc "Render `request_path` through `plug_opts` → `{body_bytes, content_type}`."
  def render(request_path, plug_opts) do
    conn = :get |> conn(request_path) |> ImagePipe.Plug.call(plug_opts)

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
