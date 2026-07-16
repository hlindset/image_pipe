defmodule ImagePipe.Dialect.Imgproxy.InfoRendererTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.InfoRenderer
  alias ImagePipe.Plan.SourceInfo

  defp render(info) do
    {content_type, body} = InfoRenderer.render(info)
    {content_type, JSON.decode!(IO.iodata_to_binary(body))}
  end

  test "reports imgproxy spellings for HEIC and JXL sources" do
    {_ct, heic} = render(%SourceInfo{format: :heif, width: 10, height: 10, orientation: 1})
    assert heic["format"] == "heic"
    assert heic["mime_type"] == "image/heif"

    {_ct, jxl} = render(%SourceInfo{format: :jpeg_xl, width: 10, height: 10, orientation: 1})
    assert jxl["format"] == "jxl"
    assert jxl["mime_type"] == "image/jxl"
  end
end
