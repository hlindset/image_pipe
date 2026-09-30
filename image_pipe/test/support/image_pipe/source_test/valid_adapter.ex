defmodule ImagePipe.SourceTest.ValidAdapter do
  @moduledoc false

  @behaviour ImagePipe.Source

  @impl ImagePipe.Source
  def validate_options(opts), do: {:ok, opts}

  @impl ImagePipe.Source
  def resolve(source, opts, runtime_opts) do
    send(self(), {:source_resolve, source})
    send(self(), {:source_resolve_runtime_opts, runtime_opts})

    {:ok,
     %ImagePipe.Source.Resolved{
       adapter: Keyword.get(opts, :adapter, :path),
       source_kind: :path,
       identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
       internal_cache: Keyword.get(opts, :internal_cache, :enabled),
       http_cache: Keyword.get(opts, :http_cache, :inherit),
       cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false},
       fetch: {:fixture, self()}
     }}
  end

  @impl ImagePipe.Source
  def fetch(%ImagePipe.Source.Resolved{fetch: {:fixture, receiver}}, _opts, runtime_opts) do
    send(receiver, {:source_fetch, :fixture})
    send(receiver, {:source_fetch_runtime_opts, runtime_opts})
    {:ok, %ImagePipe.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end

  def fetch(resolved, _opts, runtime_opts) do
    target = message_target()

    send(target, {:source_fetch, resolved.fetch})
    send(target, {:source_fetch_runtime_opts, runtime_opts})
    {:ok, %ImagePipe.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
