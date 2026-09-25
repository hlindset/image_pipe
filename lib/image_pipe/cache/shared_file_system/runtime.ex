defmodule ImagePipe.Cache.SharedFileSystem.Runtime do
  @moduledoc false
  use Supervisor

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  alias ImagePipe.Cache.SharedFileSystem.{
    InventoryWorker,
    Lifecycle,
    Locations,
    Retainer,
    Sources
  }

  @schema NimbleOptions.new!(
            name: [type: :atom, required: true],
            root: [type: :string, required: true],
            local_root: [type: :string, required: true],
            timeout: [type: :pos_integer, default: 1_000],
            heartbeat_interval: [type: :pos_integer, default: 5_000],
            max_body_bytes: [type: :pos_integer, default: 32 * 1024 * 1024],
            max_metadata_bytes: [type: :pos_integer, default: 65_536],
            max_attempts: [type: :pos_integer, default: 16],
            max_retained_bytes: [type: :pos_integer, default: 128 * 1024 * 1024],
            max_retained_entries: [type: :pos_integer, default: 4_096],
            root_max_bytes: [type: {:or, [nil, :pos_integer]}, default: nil],
            root_low_watermark: [type: :float, default: 0.8],
            usage_max_partitions: [type: :pos_integer, default: 128],
            inventory_interval: [type: :pos_integer, default: 60_000],
            inventory_max_entries: [type: :pos_integer, default: 128],
            inventory_max_bytes: [type: :pos_integer, default: 65_536],
            warmup_max_partitions: [type: :pos_integer, default: 32],
            warmup_max_candidates: [type: :pos_integer, default: 128],
            warmup_timeout: [type: :pos_integer, default: 1_000],
            clock_skew: [type: :non_neg_integer, default: 5],
            clock: [type: {:fun, 0}, default: &Sources.Supervisor.now/0]
          )

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    if opts[:root_low_watermark] <= 0.0 or opts[:root_low_watermark] >= 1.0,
      do: raise(ArgumentError, "root_low_watermark must be between zero and one")

    opts =
      opts
      |> Keyword.update!(:root, &Path.expand/1)
      |> Keyword.update!(:local_root, &Path.expand/1)

    if opts[:local_root] == opts[:root] or
         String.starts_with?(opts[:local_root], opts[:root] <> "/"),
       do: raise(ArgumentError, "local_root must be outside the shared cache root")

    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }

  # Each read resolves fresh worker handles without entering a process mailbox.
  def context(name) do
    case :ets.lookup(name, :state) do
      [{:state, {:ready, partition}}] ->
        {:ok,
         Map.new(
           [:pool, :locations, :sources, :retainer, :readers, :limits, :max_attempts, :timeout],
           fn key ->
             [{^key, value}] = :ets.lookup(name, key)
             {key, value}
           end
         )
         |> Map.put(:partition, partition)}

      _unavailable ->
        {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    table = :ets.new(opts[:name], [:named_table, :set, :public, read_concurrency: true])
    incarnation = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    readers = Path.join(opts[:local_root], incarnation)
    limits = %{body: opts[:max_body_bytes], metadata: opts[:max_metadata_bytes]}

    :ets.insert(table, [
      {:state, :starting},
      {:readers, readers},
      {:limits, limits},
      {:max_attempts, opts[:max_attempts]},
      {:timeout, opts[:timeout]}
    ])

    children = [
      %{id: CacheIO, start: {__MODULE__, :start_io, [table, opts]}, restart: :temporary},
      %{id: Task.Supervisor, start: {__MODULE__, :start_tasks, [table]}, type: :supervisor},
      %{
        id: Sources.Supervisor,
        start: {__MODULE__, :start_sources, [table, opts]},
        type: :supervisor,
        restart: :temporary
      },
      %{id: Locations, start: {__MODULE__, :start_locations, [table, opts]}},
      %{id: Retainer, start: {__MODULE__, :start_retainer, [table, opts]}, restart: :temporary},
      %{id: Lifecycle, start: {Lifecycle, :start_link, [table, opts]}},
      %{id: InventoryWorker, start: {InventoryWorker, :start_link, [table, opts]}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def start_io(table, opts) do
    bytes = max(256 * 1024 * 1024, opts[:max_body_bytes] * 4)

    with {:ok, pid} <- CacheIO.start_link(max_resource_bytes: bytes) do
      :ets.insert(table, {:pool, CacheIO.client(pid)})
      {:ok, pid}
    end
  end

  def start_tasks(table) do
    with {:ok, pid} <- Task.Supervisor.start_link() do
      :ets.insert(table, {:tasks, pid})
      {:ok, pid}
    end
  end

  def start_sources(table, opts) do
    with {:ok, pid} <-
           Sources.Supervisor.start_link(clock_skew: opts[:clock_skew], clock: opts[:clock]) do
      :ets.insert(table, {:sources, Sources.client(pid)})
      {:ok, pid}
    end
  end

  def start_locations(table, opts) do
    with {:ok, pid} <-
           Locations.start_link(
             pool: fetch(table, :pool),
             root: opts[:root],
             tasks: fetch(table, :tasks)
           ) do
      :ets.insert(table, {:locations, Locations.client(pid)})
      {:ok, pid}
    end
  end

  def start_retainer(table, opts) do
    with {:ok, pid} <-
           Retainer.start_link(
             pool: fetch(table, :pool),
             tasks: fetch(table, :tasks),
             partition: nil,
             limits: fetch(table, :limits),
             max_bytes: opts[:max_retained_bytes],
             max_entries: opts[:max_retained_entries],
             timeout: opts[:timeout]
           ) do
      :ets.insert(table, {:retainer, Retainer.client(pid)})
      {:ok, pid}
    end
  end

  def fetch(table, key), do: :ets.lookup_element(table, key, 2)
end
