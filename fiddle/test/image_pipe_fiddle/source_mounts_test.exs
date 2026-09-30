defmodule ImagePipeFiddle.SourceMountsTest do
  use ExUnit.Case, async: false

  setup do
    enabled? = Application.get_env(:image_pipe_fiddle, :loopback_http_source, false)

    on_exit(fn ->
      Application.put_env(:image_pipe_fiddle, :loopback_http_source, enabled?)
    end)

    :ok
  end

  test "source mounts configure the API endpoint" do
    mounts = ImagePipeFiddle.Application.source_mounts()
    assert ImagePipe.Plug.init(sources: mounts)
    assert Keyword.keys(mounts) == [:path, :s3, :url]
  end

  test "loopback HTTP source is absent when its local-development flag is disabled" do
    Application.put_env(:image_pipe_fiddle, :loopback_http_source, false)

    mounts = ImagePipeFiddle.Application.source_mounts()
    assert ImagePipe.Plug.init(sources: mounts)
    refute Keyword.has_key?(mounts, :url)
  end
end
