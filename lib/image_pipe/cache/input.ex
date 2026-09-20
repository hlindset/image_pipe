defmodule ImagePipe.Cache.Input do
  @moduledoc "Filesystem original-byte storage using the shared admission pool implementation."
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Source.Record
  alias ImagePipe.Telemetry

  def validate_config(opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        {:ok, opts}

      {ImagePipe.Cache.FileSystem, pool} when is_list(pool) ->
        with {:ok, pool} <- Store.validate_options(pool),
             :ok <- separate_roots(pool, Keyword.get(opts, :cache)) do
          pool = Keyword.put(pool, :pool, :input)
          {:ok, Keyword.put(opts, :input_cache, {ImagePipe.Cache.FileSystem, pool})}
        end

      _invalid ->
        {:error, :invalid_input_cache}
    end
  end

  defp separate_roots(input, {ImagePipe.Cache.FileSystem, output}) do
    case Keyword.fetch!(input, :root) == Path.expand(Keyword.fetch!(output, :root)) do
      true -> {:error, :cache_pools_require_separate_roots}
      false -> :ok
    end
  end

  defp separate_roots(_input, _output), do: :ok

  def metadata(key, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        nil

      {_adapter, pool} ->
        case Store.metadata(key, pool) do
          {:ok, %{source_record: record}} -> valid_record(record)
          _miss -> nil
        end
    end
  rescue
    _exception -> nil
  end

  defp valid_record(record) do
    case Record.valid?(record) do
      true -> record
      false -> nil
    end
  end

  def open(key, record, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :input], %{pool: :input}, fn ->
      key |> do_open(record, opts) |> open_result()
    end)
  end

  defp open_result({:ok, path, _lease} = result) do
    bytes =
      case File.stat(path) do
        {:ok, stat} -> stat.size
        _error -> 0
      end

    {result, %{result: :ok, cache: :hit, bytes: bytes}}
  end

  defp open_result(:miss), do: {:miss, %{result: :ok, cache: :miss}}
  defp open_result({:error, _reason}), do: {:miss, %{result: :cache_error, cache: :read_error}}

  defp do_open(key, record, opts) do
    case Keyword.get(opts, :input_cache) do
      nil -> :miss
      {_adapter, pool} -> open_pool(key, record, pool)
    end
  rescue
    _exception -> {:error, :cache_read_failed}
  end

  defp open_pool(key, record, pool) do
    case Store.get(key, pool) do
      {:hit, file, %{source_record: stored}} ->
        pin_matching(file, stored, record)

      {:hit, file, _invalid} ->
        CacheFile.close(file)
        {:error, :invalid_metadata}

      {:error, reason} ->
        {:error, reason}

      _miss ->
        :miss
    end
  end

  defp pin_matching(file, stored, record) do
    case Record.valid?(stored) and stored.byte_identity == record.byte_identity do
      true -> pin(file.path)
      false -> :miss
    end
  after
    CacheFile.close(file)
  end

  defp pin(path) do
    pinned = temporary_path(Path.dirname(path))
    ref = Resources.track(pinned)
    pin(path, pinned, ref)
  end

  defp pin(_path, _pinned, :unavailable), do: :miss

  defp pin(path, pinned, ref) do
    case File.ln(path, pinned) do
      :ok ->
        {:ok, pinned, ref}

      {:error, _reason} ->
        Resources.release(ref)
        :miss
    end
  end

  def temporary_path(root) do
    Path.join(
      root,
      ".image-pipe-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.tmp"
    )
  end

  def put(key, path, record, cost, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        :ok

      {_adapter, pool} ->
        Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{pool: :input}, fn ->
          result = store(key, path, record, cost, pool)

          {result, write_metadata(result)}
        end)
    end
  rescue
    _exception -> :ok
  end

  defp write_metadata({:error, _reason}), do: %{result: :cache_error, cache: :write_error}
  defp write_metadata({:ok, :rejected}), do: %{result: :ok, cache: :stage_skipped}
  defp write_metadata(:ok), do: %{result: :ok, cache: :write}

  defp store(key, path, record, cost, pool) do
    case Store.open_sink(key, %{source_record: record, cost_us: cost}, pool) do
      {:ok, sink} -> write(sink, path, pool)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(sink, path, pool) do
    result =
      Enum.reduce_while(File.stream!(path, 65_536), {:ok, sink}, fn chunk, {:ok, state} ->
        case Store.write_chunk(state, chunk, pool) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, reason, state} -> {:halt, {:error, reason, state}}
        end
      end)

    case result do
      {:ok, state} ->
        Store.commit_sink(state, pool)

      {:error, reason, state} ->
        Store.abort_sink(state, pool)
        {:error, reason}
    end
  after
    Store.abort_sink(sink, pool)
  end

  def discard(key, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        :ok

      {_adapter, pool} ->
        Store.delete(key, pool)
    end
  end

  def refresh(key, record, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        :ok

      {_adapter, pool} ->
        case metadata(key, opts) do
          %Record{byte_identity: identity} when identity == record.byte_identity ->
            Store.update_metadata(key, %{source_record: record}, pool)

          _missing ->
            :ok
        end
    end
  end
end
