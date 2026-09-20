defmodule ImagePipe.RunTest.OwnedSource do
  @moduledoc false
  @behaviour ImagePipe.Source

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
       adapter: :path,
       source_kind: :path,
       identity: [kind: :test],
       internal_cache: :disabled,
       http_cache: :disabled,
       cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
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
