defmodule ImagePipe.Test.ProcessingSource do
  @moduledoc false
  @behaviour ImagePipe.Source

  @impl true
  def identifiers(_options),
    do: [ImagePipe.Source.Path, ImagePipe.Source.URL, ImagePipe.Source.Object]

  alias ImagePipe.Source.{CacheSemantics, Resolved, Response}

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def resolve(source, options, _runtime) do
    {:ok,
     %Resolved{
       identity: [path: source.segments],
       internal_cache: Keyword.get(options, :internal_cache, :enabled),
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{
         byte_identity: {:strong, source.segments},
         stable?: true,
         copy?: Keyword.get(options, :copy?, false)
       },
       fetch: fetch_spec(source.segments, options)
     }}
  end

  # A `fetch_timeout` option gives the source a download deadline, which only
  # a keyword list fetch carries.
  defp fetch_spec(segments, options) do
    case Keyword.fetch(options, :fetch_timeout) do
      {:ok, timeout} -> [segments: segments, options: options, fetch_timeout: timeout]
      :error -> {segments, options}
    end
  end

  @impl true
  def fetch(%Resolved{fetch: fetch}, _opts, _runtime) do
    {segments, options} =
      case fetch do
        {segments, options} -> {segments, options}
        list -> {list[:segments], list[:options]}
      end

    test = Keyword.fetch!(options, :test)
    send(test, {:fetch, segments, self()})

    if "blocked" in segments do
      receive do
        :continue -> :ok
      end
    end

    cond do
      "failing" in segments -> {:error, {:source, :not_found}}
      "raising" in segments -> raise "source failed"
      true -> {:ok, response(segments, options, test)}
    end
  end

  defp response(segments, options, test) do
    %Response{
      stream: Keyword.get(options, :stream, [Keyword.fetch!(options, :bytes)]),
      origin: Keyword.get(options, :origin),
      close: fn -> send(test, {:closed, segments}) end
    }
  end
end
