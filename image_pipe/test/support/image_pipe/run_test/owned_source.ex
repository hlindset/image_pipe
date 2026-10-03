defmodule ImagePipe.RunTest.OwnedSource do
  @moduledoc false
  @behaviour ImagePipe.Source

  @impl true
  def source_kinds, do: [:path, :url, :object]

  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.SourceTest.StreamWithCleanup

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def resolve(_source, options, _runtime) do
    send(Keyword.fetch!(options, :pid), :source_resolved)

    {:ok,
     %Resolved{
       source_kind: :path,
       identity: [kind: :test],
       internal_cache: :disabled,
       http_cache: :validators,
       cache_semantics: %CacheSemantics{byte_identity: :content, stable?: false},
       fetch: nil
     }}
  end

  @impl true
  def fetch(_source, options, _runtime) do
    pid = Keyword.fetch!(options, :pid)
    send(pid, :source_fetched)
    stream = StreamWithCleanup.stream(pid, [Keyword.fetch!(options, :bytes)])

    {:ok,
     %Response{
       stream: stream,
       close: fn ->
         send(pid, :source_closed)
         :ok
       end
     }}
  end
end
