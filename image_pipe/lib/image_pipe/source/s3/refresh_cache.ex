defmodule ImagePipe.Source.S3.RefreshCache do
  @moduledoc false
  # Generic, value-agnostic refresh cache.
  #
  # `warm(key, fetch_fun)` starts an entry ahead of its first use.
  # `fetch(key, fetch_fun)` returns `{:ok, value}` or `{:error, reason}`, starting
  # a per-key `Entry` process on first use (registered in `@registry`, supervised
  # by `@supervisor`). The cache itself never interprets `value` — credential
  # specifics live in `ImagePipe.Source.S3.Credentials`.
  #
  # The `child_spec/1` returned here starts the Registry + DynamicSupervisor pair;
  # `ImagePipe.Application` lists this module as a single child.
  use Supervisor

  alias ImagePipe.Source.S3.RefreshCache.Entry

  @registry __MODULE__.Registry
  @supervisor __MODULE__.DynamicSupervisor
  @default_call_timeout 10_000

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @spec fetch(term(), (-> {:ok, term(), term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def fetch(key, fetch_fun) when is_function(fetch_fun, 0) do
    case fetch_entry(key, fetch_fun) do
      {:error, :retired} -> fetch_entry(key, fetch_fun)
      result -> result
    end
  end

  # Starts the entry, which fetches at once, without waiting for the value.
  # The entry isn't retired for being idle before its first fetch/2.
  @spec warm(term(), (-> {:ok, term(), term()} | {:error, term()})) ::
          :ok | {:error, :cache_entry_unavailable}
  def warm(key, fetch_fun) when is_function(fetch_fun, 0) do
    case ensure_entry(key, fetch_fun, warm: true) do
      {:ok, _server} -> :ok
      :error -> {:error, :cache_entry_unavailable}
    end
  end

  defp fetch_entry(key, fetch_fun) do
    case ensure_entry(key, fetch_fun, []) do
      {:ok, server} ->
        Entry.get(server, @default_call_timeout)

      :error ->
        {:error, :cache_entry_unavailable}
    end
  end

  defp ensure_entry(key, fetch_fun, opts) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        entry_opts =
          [key: key, fetch_fun: fetch_fun, name: {:via, Registry, {@registry, key}}] ++ opts

        case DynamicSupervisor.start_child(@supervisor, {Entry, entry_opts}) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          # lost a start race after a crash, or init failed: re-look up once,
          # never raise into the request process (the caller maps :error to
          # {:source, :credentials_unavailable}).
          {:error, _reason} ->
            relookup(key)
        end
    end
  end

  defp relookup(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end
end
