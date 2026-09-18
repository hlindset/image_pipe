defmodule ImagePipeFiddle.SourceMountsTest do
  use ExUnit.Case, async: false

  setup do
    enabled? = Application.get_env(:image_pipe_fiddle, :loopback_http_source, false)

    on_exit(fn ->
      Application.put_env(:image_pipe_fiddle, :loopback_http_source, enabled?)
    end)

    :ok
  end

  test "source mounts configure the native endpoint" do
    opts = ImagePipe.Plug.init(sources: ImagePipeFiddle.Application.source_mounts())
    sources = Keyword.fetch!(opts, :sources)
    assert Map.has_key?(sources, :path)
    assert Map.has_key?(sources, :s3)
    assert Map.has_key?(sources, :http)
  end

  test "loopback HTTP source is absent when its local-development flag is disabled" do
    Application.put_env(:image_pipe_fiddle, :loopback_http_source, false)

    opts = ImagePipe.Plug.init(sources: ImagePipeFiddle.Application.source_mounts())

    refute Map.has_key?(Keyword.fetch!(opts, :sources), :http)
  end
end
