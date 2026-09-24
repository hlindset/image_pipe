defmodule ImagePipe.Cache.Input do
  @moduledoc "Coordinates source-state adapters and optional original-byte storage."
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Input.{Adapter, Output, Snapshot}
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Source.Record
  alias ImagePipe.Telemetry

  def validate_config(opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        {:ok, opts}

      {adapter, pool} when is_atom(adapter) and is_list(pool) ->
        with true <- Keyword.keyword?(pool),
             :ok <- validate_adapter(adapter),
             {:ok, pool} <- validate_options(adapter, pool),
             :ok <- separate_roots(adapter, pool, Keyword.get(opts, :cache)) do
          {:ok, Keyword.put(opts, :input_cache, {adapter, pool})}
        else
          false -> {:error, :invalid_input_cache}
          {:error, _} = error -> error
        end

      _invalid ->
        {:error, :invalid_input_cache}
    end
  end

  defp validate_options(adapter, pool) do
    case adapter.validate_input_options(pool) do
      {:ok, opts} when is_list(opts) ->
        case Keyword.keyword?(opts) do
          true -> {:ok, opts}
          false -> {:error, :invalid_input_cache_options}
        end

      {:error, _} = error ->
        error

      _invalid ->
        {:error, :invalid_input_cache_options}
    end
  end

  defp validate_adapter(adapter) do
    with {:module, _} <- Code.ensure_loaded(adapter),
         true <-
           Enum.all?(Adapter.behaviour_info(:callbacks), fn {name, arity} ->
             function_exported?(adapter, name, arity)
           end) do
      :ok
    else
      _invalid -> {:error, :invalid_input_cache_adapter}
    end
  end

  defp separate_roots(FileSystem, input, {FileSystem, output}) do
    case Keyword.fetch!(input, :root) == Path.expand(Keyword.fetch!(output, :root)) do
      true -> {:error, :cache_pools_require_separate_roots}
      false -> :ok
    end
  end

  defp separate_roots(_adapter, _input, _output), do: :ok

  def lookup(key, opts) do
    case owner(opts) do
      nil ->
        nil

      {adapter, pool} ->
        validated_snapshot(adapter.lookup_source(key, pool))
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp validated_snapshot(
         {:hit, %Snapshot{revision: revision, record: record, age_margin: margin} = snapshot}
       )
       when not is_nil(revision) and is_integer(margin) and margin >= 0 do
    if is_nil(record) or Record.valid?(record), do: snapshot
  end

  defp validated_snapshot(_miss), do: nil

  def acquire(key, opts) do
    case owner(opts) do
      nil ->
        :bypass

      {adapter, pool} ->
        case adapter.acquire_source(key, pool) do
          {:ok, lease, outcome} when outcome in [:acquired, :coalesced] ->
            coordination(outcome, opts)
            {:ok, {adapter, lease, pool}}

          _unavailable ->
            coordination(:busy, opts)
            :bypass
        end
    end
  rescue
    _exception -> :bypass
  catch
    :exit, _reason -> :bypass
  end

  def release_source({adapter, lease, pool}) do
    adapter.release_source(lease, pool)
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp coordination(outcome, opts) do
    Telemetry.execute(Telemetry.telemetry_opts(opts), [:cache, :coordination], %{}, %{
      pool: :input,
      result: outcome,
      operation: :source
    })
  end

  def publish(key, {adapter, lease, pool}, record, path, cost, opts) do
    path = if Keyword.has_key?(opts, :input_cache), do: path

    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{pool: :input}, fn ->
      result = publish_adapter(adapter, key, lease, record, path, cost, pool)
      {result, write_metadata(result)}
    end)
  end

  defp publish_adapter(adapter, key, lease, record, path, cost, pool) do
    case adapter.publish_source(key, lease, record, path, cost, pool) do
      {:ok, %Snapshot{revision: revision, record: ^record, age_margin: margin}} = result
      when not is_nil(revision) and is_integer(margin) and margin >= 0 ->
        result

      {:error, _} = error ->
        error

      _invalid ->
        {:error, :invalid_adapter_result}
    end
  rescue
    _exception -> {:error, :cache_write_failed}
  catch
    :exit, _reason -> {:error, :cache_write_failed}
  end

  defp write_metadata({:ok, %Snapshot{}}), do: %{result: :ok, cache: :write}
  defp write_metadata(_error), do: %{result: :cache_error, cache: :write_error}

  def invalidate(_key, nil, _opts), do: :ok

  def invalidate(key, revision, opts) do
    case owner(opts) do
      nil -> :ok
      {adapter, pool} -> adapter.invalidate_source(key, revision, pool)
    end
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  def open(key, record, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :input], %{pool: :input}, fn ->
      key |> do_open(record, opts) |> open_result()
    end)
  end

  defp do_open(key, record, opts) do
    case Keyword.get(opts, :input_cache) do
      nil ->
        :miss

      {adapter, pool} ->
        case adapter.open_input(key, record, pool) do
          {:ok, path, handle} when is_binary(path) -> {:ok, path, {:input, adapter, handle, pool}}
          :miss -> :miss
          _error -> {:error, :cache_read_failed}
        end
    end
  rescue
    _exception -> {:error, :cache_read_failed}
  catch
    :exit, _reason -> {:error, :cache_read_failed}
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

  def release({:input, adapter, handle, pool}) do
    adapter.release_input(handle, pool)
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  def release(handle), do: Resources.release(handle)

  def temporary_path(root),
    do:
      Path.join(
        root,
        ".image-pipe-#{Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)}.tmp"
      )

  defp owner(opts) do
    case Keyword.get(opts, :input_cache) do
      nil -> output_owner(Keyword.get(opts, :cache))
      configured -> configured
    end
  end

  defp output_owner(nil), do: nil
  defp output_owner({FileSystem, _pool} = configured), do: configured
  defp output_owner(configured), do: {Output, [cache: configured]}
end
