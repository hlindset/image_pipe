defmodule ImagePipe.SourceTest.PlugCustomAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.Source]

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @behaviour Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(source, opts, _runtime_opts) do
    send(self(), {:source_order, :resolve})
    send(self(), {:custom_resolve, source})

    {:ok,
     %Resolved{
       adapter: Keyword.fetch!(opts, :adapter),
       source_kind: :object,
       identity: [
         kind: :object,
         adapter: Keyword.fetch!(opts, :adapter),
         scope: "custom",
         key: "cat.jpg"
       ],
       internal_cache: Keyword.get(opts, :internal_cache, :enabled),
       http_cache: Keyword.get(opts, :http_cache, :inherit),
       cache_semantics: %CacheSemantics{
         byte_identity: if(opts[:stable], do: {:strong, :cat}, else: :none),
         stable?: Keyword.get(opts, :stable, false)
       },
       fetch: :cat
     }}
  end

  @impl true
  def fetch(%Resolved{} = resolved, _opts, _runtime_opts) do
    target = message_target()

    send(target, {:source_order, :fetch})
    send(target, {:custom_fetch, resolved.fetch})
    {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
