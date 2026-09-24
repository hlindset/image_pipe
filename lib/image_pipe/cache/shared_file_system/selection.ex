defmodule ImagePipe.Cache.SharedFileSystem.Selection do
  @moduledoc false

  alias ImagePipe.Cache.Input.Snapshot

  # Owned by the adapter's node-local coordinator. Blocking I/O and ownership
  # checks happen outside this pure state machine; install only under a live lease.
  def new(opts) do
    %{
      entries: %{},
      recency: :gb_trees.empty(),
      sequence: 0,
      bytes: 0,
      max_entries: Keyword.fetch!(opts, :max_entries),
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      barrier_slots: Keyword.fetch!(opts, :barrier_slots),
      clock_skew: Keyword.fetch!(opts, :clock_skew),
      barriers: %{},
      high_water: nil
    }
  end

  def lookup(state, key, now) do
    state = advance_clock(state, now)

    case now < state.high_water do
      true -> {{:error, :untrusted_clock}, state}
      false -> selected(state, key)
    end
  end

  def discover(state, key, %Snapshot{} = candidate, now) do
    case lookup(state, key, now) do
      {:miss, state} -> discover_missing(state, key, candidate, now)
      result -> result
    end
  end

  def publish(state, key, record, now) do
    state = state |> advance_clock(now) |> barrier(key) |> remove(key)
    snapshot = %Snapshot{revision: :crypto.strong_rand_bytes(24), record: record}
    retain(state, key, snapshot, :ok)
  end

  def invalidate(state, key, revision, now) do
    state = advance_clock(state, now)

    case selected(state, key) do
      {{:hit, %Snapshot{revision: ^revision}}, state} ->
        {_result, state} = publish(state, key, nil, now)
        state

      {_other, state} ->
        state
    end
  end

  def stats(state),
    do: %{
      entries: map_size(state.entries),
      bytes: state.bytes,
      barriers: map_size(state.barriers)
    }

  defp discover_missing(state, _key, %Snapshot{record: nil}, _now),
    do: {{:error, :requires_validation}, state}

  defp discover_missing(state, key, candidate, now) do
    {started, received} = validation_times(candidate.record)
    cutoff = Map.get(state.barriers, bucket(state, key))

    cond do
      (started != nil and started > received) or received > now + state.clock_skew ->
        {{:error, :untrusted_clock}, state}

      cutoff != nil and (started == nil or started - state.clock_skew <= cutoff) ->
        {{:error, :requires_validation}, state}

      true ->
        retain(state, key, %{candidate | age_margin: state.clock_skew}, :hit)
    end
  end

  # A completion timestamp alone cannot prove validation started after a cutoff.
  defp validation_times(%{origin: nil, received_at: received}), do: {nil, received}

  defp validation_times(%{origin: origin}),
    do: {origin.requested_at, origin.received_at}

  defp selected(state, key) do
    case Map.fetch(state.entries, key) do
      {:ok, entry} ->
        snapshot = :erlang.binary_to_term(entry.encoded, [:safe])
        sequence = state.sequence + 1
        recency = :gb_trees.insert(sequence, key, :gb_trees.delete(entry.sequence, state.recency))
        entries = Map.put(state.entries, key, %{entry | sequence: sequence})
        {{:hit, snapshot}, %{state | entries: entries, recency: recency, sequence: sequence}}

      :error ->
        {:miss, state}
    end
  end

  defp retain(state, key, snapshot, result) do
    bytes = :erlang.external_size(snapshot) + byte_size(key)

    case bytes <= state.max_bytes do
      false ->
        {{:error, :selection_too_large}, state}

      true ->
        state = make_room(state, bytes)
        sequence = state.sequence + 1
        entry = %{encoded: :erlang.term_to_binary(snapshot), bytes: bytes, sequence: sequence}

        state = %{
          state
          | entries: Map.put(state.entries, key, entry),
            recency: :gb_trees.insert(sequence, key, state.recency),
            sequence: sequence,
            bytes: state.bytes + bytes
        }

        {{result, snapshot}, state}
    end
  end

  defp make_room(state, bytes) do
    case map_size(state.entries) < state.max_entries and state.bytes + bytes <= state.max_bytes do
      true ->
        state

      false ->
        {_sequence, key} = :gb_trees.smallest(state.recency)
        state |> barrier(key) |> remove(key) |> make_room(bytes)
    end
  end

  defp remove(state, key) do
    case Map.pop(state.entries, key) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        %{
          state
          | entries: entries,
            recency: :gb_trees.delete(entry.sequence, state.recency),
            bytes: state.bytes - entry.bytes
        }
    end
  end

  defp barrier(state, key),
    do: %{state | barriers: Map.put(state.barriers, bucket(state, key), state.high_water)}

  defp bucket(state, key), do: :erlang.phash2(key, state.barrier_slots)

  defp advance_clock(%{high_water: nil} = state, now), do: %{state | high_water: now}
  defp advance_clock(state, now), do: %{state | high_water: max(state.high_water, now)}
end
