defmodule ImagePipeFiddle.SourcesTest do
  use ExUnit.Case, async: false

  setup do
    enabled? = Application.get_env(:image_pipe_fiddle, :loopback_http_source, false)

    on_exit(fn ->
      Application.put_env(:image_pipe_fiddle, :loopback_http_source, enabled?)
    end)

    :ok
  end

  test "the configured sources serve the API endpoint" do
    sources = ImagePipeFiddle.Application.sources()
    assert ImagePipe.Plug.init(sources: sources)
    assert Keyword.keys(sources) == [:path, :s3, :url]
  end

  test "loopback HTTP source is absent when its local-development flag is disabled" do
    Application.put_env(:image_pipe_fiddle, :loopback_http_source, false)

    sources = ImagePipeFiddle.Application.sources()
    assert ImagePipe.Plug.init(sources: sources)
    refute Keyword.has_key?(sources, :url)
  end
end
