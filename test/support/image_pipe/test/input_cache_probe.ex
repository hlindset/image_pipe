defmodule ImagePipe.Test.InputCacheProbe do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.Cache]

  alias ImagePipe.Cache.FileSystem

  @behaviour ImagePipe.Cache.Input.Adapter

  @impl true
  def validate_input_options(opts) do
    with {:ok, pool} <- FileSystem.validate_options(Keyword.delete(opts, :owner)) do
      {:ok, Keyword.put(pool, :owner, Keyword.fetch!(opts, :owner))}
    end
  end

  @impl true
  def lookup_source(key, opts), do: invoke(:lookup_source, [key], opts)
  @impl true
  def acquire_source(key, opts), do: invoke(:acquire_source, [key], opts)
  @impl true
  def release_source(lease, opts), do: invoke(:release_source, [lease], opts)

  @impl true
  def publish_source(key, lease, record, path, cost, opts),
    do: invoke(:publish_source, [key, lease, record, path, cost], opts)

  @impl true
  def invalidate_source(key, revision, opts),
    do: invoke(:invalidate_source, [key, revision], opts)

  @impl true
  def open_input(key, record, opts), do: invoke(:open_input, [key, record], opts)
  @impl true
  def release_input(handle, opts), do: invoke(:release_input, [handle], opts)

  defp invoke(operation, args, opts) do
    send(Keyword.fetch!(opts, :owner), {:input_adapter, operation})
    apply(FileSystem, operation, args ++ [Keyword.delete(opts, :owner)])
  end
end
