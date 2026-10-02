defmodule ImagePipe.Execution.Watermarks do
  @moduledoc false
  # Watermark assets are additional request inputs. Each distinct asset
  # resolves through the configured source mounts and, for remote sources, the
  # input cache, exactly like the main source. Assets are acquired in tasks
  # that run while the caller acquires the main source.
  #
  # `prepare_async/3` establishes byte identity before the conditional gate:
  # it reuses a fresh input-cache record, or fetches (revalidating a stale
  # record). `open_async/2` reads the bytes of assets that prepare did not
  # fetch, after an output-cache miss. Both read whole bodies into memory and
  # release their input leases before returning.

  alias ImagePipe.Execution.SourceCache
  alias ImagePipe.Execution.Watermark
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial
  alias ImagePipe.Source
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  @type planned :: %{asset: term(), source: ImagePipe.Plan.Source.t(), opacity: float()}

  @doc """
  Translates each distinct watermark asset of `request` into a plan source.
  Named assets were validated against the host configuration while parsing.
  """
  @spec plan(Spec.t(), keyword()) :: {:ok, [planned()]} | {:error, term()}
  def plan(%Spec{groups: groups}, config) do
    groups
    |> Enum.flat_map(fn
      %{watermark: %{asset: asset}} -> [asset]
      _group -> []
    end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn asset, {:ok, planned} ->
      case plan_asset(asset, config) do
        {:ok, entry} -> {:cont, {:ok, [entry | planned]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      error -> error
    end
  end

  defp plan_asset({:name, name} = asset, config) do
    %{source: source, opacity: opacity} =
      config |> Keyword.fetch!(:watermarks) |> Map.fetch!(name)

    {:ok, %{asset: asset, source: source, opacity: opacity}}
  end

  defp plan_asset({:src, source} = asset, config) do
    with {:ok, plan_source} <- Source.Parser.translate(source, config) do
      {:ok, %{asset: asset, source: plan_source, opacity: 1.0}}
    end
  end

  def prepare_async(planned, %IdentityMaterial{} = material, config),
    do: Enum.map(planned, &start(:prepare, fn -> prepare(&1, material, config) end, config))

  def open_async(watermarks, config) do
    Enum.map(watermarks, fn
      %Watermark{bytes: nil} = watermark ->
        start(:open, fn -> open(watermark, config) end, config)

      watermark ->
        {:done, watermark}
    end)
  end

  @doc """
  Defers reading to the process that will consume the assets. The returned
  function starts the reads in the calling process and returns functions that
  await them as executor inputs and cancel them.
  """
  def deferred(watermarks, config), do: fn -> start_deferred(watermarks, config) end

  defp start_deferred(watermarks, config) do
    tasks = open_async(watermarks, config)
    {fn -> await_inputs(tasks) end, fn -> cancel(tasks) end}
  end

  defp await_inputs(tasks) do
    with {:ok, watermarks} <- await(tasks), do: {:ok, inputs(watermarks)}
  end

  @doc "Awaits every task in order; the first failure cancels the rest."
  def await(tasks) do
    Enum.reduce(tasks, {:ok, []}, fn
      task, {:ok, done} ->
        case await_task(task) do
          {:ok, watermark} -> {:ok, [watermark | done]}
          {:error, _reason} = error -> error
        end

      task, error ->
        cancel_task(task)
        error
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  def cancel(tasks), do: Enum.each(tasks, &cancel_task/1)

  @doc "Asset inputs keyed by asset reference, as the executor consumes them."
  def inputs(watermarks),
    do: Map.new(watermarks, &{&1.asset, %{bytes: &1.bytes, opacity: &1.opacity}})

  @doc "Byte identity across the main source and every asset."
  def byte_identity(main, []), do: main

  def byte_identity(main, watermarks) do
    identities = [main | Enum.map(watermarks, &Watermark.byte_identity/1)]

    case Enum.all?(identities, &match?({:strong, _seed}, &1)) do
      true -> {:strong, Enum.map(identities, fn {:strong, seed} -> seed end)}
      false -> :none
    end
  end

  defp start(phase, fun, config) do
    request_context = RequestContext.capture()
    telemetry = Telemetry.telemetry_opts(config)

    Task.Supervisor.async_nolink(ImagePipe.ProcessingPool.Tasks, fn ->
      RequestContext.adopt(request_context)

      Telemetry.span(telemetry, [:source, :watermark], %{phase: phase}, fn ->
        result = fun.()
        {result, stop_metadata(result)}
      end)
    end)
  end

  defp stop_metadata({:ok, %Watermark{}}), do: %{result: :ok}

  defp stop_metadata({:error, _reason} = error), do: %{result: Telemetry.request_result(error)}

  defp await_task({:done, watermark}), do: {:ok, watermark}

  defp await_task(%Task{} = task) do
    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
    end
  end

  defp cancel_task({:done, _watermark}), do: :ok
  defp cancel_task(%Task{} = task), do: Task.shutdown(task, :brutal_kill)

  defp prepare(%{asset: asset, source: plan_source, opacity: opacity}, material, config) do
    with {:ok, source} <- Source.resolve(plan_source, config, Source.runtime_opts(config)) do
      watermark = %Watermark{asset: asset, source: source, opacity: opacity}

      case SourceCache.staged?(source) do
        true -> prepare_cached(watermark, material, config)
        false -> {:ok, watermark}
      end
    end
  end

  defp prepare_cached(watermark, material, config) do
    with {:ok, source, fetch_context} <- Source.prepare_cache_context(watermark.source, config) do
      key = Representation.input_key(source.identity, material, fetch_context)
      watermark = %{watermark | source: source, input_key: key}

      record =
        SourceCache.immutable_record(source, config) || SourceCache.lookup(source, key, config)

      case SourceCache.status(record, source, config) do
        :fresh -> {:ok, %{watermark | record: record}}
        _validate -> acquire(watermark, record, config)
      end
    end
  end

  # No preparation: the overlapped decode belongs to the main source.
  defp acquire(watermark, record, config) do
    with {:ok, acquisition} <-
           SourceCache.acquire(watermark.source, watermark.input_key, record, nil, config) do
      watermark = %{watermark | record: acquisition.record}

      case acquisition.response do
        nil -> {:ok, watermark}
        response -> leased_bytes(watermark, response, acquisition.lease, config)
      end
    end
  end

  defp open(%Watermark{input_key: nil} = watermark, config) do
    Source.with_fetched(watermark.source, config, fn response ->
      with {:ok, bytes} <- read(response, config), do: {:ok, %{watermark | bytes: bytes}}
    end)
  end

  defp open(watermark, config) do
    with {:ok, acquisition} <-
           SourceCache.input(watermark.source, watermark.input_key, watermark.record, nil, config) do
      leased_bytes(watermark, acquisition.response, acquisition.lease, config)
    end
  end

  defp leased_bytes(watermark, response, lease, config) do
    with {:ok, bytes} <- read(response, config), do: {:ok, %{watermark | bytes: bytes}}
  after
    SourceCache.release(lease)
  end

  defp read(%Response{path: path}, config) when is_binary(path) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{size: size}} when size > limit -> {:error, {:source, :body_too_large}}
      {:ok, _stat} -> path |> File.read() |> read_result()
      {:error, _reason} -> {:error, {:source, :invalid_body}}
    end
  end

  defp read(%Response{stream: stream}, config) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    {chunks, _size} =
      Source.reduce_body(stream, {[], 0}, fn bytes, {chunks, size} ->
        size = size + byte_size(bytes)
        if size > limit, do: raise(StreamError, reason: :body_too_large)
        {[bytes | chunks], size}
      end)

    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  rescue
    exception in StreamError -> {:error, {:source, exception.reason}}
  end

  defp read_result({:ok, bytes}), do: {:ok, bytes}
  defp read_result({:error, _reason}), do: {:error, {:source, :invalid_body}}
end
