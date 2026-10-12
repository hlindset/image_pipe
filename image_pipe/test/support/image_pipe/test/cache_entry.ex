defmodule ImagePipe.Test.CacheEntry do
  @moduledoc false
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.Key
  alias ImagePipe.Test.Caches

  def put(opts, body) do
    key = %Key{hash: Base.encode16(:crypto.hash(:sha256, body), case: :lower), data: []}

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      output_format: :png,
      created_at: ~U[2026-04-29 10:15:00Z],
      cost_us: 1000
    }

    Caches.write!(opts, key, metadata, body)
    :ok
  end
end
