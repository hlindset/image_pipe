# Compares bounded FileSystem admission (W-TinyLFU) with a plain LRU of the
# same byte budget on synthetic traffic. Run from image_pipe/:
#
#   mise exec -- mix run bench/cache_policy.exs
#   mise exec -- mix run bench/cache_policy.exs zipf-0.8 5
#   mise exec -- mix run bench/cache_policy.exs --real shift 5
#
# Optional arguments: one workload and one cache size (% of catalog bytes).
#
# By default W-TinyLFU runs an in-memory model of Admission's queues that
# calls the real Sketch, Doorkeeper and Policy modules, so the full matrix
# takes seconds. `--real` drives the real Admission process through the
# adapter instead, which every commit's datasync makes take minutes per cell.
# Use it to check that the model still matches Admission after a change.
# Real runs store bodies at 1/100 scale; both backends derive sketch,
# doorkeeper and aging options from the unscaled cap with the adapter's
# default formulas.
#
# Each line of output is one JSON result. Hit ratios ignore the first quarter
# of the requests as warm-up. `cost_saved` is the share of true render cost
# served from cache, the quantity the cost-aware score optimises.
defmodule CachePolicyBench do
  alias CachePolicyBench.Model
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key

  @catalog 20_000
  @requests 200_000
  @scale 100
  @workloads ["zipf-0.8", "zipf-1.0", "scan", "shift", "mixed-cost"]
  @cache_percents [1, 5, 20]
  # {name, :lru | overrides of @tinylfu}. Model-only options:
  #
  #   * `admission: {:random, min_frequency, one_in}` admits a candidate that
  #     loses the gate anyway with probability 1/one_in when its frequency is
  #     at least min_frequency. Admission uses {:random, 6, 128}, as Caffeine
  #     does. `:strict` never admits a loser.
  #   * `aging: {:entries, k}` halves the sketch every k × the cache's expected
  #     entry count (cap / mean entry size), as Caffeine does with k = 10,
  #     instead of the adapter's default.
  #   * `gate: :each` admits only a candidate that outscores every victim,
  #     instead of the size-weighted average of the victims.
  @tinylfu %{
    window: 0.01,
    cost: :true_cost,
    admission: {:random, 6, 128},
    aging: :default,
    gate: :average
  }
  @policies [
    {"lru", :lru},
    {"tinylfu", []},
    {"noisy-cost", cost: :noisy_cost},
    {"no-cost", cost: :no_cost},
    {"window-5%", window: 0.05},
    {"window-20%", window: 0.20},
    {"strict", admission: :strict},
    {"random-3/32", admission: {:random, 3, 32}},
    {"aging-10x", aging: {:entries, 10}},
    {"aging-20x", aging: {:entries, 20}},
    {"aging-40x", aging: {:entries, 40}},
    {"aging-10x-strict", aging: {:entries, 10}, admission: :strict},
    {"gate-each", gate: :each}
  ]

  def run(args) do
    {backend, args} =
      case args do
        ["--real" | rest] -> {:real, rest}
        rest -> {:model, rest}
      end

    {workloads, percents} =
      case args do
        [] -> {@workloads, @cache_percents}
        [workload, percent] -> {[workload], [String.to_integer(percent)]}
      end

    for workload <- workloads do
      catalog = catalog(workload)
      requests = requests(workload)
      catalog_bytes = catalog_bytes(catalog)

      mean_entry_bytes = div(catalog_bytes, @catalog)

      for percent <- percents,
          {name, policy} <- @policies,
          policy = options(policy, mean_entry_bytes),
          supported?(backend, policy) do
        {percent, name, policy}
      end
      |> Task.async_stream(
        fn {percent, name, policy} ->
          cap = div(catalog_bytes * percent, 100)
          stats = simulate(backend, policy, requests, catalog, cap)
          Map.merge(stats, %{workload: workload, cache_percent: percent, policy: name})
        end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.each(fn {:ok, result} -> IO.puts(JSON.encode!(result)) end)
    end
  end

  defp options(:lru, _mean_entry_bytes), do: :lru

  defp options(overrides, mean_entry_bytes),
    do: @tinylfu |> Map.merge(Map.new(overrides)) |> Map.put(:mean_entry_bytes, mean_entry_bytes)

  defp supported?(:real, %{admission: {:random, 6, 128}, aging: :default, gate: :average}),
    do: true
  defp supported?(:real, %{}), do: false
  defp supported?(_backend, _policy), do: true

  # -- traffic -----------------------------------------------------------------

  # Key id -> {real size in bytes, true render cost in µs}. Ids from @catalog
  # up are one-off keys. Render cost tracks size (pixels) with a log-normal
  # spread, about 1 µs per byte.
  defp catalog("mixed-cost") do
    seeded_catalog(fn ->
      case :rand.uniform() do
        # Small terminals (info, blurhash, LQIP): tiny bodies, full decode.
        r when r < 0.1 -> {lognormal(1_000, 0.5), lognormal(50_000, 0.5)}
        # Slow encoders (AVIF): similar sizes, several times the work.
        r when r < 0.3 -> sized(lognormal(40_000, 1.0), 8)
        _ -> sized(lognormal(50_000, 1.0), 1)
      end
    end)
  end

  defp catalog(_workload), do: seeded_catalog(fn -> sized(lognormal(50_000, 1.0), 1) end)

  defp seeded_catalog(entry) do
    :rand.seed(:exsss, {1, 2, 3})
    Map.new(0..(@catalog * 2), fn id -> {id, entry.()} end)
  end

  defp sized(size, cost_per_byte), do: {size, lognormal(size * cost_per_byte, 0.5)}

  defp lognormal(median, sigma), do: max(round(median * :math.exp(:rand.normal() * sigma)), 300)

  defp catalog_bytes(catalog) do
    Enum.reduce(0..(@catalog - 1), 0, fn id, acc -> acc + elem(Map.fetch!(catalog, id), 0) end)
  end

  defp requests("zipf-" <> alpha), do: seeded(alpha |> String.to_float() |> cdf(), &zipf/2)
  defp requests("mixed-cost"), do: seeded(cdf(0.8), &zipf/2)

  # 30% of requests are one-off keys, as from a crawler or cache-busting sweep.
  defp requests("scan") do
    seeded(cdf(0.8), fn cdf, n ->
      if :rand.uniform() < 0.3, do: {:once, n}, else: sample(cdf)
    end)
  end

  # Halfway through, a different set of keys becomes popular.
  defp requests("shift") do
    seeded(cdf(0.8), fn cdf, n ->
      rank = sample(cdf)
      if n <= div(@requests, 2), do: rank, else: rem(rank + div(@catalog, 2), @catalog)
    end)
  end

  defp zipf(cdf, _n), do: sample(cdf)

  defp seeded(cdf, request) do
    :rand.seed(:exsss, {4, 5, 6})
    Enum.map(1..@requests, &request.(cdf, &1))
  end

  defp cdf(alpha) do
    weights = for rank <- 1..@catalog, do: 1 / :math.pow(rank, alpha)
    total = Enum.sum(weights)

    weights
    |> Enum.scan(&(&1 + &2))
    |> Enum.map(&(&1 / total))
    |> List.to_tuple()
  end

  # Ranks are shuffled into ids so popularity doesn't follow id order.
  defp sample(cdf), do: permute(search(cdf, :rand.uniform(), 0, tuple_size(cdf) - 1))

  defp search(_cdf, _u, low, high) when low >= high, do: low

  defp search(cdf, u, low, high) do
    mid = div(low + high, 2)
    if elem(cdf, mid) < u, do: search(cdf, u, mid + 1, high), else: search(cdf, u, low, mid)
  end

  defp permute(rank), do: rem(rank * 7_919, @catalog)

  defp attributes(catalog, {:once, n}), do: Map.fetch!(catalog, @catalog + rem(n, @catalog))
  defp attributes(catalog, id), do: Map.fetch!(catalog, id)

  # -- measurement ---------------------------------------------------------------

  defp simulate(backend, policy, requests, catalog, cap) do
    :rand.seed(:exsss, {7, 8, 9})
    warmup = div(length(requests), 4)
    {state, step} = start(backend, policy, cap)
    zero = %{requests: 0, hits: 0, bytes: 0, hit_bytes: 0, cost: 0, hit_cost: 0}

    {state, totals} =
      requests
      |> Enum.with_index()
      |> Enum.reduce({state, zero}, fn {request, index}, {state, totals} ->
        {size, cost} = attributes(catalog, request)
        {hit?, state} = step.(state, request, size, cost)
        if index < warmup, do: {state, totals}, else: {state, count(totals, hit?, size, cost)}
      end)

    stop(state)

    %{
      hit_ratio: Float.round(totals.hits / totals.requests, 4),
      byte_hit_ratio: Float.round(totals.hit_bytes / totals.bytes, 4),
      cost_saved: Float.round(totals.hit_cost / totals.cost, 4)
    }
  end

  defp count(totals, hit?, size, cost) do
    hit = if hit?, do: 1, else: 0

    %{
      totals
      | requests: totals.requests + 1,
        hits: totals.hits + hit,
        bytes: totals.bytes + size,
        hit_bytes: totals.hit_bytes + hit * size,
        cost: totals.cost + cost,
        hit_cost: totals.hit_cost + hit * cost
    }
  end

  defp start(_backend, :lru, cap) do
    state = %{cap: cap, used: 0, tick: 0, entries: %{}, order: :gb_trees.empty()}
    {state, &lru_step/4}
  end

  defp start(:model, options, cap) do
    {Model.new(cap, options), &model_step(&1, &2, &3, &4, options.cost)}
  end

  defp start(:real, options, cap), do: start_admission(options.window, options.cost, cap)

  # Noisy cost: each render records its true cost scaled by load, about ±3×.
  defp recorded_cost(:true_cost, cost), do: cost
  defp recorded_cost(:noisy_cost, cost), do: round(cost * :math.exp(:rand.normal() * 1.1))
  defp recorded_cost(:no_cost, _cost), do: 0

  defp hash(request),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(request)) |> Base.encode16(case: :lower)

  # -- LRU -------------------------------------------------------------------------

  defp lru_step(state, request, size, _cost) do
    tick = state.tick + 1

    case Map.fetch(state.entries, request) do
      {:ok, {old_tick, size}} ->
        order = :gb_trees.insert(tick, request, :gb_trees.delete(old_tick, state.order))
        entries = Map.put(state.entries, request, {tick, size})
        {true, %{state | tick: tick, order: order, entries: entries}}

      :error when size > state.cap ->
        {false, %{state | tick: tick}}

      :error ->
        state = %{
          state
          | tick: tick,
            used: state.used + size,
            order: :gb_trees.insert(tick, request, state.order),
            entries: Map.put(state.entries, request, {tick, size})
        }

        {false, evict_lru(state)}
    end
  end

  defp evict_lru(%{used: used, cap: cap} = state) when used <= cap, do: state

  defp evict_lru(state) do
    {_tick, request, order} = :gb_trees.take_smallest(state.order)
    {{_tick, size}, entries} = Map.pop!(state.entries, request)
    evict_lru(%{state | used: state.used - size, order: order, entries: entries})
  end

  # -- W-TinyLFU model -------------------------------------------------------------

  defp model_step(model, request, size, cost, cost_mode) do
    descriptor = %{
      key_hash: hash(request),
      size_bytes: size,
      body_sha256: "",
      cost_us: recorded_cost(cost_mode, cost)
    }

    Model.request(model, descriptor)
  end

  # -- real Admission ------------------------------------------------------------

  defp start_admission(window_ratio, cost_mode, cap) do
    root = Path.join(System.tmp_dir!(), "cache-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    registry = FileSystem.registry_name(root)
    {:ok, registry_pid} = Registry.start_link(keys: :unique, name: registry)
    scaled_cap = div(cap, @scale)

    {:ok, admission} =
      Admission.start_link(
        [
          registry: registry,
          root: root,
          node_id: "bench",
          state_dir: Path.join(root, ".cache_state"),
          max_size_bytes: scaled_cap,
          window_ratio: window_ratio,
          eviction_victim_limit: 64
        ] ++ Model.sketch_options(cap)
      )

    Admission.await_scan(admission, :infinity)

    state = %{
      pool: [root: root, node_id: "bench", max_size_bytes: scaled_cap],
      root: root,
      admission: admission,
      registry: registry_pid,
      cost_mode: cost_mode
    }

    {state, &admission_step/4}
  end

  defp admission_step(state, request, size, cost) do
    key = %Key{hash: hash(request), data: []}

    case FileSystem.get(key, state.pool) do
      {:hit, _entry} ->
        {true, state}

      _miss ->
        commit(state, key, request, size, recorded_cost(state.cost_mode, cost))
        {false, state}
    end
  end

  defp commit(state, key, request, size, cost) do
    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-04-29 10:15:00Z],
        output_format: :webp,
        cost_us: cost
      )

    # Unique bodies: stored bodies are deleted by content hash.
    prefix = :erlang.term_to_binary(request)
    body = prefix <> :binary.copy("x", max(div(size, @scale) - byte_size(prefix), 0))

    {:ok, sink} = FileSystem.open_sink(key, metadata, state.pool)
    {:ok, sink} = FileSystem.write_chunk(sink, body, state.pool)
    FileSystem.commit_sink(sink, state.pool)
  end

  defp stop(%{admission: admission} = state) do
    GenServer.stop(admission)
    GenServer.stop(state.registry)
    File.rm_rf!(state.root)
  end

  defp stop(_state), do: :ok
end

defmodule CachePolicyBench.Model do
  # In-memory copy of Admission's queue handling: window LRU, probationary and
  # protected segments, the main gate, and reconciliation to the cap. It calls
  # the real Sketch, Doorkeeper and Policy, so it tracks scoring changes, but a
  # change to Admission's queue handling must be mirrored here. Check with
  # `--real` that both agree.
  alias ImagePipe.Cache.FileSystem.Doorkeeper
  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Sketch

  @victim_limit 64
  @queues [:window, :probationary, :protected]

  def sketch_options(cap) do
    [
      sketch_depth: 4,
      sketch_width: max(4096, div(cap, 25_000)),
      aging_sample_size: max(81_920, div(cap, 5_000)),
      doorkeeper_cardinality: max(8192, div(cap, 12_500)),
      doorkeeper_fpr: 0.01
    ]
  end

  def new(cap, policy) do
    options = sketch_options(cap)

    sample_size =
      case policy.aging do
        :default -> options[:aging_sample_size]
        {:entries, k} -> max(k * div(cap, policy.mean_entry_bytes), 1)
      end

    %{
      max: cap,
      admission_mode: policy.admission,
      gate: policy.gate,
      window_budget: trunc(cap * policy.window),
      cms:
        Sketch.new(
          depth: options[:sketch_depth],
          width: options[:sketch_width],
          sample_size: sample_size
        ),
      doorkeeper_cardinality: options[:doorkeeper_cardinality],
      doorkeeper: Doorkeeper.new(options[:doorkeeper_cardinality], 0.01),
      trees: Map.new(@queues, &{&1, :gb_trees.empty()}),
      bytes: Map.new(@queues, &{&1, 0}),
      index: %{},
      position: 0
    }
  end

  # Returns {hit?, model}. A miss commits the entry, as a real miss would.
  def request(model, descriptor) do
    key = descriptor.key_hash
    model = sighting(model, key)

    case Map.fetch(model.index, key) do
      {:ok, {queue, _position}} -> {true, promote(model, queue, key)}
      :error -> {false, admit_new(model, descriptor)}
    end
  end

  defp sighting(model, key) do
    model =
      if Talan.BloomFilter.member?(model.doorkeeper, key) do
        %{model | cms: Sketch.increment(model.cms, key)}
      else
        :ok = Talan.BloomFilter.put(model.doorkeeper, key)
        model
      end

    if Sketch.should_age?(model.cms) do
      %{
        model
        | cms: Sketch.age(model.cms),
          doorkeeper: Doorkeeper.new(model.doorkeeper_cardinality, 0.01)
      }
    else
      model
    end
  end

  defp frequency(model, key) do
    bit = if Talan.BloomFilter.member?(model.doorkeeper, key), do: 1, else: 0
    bit + Sketch.estimate(model.cms, key)
  end

  defp promote(model, :probationary, key) do
    {descriptor, model} = drop(model, key)
    model |> put(:protected, descriptor) |> enforce_protected()
  end

  defp promote(model, queue, key) do
    {descriptor, model} = drop(model, key)
    put(model, queue, descriptor)
  end

  defp enforce_protected(model) do
    target = trunc((model.max - model.window_budget) * 0.80)

    if model.bytes.protected > target and not :gb_trees.is_empty(model.trees.protected) do
      {_position, descriptor} = :gb_trees.smallest(model.trees.protected)
      {descriptor, model} = drop(model, descriptor.key_hash)
      model |> put(:probationary, descriptor) |> enforce_protected()
    else
      model
    end
  end

  defp admit_new(model, descriptor) do
    cond do
      descriptor.size_bytes > model.max -> model
      descriptor.size_bytes > model.window_budget -> main_gate(model, descriptor)
      true -> model |> put(:window, descriptor) |> drain_window()
    end
  end

  defp drain_window(model) do
    if model.bytes.window <= model.window_budget or :gb_trees.is_empty(model.trees.window) do
      model
    else
      {_position, descriptor} = :gb_trees.smallest(model.trees.window)
      {descriptor, model} = drop(model, descriptor.key_hash)
      model |> main_gate(descriptor) |> drain_window()
    end
  end

  defp main_gate(model, descriptor) do
    needed =
      model.bytes.probationary + model.bytes.protected + descriptor.size_bytes -
        (model.max - model.window_budget)

    if needed > 0 do
      score(model, descriptor, needed)
    else
      put(model, :probationary, descriptor)
    end
  end

  defp score(model, descriptor, needed) do
    victims =
      Policy.victim_walk(
        lru(model.trees.probationary),
        lru(model.trees.protected),
        needed,
        @victim_limit
      )

    with {:ok, victims} <- victims,
         true <- admit?(model, descriptor, victims) do
      {now, later} = Enum.split(victims, @victim_limit)
      model = Enum.reduce(now, model, fn victim, acc -> acc |> drop(victim.key_hash) |> elem(1) end)
      model = put(model, :probationary, descriptor)
      if later == [], do: model, else: reconcile(model)
    else
      _rejected -> model
    end
  end

  defp admit?(model, descriptor, victims) do
    gate_admit?(model.gate, model, descriptor, victims) or
      random_admit?(model.admission_mode, frequency(model, descriptor.key_hash))
  end

  defp gate_admit?(:average, model, descriptor, victims),
    do: Policy.admit?(descriptor, victims, &frequency(model, &1))

  defp gate_admit?(:each, model, descriptor, victims) do
    score = Policy.score(descriptor, frequency(model, descriptor.key_hash))
    Enum.all?(victims, &(score > Policy.score(&1, frequency(model, &1.key_hash))))
  end

  defp random_admit?({:random, min_frequency, one_in}, frequency)
       when frequency >= min_frequency,
       do: :rand.uniform(one_in) == 1

  defp random_admit?(_admission, _frequency), do: false

  defp reconcile(model) do
    over? = model.bytes.window + model.bytes.probationary + model.bytes.protected > model.max
    queue = Enum.find([:probationary, :protected], &(not :gb_trees.is_empty(model.trees[&1])))

    if over? and queue do
      {_position, descriptor} = :gb_trees.smallest(model.trees[queue])
      {_descriptor, model} = drop(model, descriptor.key_hash)
      reconcile(model)
    else
      model
    end
  end

  defp lru(tree) do
    Stream.unfold(:gb_trees.iterator(tree), fn iterator ->
      case :gb_trees.next(iterator) do
        :none -> nil
        {_position, descriptor, next} -> {descriptor, next}
      end
    end)
  end

  defp put(model, queue, descriptor) do
    position = model.position + 1

    %{
      model
      | position: position,
        trees: Map.update!(model.trees, queue, &:gb_trees.insert(position, descriptor, &1)),
        bytes: Map.update!(model.bytes, queue, &(&1 + descriptor.size_bytes)),
        index: Map.put(model.index, descriptor.key_hash, {queue, position})
    }
  end

  defp drop(model, key) do
    {{queue, position}, index} = Map.pop!(model.index, key)
    descriptor = :gb_trees.get(position, model.trees[queue])

    {descriptor,
     %{
       model
       | index: index,
         trees: Map.update!(model.trees, queue, &:gb_trees.delete(position, &1)),
         bytes: Map.update!(model.bytes, queue, &(&1 - descriptor.size_bytes))
     }}
  end
end

CachePolicyBench.run(System.argv())
