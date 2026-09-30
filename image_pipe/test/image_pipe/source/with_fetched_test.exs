defmodule ImagePipe.Source.WithFetchedTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.SourceTest.StreamWithCleanup

  defmodule BufferAdapter do
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("not used")

    @impl ImagePipe.Source
    def fetch(%Resolved{fetch: body}, _opts, _runtime_opts) when is_binary(body) do
      {:ok, %Response{stream: [body]}}
    end
  end

  defmodule FailingFetchAdapter do
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("not used")

    @impl ImagePipe.Source
    def fetch(%Resolved{}, _opts, _runtime_opts), do: {:error, {:source, :connect_error}}
  end

  defmodule CleanupStreamAdapter do
    @moduledoc false
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("not used")

    @impl ImagePipe.Source
    def fetch(%Resolved{fetch: {test_pid, chunks}}, _opts, _runtime_opts) do
      {:ok, %Response{stream: StreamWithCleanup.stream(test_pid, chunks)}}
    end
  end

  defp resolved(adapter, fetch) do
    %Resolved{
      adapter: adapter,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
      fetch: fetch
    }
  end

  defp opts(adapter, module) do
    [sources: %{adapter => {module, []}}, max_body_bytes: 10_000_000]
  end

  test "invokes fun with the fetched response and returns fun's result unchanged" do
    body = File.read!("priv/static/images/beach.jpg")
    resolved = resolved(:buffer, body)

    result =
      Source.with_fetched(resolved, opts(:buffer, BufferAdapter), fn %Response{} = response ->
        drained = response.stream |> Enum.to_list() |> IO.iodata_to_binary()
        {:ok, byte_size(drained)}
      end)

    assert result == {:ok, byte_size(body)}
  end

  test "fun's own error return passes through unchanged, not reclassified as a source error" do
    resolved = resolved(:buffer, "not a real image")

    result =
      Source.with_fetched(resolved, opts(:buffer, BufferAdapter), fn %Response{} ->
        {:error, {:transform, :some_downstream_reason}}
      end)

    assert result == {:error, {:transform, :some_downstream_reason}}
  end

  test "a fetch failure short-circuits: fun is never invoked, error is normalized {:source, _}" do
    resolved = resolved(:failing, nil)

    result =
      Source.with_fetched(resolved, opts(:failing, FailingFetchAdapter), fn %Response{} ->
        flunk("fun must not be called when fetch/3 itself fails")
      end)

    assert result == {:error, {:source, :connect_error}}
  end

  test "no leaked stream: cleanup runs even when fun raises after partially draining the stream" do
    resolved = resolved(:cleanup, {self(), ["123", "456"]})

    assert_raise RuntimeError, "boom", fn ->
      Source.with_fetched(resolved, opts(:cleanup, CleanupStreamAdapter), fn %Response{} =
                                                                               response ->
        assert Enum.take(response.stream, 1) == ["123"]
        raise "boom"
      end)
    end

    assert_receive :stream_closed
  end

  test "an untouched stream never opens its resource, so there is nothing to leak" do
    resolved = resolved(:cleanup, {self(), ["123", "456"]})

    result =
      Source.with_fetched(resolved, opts(:cleanup, CleanupStreamAdapter), fn %Response{} ->
        :never_touched
      end)

    assert result == :never_touched
    refute_received :stream_closed
  end
end
