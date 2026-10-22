defmodule ImagePipe.Cache.WatermarkBytes do
  # Keeps the bytes of an instance's recently used watermark assets in memory,
  # so an asset from an origin isn't downloaded again for every processed
  # image, in a `RecentTable`. A row is keyed by the asset's input key and the
  # identity of its bytes, so a changed asset misses.
  #
  # Signed URLs can name any asset (`wm-src64`), so the table keeps at most
  # `@limit` assets of at most `@max_bytes` each, and forgets the least
  # recently used of a few sampled rows when full.
  @moduledoc false

  alias ImagePipe.Cache.RecentTable

  @limit 64
  @max_bytes 1_048_576

  @spec get(atom(), String.t(), term()) :: binary() | nil
  def get(table, hash, identity), do: RecentTable.get(table, {hash, identity})

  @spec put(atom(), String.t(), term(), binary()) :: :ok
  def put(table, hash, identity, bytes) when byte_size(bytes) <= @max_bytes,
    do: RecentTable.put(table, {hash, identity}, bytes, @limit)

  def put(_table, _hash, _identity, _bytes), do: :ok
end
