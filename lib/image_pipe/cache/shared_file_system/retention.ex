defmodule ImagePipe.Cache.SharedFileSystem.Retention do
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.{Policy, Sketch}

  # Pure policy state. The owner applies admitted transitions around publication;
  # victim descriptors identify exact local generations, never shared key paths.
  def new(opts) do
    capacity = Keyword.fetch!(opts, :max_bytes)
    window = trunc(capacity * Keyword.fetch!(opts, :window_ratio))

    %{
      entries: %{},
      queues: Map.new([:window, :probationary, :protected], &{&1, :gb_trees.empty()}),
      bytes: %{window: 0, probationary: 0, protected: 0},
      sequence: 0,
      capacity: capacity,
      window: window,
      protected: trunc((capacity - window) * Keyword.fetch!(opts, :protected_ratio)),
      max_entries: Keyword.fetch!(opts, :max_entries),
      max_victims: Keyword.fetch!(opts, :max_victims),
      sketch: Sketch.new(Keyword.fetch!(opts, :sketch))
    }
  end

  def descriptor(location, size, digest, cost),
    do: %{
      key_hash: identity(location.kind, location.key),
      location: location,
      size_bytes: size,
      body_sha256: digest,
      cost_us: cost
    }

  def clear(state),
    do: %{
      state
      | entries: %{},
        queues:
          Map.new(
            [:window, :probationary, :protected],
            &{&1, :gb_trees.empty()}
          ),
        bytes: %{window: 0, probationary: 0, protected: 0}
    }

  # Call exactly once per real local demand, including misses. Inventory import
  # and speculative admission never advance the sketch or request recency.
  def request(state, kind, key) do
    hash = identity(kind, key)
    sketch = Sketch.increment(state.sketch, hash)
    sketch = if Sketch.should_age?(sketch), do: Sketch.age(sketch), else: sketch
    state = %{state | sketch: sketch}

    case Map.get(state.entries, hash) do
      nil ->
        state

      %{queue: queue, descriptor: descriptor} ->
        queue = if queue == :probationary, do: :protected, else: queue
        state |> remove(hash) |> insert(descriptor, queue) |> demote()
    end
  end

  def offer(state, descriptor) do
    previous = Map.get(state.entries, descriptor.key_hash)
    available = remove(state, descriptor.key_hash)

    case admit(available, descriptor) do
      {:ok, admitted, victims} ->
        case Map.get(admitted.entries, descriptor.key_hash) do
          %{descriptor: ^descriptor} ->
            victims = previous_victim(previous, descriptor, victims)
            {:admit, admitted, victims}

          nil ->
            {:reject, :low_value, state}
        end

      {:error, reason} ->
        {:reject, reason, state}
    end
  end

  def forget(state, descriptor) do
    case Map.get(state.entries, descriptor.key_hash) do
      %{descriptor: %{location: location}} when location == descriptor.location ->
        remove(state, descriptor.key_hash)

      _absent_or_replaced ->
        state
    end
  end

  def retained(state, kind, key) do
    case Map.get(state.entries, identity(kind, key)) do
      nil -> nil
      entry -> entry.descriptor
    end
  end

  def ranked(state, limit) do
    state.entries
    |> Map.values()
    |> Enum.sort_by(
      fn entry ->
        descriptor = entry.descriptor

        {entry.queue == :protected,
         Policy.score(descriptor, Sketch.estimate(state.sketch, descriptor.key_hash)),
         entry.position}
      end,
      :desc
    )
    |> Enum.take(limit)
    |> Enum.map(& &1.descriptor)
  end

  def stats(state),
    do: %{
      entries: map_size(state.entries),
      bytes: Enum.sum(Map.values(state.bytes)),
      window_bytes: state.bytes.window,
      protected_bytes: state.bytes.protected
    }

  defp admit(state, descriptor) do
    cond do
      descriptor.size_bytes > state.capacity -> {:error, :over_cap}
      descriptor.size_bytes > state.window -> main_gate(state, descriptor, state.max_victims)
      true -> state |> insert(descriptor, :window) |> drain([], state.max_victims)
    end
  end

  defp drain(state, victims, remaining) do
    cond do
      state.bytes.window <= state.window and map_size(state.entries) <= state.max_entries ->
        {:ok, state, victims}

      remaining == 0 ->
        {:error, :victim_limit}

      true ->
        descriptor = oldest(state, :window)
        state = remove(state, descriptor.key_hash)
        drain_candidate(state, descriptor, victims, remaining)
    end
  end

  defp drain_candidate(state, descriptor, victims, remaining) do
    case main_gate(state, descriptor, remaining - 1) do
      {:ok, next, evicted} -> drain(next, victims ++ evicted, remaining - 1 - length(evicted))
      {:error, _rejected} -> drain(state, victims ++ [descriptor], remaining - 1)
    end
  end

  defp main_gate(state, descriptor, limit) do
    main_bytes = state.bytes.probationary + state.bytes.protected
    needed = max(main_bytes + descriptor.size_bytes - (state.capacity - state.window), 0)
    needed = if map_size(state.entries) >= state.max_entries, do: max(needed, 1), else: needed

    case victims(state, needed, limit) do
      {:ok, victims} -> score(state, descriptor, victims)
      {:error, reason} -> {:error, reason}
    end
  end

  defp victims(_state, 0, _limit), do: {:ok, []}
  defp victims(_state, _needed, 0), do: {:error, :victim_limit}

  defp victims(state, needed, limit),
    do:
      Policy.victim_walk(
        ordered(state, :probationary, limit + 1),
        ordered(state, :protected, limit + 1),
        needed,
        limit
      )

  defp score(state, descriptor, victims) do
    case Policy.admit?(descriptor, victims, &Sketch.estimate(state.sketch, &1)) do
      true ->
        state =
          Enum.reduce(victims, state, fn victim, state -> remove(state, victim.key_hash) end)

        {:ok, insert(state, descriptor, :probationary), victims}

      false ->
        {:error, :low_value}
    end
  end

  defp ordered(state, queue, limit) do
    state.queues |> Map.fetch!(queue) |> :gb_trees.iterator() |> take(state, limit, [])
  end

  defp take(_iterator, _state, 0, entries), do: Enum.reverse(entries)

  defp take(iterator, state, remaining, entries) do
    case :gb_trees.next(iterator) do
      :none ->
        Enum.reverse(entries)

      {_position, hash, next} ->
        take(next, state, remaining - 1, [state.entries[hash].descriptor | entries])
    end
  end

  defp demote(state) do
    case state.bytes.protected > state.protected do
      true ->
        descriptor = oldest(state, :protected)
        state |> remove(descriptor.key_hash) |> insert(descriptor, :probationary) |> demote()

      false ->
        state
    end
  end

  defp oldest(state, queue) do
    {_position, hash} = state.queues |> Map.fetch!(queue) |> :gb_trees.smallest()
    state.entries[hash].descriptor
  end

  defp insert(state, descriptor, queue) do
    position = state.sequence + 1
    entry = %{descriptor: descriptor, queue: queue, position: position}

    %{
      state
      | entries: Map.put(state.entries, descriptor.key_hash, entry),
        queues:
          Map.update!(state.queues, queue, &:gb_trees.insert(position, descriptor.key_hash, &1)),
        bytes: Map.update!(state.bytes, queue, &(&1 + descriptor.size_bytes)),
        sequence: position
    }
  end

  defp remove(state, hash) do
    case Map.pop(state.entries, hash) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        %{
          state
          | entries: entries,
            queues: Map.update!(state.queues, entry.queue, &:gb_trees.delete(entry.position, &1)),
            bytes: Map.update!(state.bytes, entry.queue, &(&1 - entry.descriptor.size_bytes))
        }
    end
  end

  defp previous_victim(nil, _descriptor, victims), do: victims

  defp previous_victim(%{descriptor: previous}, descriptor, victims) do
    if previous.location == descriptor.location, do: victims, else: [previous | victims]
  end

  defp identity(kind, key), do: :erlang.term_to_binary({kind, key})
end
