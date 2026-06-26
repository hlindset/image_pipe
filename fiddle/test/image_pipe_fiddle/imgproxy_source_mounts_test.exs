defmodule ImagePipeFiddle.ImgproxySourceMountsTest do
  use ExUnit.Case, async: true

  # The fiddle mounts three source adapters for the imgproxy provider so the demo
  # can fetch the same sample images via local / s3 / http. This pins that the s3
  # and http mount shapes are accepted by ImagePipe's host-config validation
  # (Plug.init raises on an invalid source config).
  test "imgproxy_source_mounts/0 is accepted by ImagePipe.Plug.init/1" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: Application.fetch_env!(:image_pipe_fiddle, :imgproxy),
        sources: ImagePipeFiddle.Application.imgproxy_source_mounts()
      )

    assert is_list(opts)
    sources = Keyword.fetch!(opts, :sources)
    # url: fans out to :http/:https inside ImagePipe; s3 stays under :s3.
    assert Map.has_key?(sources, :s3)
    assert Map.has_key?(sources, :http)
  end
end
