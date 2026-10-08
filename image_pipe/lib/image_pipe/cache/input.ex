defmodule ImagePipe.Cache.Input do
  # Filesystem original-byte storage using the shared admission pool implementation.
  @moduledoc false
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.FileSystem.Sweep
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

  # Each pool's startup scan walks its whole root, so a root inside the other
  # pool's would adopt and evict that pool's entries.
  defp separate_roots(input, {ImagePipe.Cache.FileSystem, output}) do
    input = input |> Keyword.fetch!(:root) |> Path.split()
    output = output |> Keyword.fetch!(:root) |> Path.expand() |> Path.split()

    case List.starts_with?(input, output) or List.starts_with?(output, input) do
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
    pinned = Path.join(Path.dirname(path), Sweep.pin_name(random()))
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

  def temporary_path(root), do: Path.join(root, ".image-pipe-#{random()}.tmp")

  # Staged originals live in their own directory, so the startup sweep lists
  # only them, not the whole tmp directory.
  def staging_dir, do: Path.join(System.tmp_dir!(), "image_pipe")

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # `sha256` is the digest of the bytes at `path`, computed while staging them.
  def put(key, path, sha256, record, cost, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        :ok

      {_adapter, pool} ->
        Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{pool: :input}, fn ->
          result = store(key, path, sha256, record, cost, pool)

          {result, write_metadata(result)}
        end)
    end
  rescue
    _exception -> :ok
  end

  defp write_metadata({:error, _reason}), do: %{result: :cache_error, cache: :write_error}
  defp write_metadata({:ok, :rejected}), do: %{result: :ok, cache: :stage_skipped}
  defp write_metadata(:ok), do: %{result: :ok, cache: :write}

  # A staged file on the pool's filesystem is linked into place, not re-read
  # and rehashed. Elsewhere, its bytes are copied.
  defp store(key, path, sha256, record, cost, pool) do
    metadata = %{source_record: record, cost_us: cost}

    case Store.open_linked_sink(key, metadata, path, sha256, pool) do
      {:ok, sink} -> Store.commit_sink(sink, pool)
      {:error, _reason} -> copy(key, metadata, path, pool)
    end
  end

  defp copy(key, metadata, path, pool) do
    case Store.open_sink(key, metadata, pool) do
      {:ok, sink} -> write(sink, path, pool)
      {:error, reason} -> {:error, reason}
    end
  end

  # A committed sink belongs to the store, so only an unfinished one is aborted.
  defp write(sink, path, pool) do
    case write_body(sink, path, pool) do
      {:ok, state} ->
        Store.commit_sink(state, pool)

      {:error, reason, state} ->
        Store.abort_sink(state, pool)
        {:error, reason}
    end
  end

  defp write_body(sink, path, pool) do
    Enum.reduce_while(File.stream!(path, 65_536), {:ok, sink}, fn chunk, {:ok, state} ->
      case Store.write_chunk(state, chunk, pool) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason, state} -> {:halt, {:error, reason, state}}
      end
    end)
  rescue
    exception in File.Error -> {:error, exception.reason, sink}
  end

  def verify(key, opts) do
    case Keyword.get(opts, :input_cache) do
      nil -> :miss
      {_adapter, pool} -> Store.verify(key, pool)
    end
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
          %Record{byte_identity: identity} = previous when identity == record.byte_identity ->
            Store.refresh_source_record(key, previous, record, pool)

          _missing ->
            :ok
        end
    end
  end
end
