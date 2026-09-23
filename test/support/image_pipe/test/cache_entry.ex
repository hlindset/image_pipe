defmodule ImagePipe.Test.CacheEntry do
  @moduledoc false
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  def put(opts, body) do
    key = %Key{hash: Base.encode16(:crypto.hash(:sha256, body), case: :lower), data: []}

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      output_format: :png,
      created_at: ~U[2026-04-29 10:15:00Z],
      cost_us: 1000
    }

    with {:ok, sink} <- FileSystem.open_sink(key, metadata, opts),
         {:ok, sink} <- FileSystem.write_chunk(sink, body, opts) do
      FileSystem.commit_sink(sink, opts)
    end
  end
end
