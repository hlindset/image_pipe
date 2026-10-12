# Compares bounded FileSystem admission (W-TinyLFU) with a plain LRU of the
# same byte budget, and with cheaper policies, on synthetic traffic. Run from
# image_pipe/:
#
#   mise exec -- mix run bench/cache_policy.exs
#   mise exec -- mix run bench/cache_policy.exs zipf-0.8 5
#   mise exec -- mix run bench/cache_policy.exs --cdn
#   mise exec -- mix run bench/cache_policy.exs shield+scan 5
#   mise exec -- mix run bench/cache_policy.exs --real shift 5
#   mise exec -- mix run bench/cache_policy.exs --random-sweep
#   mise exec -- mix run bench/cache_policy.exs --restart-sweep
#
# Optional arguments: one workload and one cache size (% of catalog bytes).
# `--cdn` replaces the workloads with each workload filtered through each
# simulated CDN in @cdns, named `<cdn>+<workload>`: only the CDN's misses
# reach the cache under test, as on a node behind a CDN.
# `--random-sweep` replaces the policy list with a grid of random admission
# thresholds and odds, each run with three seeds for the random draws.
# `--restart-sweep` restarts the cache every N requests, either starting cold
# with every entry on probation by write time (as Admission does) or by last
# access, or keeping its sketch and protected list as a persisted state would.
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
# served from cache, the quantity the cost-aware score optimises. On
# CDN-filtered workloads, `origin_share` is the share of client requests after
# warm-up that miss the CDN, and the other ratios are over those requests.
defmodule CachePolicyBench do
  alias CachePolicyBench.Lru
  alias CachePolicyBench.Model
  alias CachePolicyBench.Sampled
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key

  @catalog 20_000
  @requests 200_000
  @scale 100
  @workloads ["zipf-0.8", "zipf-1.0", "scan", "shift", "mixed-cost"]
  @cache_percents [1, 5, 20]
  # Each CDN routes a request to one of `edges` LRUs at random, each holding
  # `edge_percent` of the catalog's bytes. An edge miss goes to the shield LRU
  # if there is one, and a shield miss to the cache under test. Edge and
  # shield entries expire `ttl` requests after they were fetched.
  @cdns %{
    "edges" => %{edges: 8, edge_percent: 10, ttl: nil, shield_percent: nil},
    "edges-ttl" => %{edges: 8, edge_percent: 10, ttl: 20_000, shield_percent: nil},
    "shield" => %{edges: 8, edge_percent: 10, ttl: nil, shield_percent: 30},
    "shield-ttl" => %{edges: 8, edge_percent: 10, ttl: 20_000, shield_percent: 30}
  }
  # {name, :lru | {:lru, doorkeeper: k} | {:sampled, k} |
  # {:sampled, k, overrides of @tinylfu} | overrides of @tinylfu}.
  #
  #   * `{:lru, doorkeeper: k}` admits a key into the LRU only on its second
  #     request, remembered in a Doorkeeper bloom filter that resets every
  #     k × the cache's expected entry count insertions.
  #   * `{:sampled, k}` keeps W-TinyLFU's sketch, doorkeeper, score and gate
  #     but no window or queues: each victim is the lowest-scoring of k
  #     entries sampled at random, as in Ristretto.
  #
  # Model-only options:
  #
  #   * `admission: {:random, min_frequency, one_in}` admits a candidate that
  #     loses the gate anyway with probability 1/one_in when its frequency is
  #     at least min_frequency. Admission uses {:random, 6, 128}, as Caffeine
  #     does. `:strict` never admits a loser.
  #   * `aging: {:entries, k}` halves the sketch every k × the cache's expected
  #     entry count (cap / mean entry size), as Caffeine does with k = 10,
  #     instead of the adapter's default.
  #   * `restart: {every, mode}` restarts the cache every `every` requests.
  #     `:persist` keeps the sketch and protected list, `:cold` clears them
  #     and queues every entry on probation by write time, as Admission's
  #     startup scan orders by mtime, and `:cold_access` by last access.
  #   * `gate: :each` admits only a candidate that outscores every victim,
  #     instead of the size-weighted average of the victims.
  @tinylfu %{
    window: 0.01,
    cost: :true_cost,
    admission: {:random, 6, 128},
    aging: :default,
    gate: :average,
    restart: nil,
    seed: 9
  }
  @policies [
    {"lru", :lru},
    {"tinylfu", []},
    {"noisy-cost", cost: :noisy_cost},
    {"no-cost", cost: :no_cost},
    {"static-cost", cost: :static_cost},
    {"window-5%", window: 0.05},
    {"window-20%", window: 0.20},
    {"strict", admission: :strict},
    {"random-3/32", admission: {:random, 3, 32}},
    {"aging-10x", aging: {:entries, 10}},
    {"aging-20x", aging: {:entries, 20}},
    {"aging-40x", aging: {:entries, 40}},
    {"aging-10x-strict", aging: {:entries, 10}, admission: :strict},
    {"gate-each", gate: :each},
    {"lru-doorkeeper-1x", {:lru, doorkeeper: 1}},
    {"lru-doorkeeper-2x", {:lru, doorkeeper: 2}},
    {"lru-doorkeeper-10x", {:lru, doorkeeper: 10}},
    {"sampled-5", {:sampled, 5}},
    {"sampled-16", {:sampled, 16}},
    {"sampled-64", {:sampled, 64}},
    {"sampled-16-no-cost", {:sampled, 16, cost: :no_cost}},
    {"sampled-16-noisy-cost", {:sampled, 16, cost: :noisy_cost}},
    {"sampled-16-static-cost", {:sampled, 16, cost: :static_cost}},
    {"sampled-16-biased-cost", {:sampled, 16, cost: :biased_cost}}
  ]

  def run(args) do
    {backend, args} =
      case args do
        ["--real" | rest] -> {:real, rest}
        rest -> {:model, rest}
      end

    {policies, args} =
      case args do
        ["--random-sweep" | rest] -> {random_sweep(), rest}
        ["--restart-sweep" | rest] -> {restart_sweep(), rest}
        rest -> {@policies, rest}
      end

    {workloads, percents} =
      case args do
        [] -> {@workloads, @cache_percents}
        ["--cdn"] -> {cdn_workloads(), @cache_percents}
        [workload, percent] -> {[workload], [String.to_integer(percent)]}
      end

    for workload <- workloads do
      base = workload |> String.split("+") |> List.last()
      catalog = catalog(base)
      catalog_bytes = catalog_bytes(catalog)
      {traffic, labels} = traffic(workload, base, catalog, catalog_bytes)

      mean_entry_bytes = div(catalog_bytes, @catalog)

      for percent <- percents,
          {name, policy} <- policies,
          policy = options(policy, mean_entry_bytes),
          supported?(backend, policy) do
        {percent, name, policy}
      end
      |> Task.async_stream(
        fn {percent, name, policy} ->
          cap = div(catalog_bytes * percent, 100)
          stats = simulate(backend, policy, traffic, catalog, cap)

          stats
          |> Map.merge(labels)
          |> Map.merge(%{workload: workload, cache_percent: percent, policy: name})
        end,
        max_concurrency: System.schedulers_online(),
        timeout: :infinity
      )
      |> Enum.each(fn {:ok, result} -> IO.puts(JSON.encode!(result)) end)
    end
  end

  defp cdn_workloads do
    for cdn <- Enum.sort(Map.keys(@cdns)), workload <- @workloads, do: "#{cdn}+#{workload}"
  end

  defp random_sweep do
    variants =
      for min_frequency <- [2, 3, 4, 6, 8, 10], one_in <- [16, 32, 64, 128, 256] do
        {"random-#{min_frequency}/#{one_in}", admission: {:random, min_frequency, one_in}}
      end

    for {name, overrides} <- [{"strict", admission: :strict} | variants], seed <- 1..3 do
      {name, Keyword.put(overrides, :seed, seed)}
    end
  end

  defp restart_sweep do
    restarts =
      for every <- [20_000, 50_000], mode <- [:persist, :cold, :cold_access] do
        {"restart-#{div(every, 1_000)}k-#{mode}", restart: {every, mode}}
      end

    [{"lru", :lru}, {"tinylfu", []} | restarts]
  end

  defp options(:lru, _mean_entry_bytes), do: :lru

  defp options({:lru, doorkeeper: k}, mean_entry_bytes),
    do: {:lru_doorkeeper, k, mean_entry_bytes}

  defp options({:sampled, k}, mean_entry_bytes), do: options({:sampled, k, []}, mean_entry_bytes)

  defp options({:sampled, k, overrides}, mean_entry_bytes),
    do: {:sampled, k, options(overrides, mean_entry_bytes)}

  defp options(overrides, mean_entry_bytes),
    do: @tinylfu |> Map.merge(Map.new(overrides)) |> Map.put(:mean_entry_bytes, mean_entry_bytes)

  defp seed(%{seed: seed}), do: seed
  defp seed({:sampled, _k, %{seed: seed}}), do: seed
  defp seed(_policy), do: 9

  defp supported?(:real, %{
         admission: {:random, 6, 128},
         aging: :default,
         gate: :average,
         restart: nil
       }),
       do: true

  defp supported?(:real, %{}), do: false
  defp supported?(_backend, _policy), do: true

  # -- traffic -----------------------------------------------------------------

  # Key id -> {real size in bytes, true render cost in µs, class}. Ids from
  # @catalog up are one-off keys. Render cost tracks size (pixels) with a
  # log-normal spread for content, about 1 µs per byte for `:plain` renders.
  defp catalog("mixed-cost") do
    seeded_catalog(fn ->
      case :rand.uniform() do
        # Small terminals (info, blurhash, LQIP): tiny bodies, full decode.
        r when r < 0.1 -> {lognormal(1_000, 0.5), lognormal(50_000, 0.5), :terminal}
        # Slow encoders (AVIF): similar sizes, several times the work.
        r when r < 0.3 -> sized(lognormal(40_000, 1.0), :slow)
        _ -> sized(lognormal(50_000, 1.0), :plain)
      end
    end)
  end

  defp catalog(_workload), do: seeded_catalog(fn -> sized(lognormal(50_000, 1.0), :plain) end)

  defp seeded_catalog(entry) do
    :rand.seed(:exsss, {1, 2, 3})
    Map.new(0..(@catalog * 2), fn id -> {id, entry.()} end)
  end

  defp sized(size, class), do: {size, lognormal(static_cost(class, size), 0.5), class}

  # The median cost of a class, as a static cost model that ignores content
  # would estimate it.
  defp static_cost(:terminal, _size), do: 50_000
  defp static_cost(:slow, size), do: size * 8
  defp static_cost(:plain, size), do: size

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

  # {requests, warm-up count} for the cache under test, and labels to add to
  # each result.
  defp traffic(workload, workload, _catalog, _catalog_bytes) do
    requests = requests(workload)
    {{requests, div(length(requests), 4)}, %{}}
  end

  defp traffic(workload, base, catalog, catalog_bytes) do
    [cdn | _base] = String.split(workload, "+")
    requests = requests(base)
    warmup = div(length(requests), 4)
    {misses, origin_warmup} = cdn_misses(Map.fetch!(@cdns, cdn), requests, catalog, catalog_bytes)
    origin_share = (length(misses) - origin_warmup) / (length(requests) - warmup)
    {{misses, origin_warmup}, %{cdn: cdn, origin_share: Float.round(origin_share, 4)}}
  end

  # Returns the requests that miss the CDN, in order, and how many of them
  # fall in the warm-up quarter.
  defp cdn_misses(cdn, requests, catalog, catalog_bytes) do
    :rand.seed(:exsss, {10, 11, 12})
    edge = Lru.new(div(catalog_bytes * cdn.edge_percent, 100), ttl: cdn.ttl)
    edges = Map.new(1..cdn.edges, &{&1, edge})

    shield =
      if cdn.shield_percent,
        do: Lru.new(div(catalog_bytes * cdn.shield_percent, 100), ttl: cdn.ttl)

    warmup = div(length(requests), 4)

    {_edges, _shield, misses, origin_warmup} =
      requests
      |> Enum.with_index()
      |> Enum.reduce({edges, shield, [], 0}, fn {request, now}, {edges, shield, misses, count} ->
        {size, _cost, _class} = attributes(catalog, request)
        id = :rand.uniform(cdn.edges)
        {hit?, edge} = Lru.request(edges[id], request, size, now)
        edges = Map.put(edges, id, edge)

        {hit?, shield} =
          cond do
            hit? -> {true, shield}
            shield -> Lru.request(shield, request, size, now)
            true -> {false, nil}
          end

        cond do
          hit? -> {edges, shield, misses, count}
          now < warmup -> {edges, shield, [request | misses], count + 1}
          true -> {edges, shield, [request | misses], count}
        end
      end)

    {Enum.reverse(misses), origin_warmup}
  end

  # -- measurement ---------------------------------------------------------------

  defp simulate(backend, policy, {requests, warmup}, catalog, cap) do
    :rand.seed(:exsss, {7, 8, seed(policy)})
    {state, step} = start(backend, policy, cap)
    zero = %{requests: 0, hits: 0, bytes: 0, hit_bytes: 0, cost: 0, hit_cost: 0}

    {state, totals} =
      requests
      |> Enum.with_index()
      |> Enum.reduce({state, zero}, fn {request, index}, {state, totals} ->
        {size, cost, class} = attributes(catalog, request)
        {hit?, state} = step.(state, request, size, {cost, class})
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

  defp start(_backend, :lru, cap), do: {Lru.new(cap), &lru_step/4}

  defp start(_backend, {:lru_doorkeeper, k, mean_entry_bytes}, cap) do
    {Lru.new(cap, doorkeeper: max(k * div(cap, mean_entry_bytes), 1)), &lru_step/4}
  end

  defp start(_backend, {:sampled, k, options}, cap) do
    {Sampled.new(cap, k, options), &model_step(&1, &2, &3, &4, options.cost, Sampled)}
  end

  defp start(:model, options, cap) do
    {Model.new(cap, options), &model_step(&1, &2, &3, &4, options.cost, Model)}
  end

  defp start(:real, options, cap), do: start_admission(options.window, options.cost, cap)

  # Noisy cost: each render records its true cost scaled by load, about ±3×.
  # Static cost: a model that estimates cost from the class and size, without
  # noise but blind to content. Biased cost: the same model with the expensive
  # classes' weights set 2× too low.
  defp recorded_cost(:true_cost, {cost, _class}, _size), do: cost

  defp recorded_cost(:noisy_cost, {cost, _class}, _size),
    do: round(cost * :math.exp(:rand.normal() * 1.1))

  defp recorded_cost(:no_cost, _cost, _size), do: 0
  defp recorded_cost(:static_cost, {_cost, class}, size), do: static_cost(class, size)

  defp recorded_cost(:biased_cost, {_cost, class}, size),
    do: if(class == :plain, do: size, else: div(static_cost(class, size), 2))

  defp hash(request),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(request)) |> Base.encode16(case: :lower)

  # -- LRU -------------------------------------------------------------------------

  defp lru_step(lru, request, size, _cost), do: Lru.request(lru, request, size, lru.tick)

  # -- W-TinyLFU model -------------------------------------------------------------

  defp model_step(model, request, size, cost, cost_mode, module) do
    descriptor = %{
      key_hash: hash(request),
      size_bytes: size,
      body_sha256: "",
      cost_us: recorded_cost(cost_mode, cost, size)
    }

    module.request(model, descriptor)
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
        Store.admission_options(
          [root: root, max_size_bytes: scaled_cap, window_ratio: window_ratio] ++
            Model.sketch_options(cap),
          registry
        )
      )

    Admission.await_scan(admission, :infinity)

    state = %{
      pool: [root: root, max_size_bytes: scaled_cap],
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
        commit(state, key, request, size, recorded_cost(state.cost_mode, cost, size))
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
    cap
    |> counters(policy)
    |> Map.merge(%{
      max: cap,
      admission_mode: policy.admission,
      gate: policy.gate,
      window_budget: trunc(cap * policy.window),
      restart: policy.restart,
      requests: 0,
      trees: Map.new(@queues, &{&1, :gb_trees.empty()}),
      bytes: Map.new(@queues, &{&1, 0}),
      index: %{},
      position: 0
    })
  end

  # The sketch and doorkeeper that `sighting/2` and `frequency/2` use.
  def counters(cap, policy) do
    options = sketch_options(cap)

    sample_size =
      case policy.aging do
        :default -> options[:aging_sample_size]
        {:entries, k} -> max(k * div(cap, policy.mean_entry_bytes), 1)
      end

    sketch_options = [
      depth: options[:sketch_depth],
      width: options[:sketch_width],
      sample_size: sample_size
    ]

    %{
      sketch_options: sketch_options,
      cms: Sketch.new(sketch_options),
      doorkeeper_cardinality: options[:doorkeeper_cardinality],
      doorkeeper: Doorkeeper.new(options[:doorkeeper_cardinality], 0.01)
    }
  end

  # Returns {hit?, model}. A miss commits the entry, as a real miss would.
  def request(model, descriptor) do
    model = model |> Map.update!(:requests, &(&1 + 1)) |> maybe_restart()
    key = descriptor.key_hash
    model = sighting(model, key)

    case Map.fetch(model.index, key) do
      {:ok, {queue, _position}} ->
        {true, promote(model, queue, key)}

      :error ->
        {false, admit_new(model, Map.put(descriptor, :written_at, model.requests))}
    end
  end

  defp maybe_restart(%{restart: {every, mode}, requests: requests} = model)
       when rem(requests, every) == 0,
       do: restart(model, mode)

  defp maybe_restart(model), do: model

  # Mirrors Admission's startup: the doorkeeper starts empty and the window
  # is rebuilt from traffic. Entries go on probation in scan order.
  defp restart(model, mode) do
    entries = for queue <- @queues, entry <- entries(model, queue), do: {queue, entry}

    {protected, probationary} =
      case mode do
        :persist -> Enum.split_with(entries, fn {queue, _entry} -> queue == :protected end)
        _cold -> {[], entries}
      end

    order =
      case mode do
        :cold_access -> fn {_queue, {position, _descriptor}} -> position end
        _by_write -> fn {_queue, {_position, descriptor}} -> descriptor.written_at end
      end

    cms =
      case mode do
        :persist -> model.cms
        _cold -> Sketch.new(model.sketch_options)
      end

    empty = %{
      model
      | cms: cms,
        doorkeeper: Doorkeeper.new(model.doorkeeper_cardinality, 0.01),
        trees: Map.new(@queues, &{&1, :gb_trees.empty()}),
        bytes: Map.new(@queues, &{&1, 0}),
        index: %{}
    }

    empty = Enum.reduce(protected, empty, fn {_q, {_p, d}}, acc -> put(acc, :protected, d) end)

    probationary
    |> Enum.sort_by(order)
    |> Enum.reduce(empty, fn {_q, {_p, d}}, acc -> put(acc, :probationary, d) end)
  end

  defp entries(model, queue), do: :gb_trees.to_list(model.trees[queue])

  def sighting(model, key) do
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

  def frequency(model, key) do
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

      model =
        Enum.reduce(now, model, fn victim, acc -> acc |> drop(victim.key_hash) |> elem(1) end)

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

  def random_admit?({:random, min_frequency, one_in}, frequency)
      when frequency >= min_frequency,
      do: :rand.uniform(one_in) == 1

  def random_admit?(_admission, _frequency), do: false

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

defmodule CachePolicyBench.Lru do
  # Byte-bounded LRU. With `ttl`, an entry fetched `ttl` or more requests
  # before `now` counts as a miss and is fetched again, as in a CDN. With
  # `doorkeeper: n`, a missed key is admitted only if the doorkeeper has seen
  # it since its last reset, which comes every n insertions.
  alias ImagePipe.Cache.FileSystem.Doorkeeper

  def new(cap, options \\ []) do
    doorkeeper =
      if cardinality = options[:doorkeeper] do
        %{filter: Doorkeeper.new(cardinality, 0.01), cardinality: cardinality, inserts: 0}
      end

    %{
      cap: cap,
      ttl: options[:ttl],
      doorkeeper: doorkeeper,
      used: 0,
      tick: 0,
      entries: %{},
      order: :gb_trees.empty()
    }
  end

  # Returns {hit?, lru}. A miss stores the entry unless the doorkeeper turns
  # it away.
  def request(lru, key, size, now) do
    lru = %{lru | tick: lru.tick + 1}

    case Map.fetch(lru.entries, key) do
      {:ok, {tick, size, fetched_at}} ->
        lru = remove(lru, key, tick, size)

        if expired?(lru, fetched_at, now),
          do: {false, admit(lru, key, size, now)},
          else: {true, insert(lru, key, size, fetched_at)}

      :error ->
        {false, admit(lru, key, size, now)}
    end
  end

  defp expired?(%{ttl: nil}, _fetched_at, _now), do: false
  defp expired?(%{ttl: ttl}, fetched_at, now), do: now - fetched_at >= ttl

  defp admit(lru, _key, size, _now) when size > lru.cap, do: lru

  defp admit(%{doorkeeper: nil} = lru, key, size, now),
    do: lru |> insert(key, size, now) |> evict()

  defp admit(%{doorkeeper: doorkeeper} = lru, key, size, now) do
    if Talan.BloomFilter.member?(doorkeeper.filter, key) do
      lru |> insert(key, size, now) |> evict()
    else
      :ok = Talan.BloomFilter.put(doorkeeper.filter, key)
      %{lru | doorkeeper: reset(%{doorkeeper | inserts: doorkeeper.inserts + 1})}
    end
  end

  defp reset(%{inserts: inserts, cardinality: cardinality} = doorkeeper)
       when inserts >= cardinality,
       do: %{doorkeeper | filter: Doorkeeper.new(cardinality, 0.01), inserts: 0}

  defp reset(doorkeeper), do: doorkeeper

  defp insert(lru, key, size, fetched_at) do
    %{
      lru
      | used: lru.used + size,
        order: :gb_trees.insert(lru.tick, key, lru.order),
        entries: Map.put(lru.entries, key, {lru.tick, size, fetched_at})
    }
  end

  defp remove(lru, key, tick, size) do
    %{
      lru
      | used: lru.used - size,
        order: :gb_trees.delete(tick, lru.order),
        entries: Map.delete(lru.entries, key)
    }
  end

  defp evict(%{used: used, cap: cap} = lru) when used <= cap, do: lru

  defp evict(lru) do
    {tick, key, _order} = :gb_trees.take_smallest(lru.order)
    {_tick, size, _fetched_at} = Map.fetch!(lru.entries, key)
    lru |> remove(key, tick, size) |> evict()
  end
end

defmodule CachePolicyBench.Sampled do
  # W-TinyLFU's admission without the window, queues or LRU order: the same
  # sketch, doorkeeper, cost-aware score, size-weighted average gate and
  # random admission, but each victim is the lowest-scoring of `k` entries
  # sampled at random, as in Ristretto. It needs only the total bytes and a
  # way to sample stored entries, here a slot map.
  alias CachePolicyBench.Model
  alias ImagePipe.Cache.FileSystem.Policy

  def new(cap, k, policy) do
    cap
    |> Model.counters(policy)
    |> Map.merge(%{
      max: cap,
      k: k,
      admission_mode: policy.admission,
      used: 0,
      entries: %{},
      slots: %{},
      slot_of: %{}
    })
  end

  # Returns {hit?, state}. A miss commits the entry, as a real miss would.
  def request(state, descriptor) do
    state = Model.sighting(state, descriptor.key_hash)

    if Map.has_key?(state.entries, descriptor.key_hash),
      do: {true, state},
      else: {false, admit(state, descriptor)}
  end

  defp admit(state, descriptor) do
    cond do
      descriptor.size_bytes > state.max ->
        state

      state.used + descriptor.size_bytes <= state.max ->
        put(state, descriptor)

      true ->
        gate(state, descriptor, pick(state, state.used + descriptor.size_bytes - state.max, []))
    end
  end

  # Takes victims out until `needed` bytes are free. A rejected candidate
  # puts them back.
  defp pick(state, needed, victims) when needed <= 0, do: {state, victims}

  defp pick(state, needed, victims) do
    victim = lowest(state)
    pick(delete(state, victim.key_hash), needed - victim.size_bytes, [victim | victims])
  end

  defp lowest(state) do
    1..state.k
    |> Enum.map(fn _draw ->
      key = Map.fetch!(state.slots, :rand.uniform(map_size(state.slots)) - 1)
      Map.fetch!(state.entries, key)
    end)
    |> Enum.min_by(&Policy.score(&1, Model.frequency(state, &1.key_hash)))
  end

  defp gate(state, descriptor, {taken, victims}) do
    frequency = &Model.frequency(state, &1)

    if Policy.admit?(descriptor, victims, frequency) or
         Model.random_admit?(state.admission_mode, frequency.(descriptor.key_hash)),
       do: put(taken, descriptor),
       else: Enum.reduce(victims, taken, &put(&2, &1))
  end

  defp put(state, descriptor) do
    slot = map_size(state.slots)

    %{
      state
      | used: state.used + descriptor.size_bytes,
        entries: Map.put(state.entries, descriptor.key_hash, descriptor),
        slots: Map.put(state.slots, slot, descriptor.key_hash),
        slot_of: Map.put(state.slot_of, descriptor.key_hash, slot)
    }
  end

  # Moves the last slot's key into the deleted key's slot.
  defp delete(state, key) do
    {descriptor, entries} = Map.pop!(state.entries, key)
    {slot, slot_of} = Map.pop!(state.slot_of, key)
    last = map_size(state.slots) - 1
    {last_key, slots} = Map.pop!(state.slots, last)

    {slots, slot_of} =
      if slot == last,
        do: {slots, slot_of},
        else: {Map.put(slots, slot, last_key), Map.put(slot_of, last_key, slot)}

    %{
      state
      | used: state.used - descriptor.size_bytes,
        entries: entries,
        slots: slots,
        slot_of: slot_of
    }
  end
end

CachePolicyBench.run(System.argv())
