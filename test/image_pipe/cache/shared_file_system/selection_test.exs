defmodule ImagePipe.Cache.SharedFileSystem.SelectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Input.Snapshot
  alias ImagePipe.Cache.SharedFileSystem.Selection
  alias ImagePipe.Source
  alias ImagePipe.Source.{Origin, Record}

  test "nodes retain independent selections and discovery cannot replace one" do
    first = snapshot("first", 10)
    changed = snapshot("changed", 20)
    {{:hit, ^first}, a} = Selection.discover(new(), "key", first, 12)
    {{:hit, ^changed}, b} = Selection.discover(new(), "key", changed, 22)
    assert {{:hit, ^first}, _a} = Selection.discover(a, "key", changed, 22)
    assert {{:hit, ^changed}, _b} = Selection.lookup(b, "key", 22)
  end

  test "invalidation matches only the selected revision and blocks rediscovery" do
    first = snapshot("first", 10)
    {{:hit, ^first}, state} = Selection.discover(new(), "key", first, 12)
    state = Selection.invalidate(state, "key", first.revision, 15)
    assert {{:hit, %Snapshot{record: nil}}, state} = Selection.discover(state, "key", first, 16)
    {{:ok, newer}, state} = Selection.publish(state, "key", record("changed", 20), 22)
    state = Selection.invalidate(state, "key", first.revision, 23)
    assert {{:hit, ^newer}, _state} = Selection.lookup(state, "key", 23)
  end

  test "LRU eviction retains rejection knowledge and needs later validation evidence" do
    {{:hit, first}, state} = Selection.discover(new(max_entries: 2), "a", snapshot("a", 10), 12)
    {{:hit, _}, state} = Selection.discover(state, "b", snapshot("b", 10), 12)
    {{:hit, ^first}, state} = Selection.lookup(state, "a", 13)
    {{:ok, _}, state} = Selection.publish(state, "c", record("c", 20), 22)
    assert {:miss, state} = Selection.lookup(state, "b", 22)

    assert {{:error, :requires_validation}, state} =
             Selection.discover(state, "b", snapshot("b", 10), 23)

    # Receiving later is insufficient when the validation started before eviction.
    delayed = snapshot("b", 30, 21)
    assert {{:error, :requires_validation}, state} = Selection.discover(state, "b", delayed, 32)
    later = snapshot("b", 30, 25)
    assert {{:hit, ^later}, _state} = Selection.discover(state, "b", later, 32)
  end

  test "bucket collisions only force validation, and selected peers remain usable" do
    state = new(barrier_slots: 1)
    {{:hit, first}, state} = Selection.discover(state, "a", snapshot("a", 10), 12)
    {{:hit, second}, state} = Selection.discover(state, "b", snapshot("b", 10), 12)
    state = Selection.invalidate(state, "a", first.revision, 15)
    assert {{:hit, ^second}, state} = Selection.lookup(state, "b", 16)

    assert {{:error, :requires_validation}, _state} =
             Selection.discover(state, "c", snapshot("c", 10), 16)
  end

  test "oversized publication cannot leave the old selection discoverable" do
    {{:hit, first}, state} =
      Selection.discover(new(max_bytes: 1_024), "key", snapshot("a", 10), 12)

    large = record(String.duplicate("large", 1_000), 20)
    assert {{:error, :selection_too_large}, state} = Selection.publish(state, "key", large, 22)
    assert {:miss, state} = Selection.lookup(state, "key", 23)
    assert {{:error, :requires_validation}, _state} = Selection.discover(state, "key", first, 23)
  end

  test "clock rollback and future evidence do not weaken cutoffs" do
    {{:hit, first}, state} = Selection.discover(new(), "key", snapshot("a", 10), 20)
    state = Selection.invalidate(state, "key", first.revision, 10)

    assert {{:error, :untrusted_clock}, state} =
             Selection.discover(state, "other", snapshot("b", 10), 11)

    assert {{:error, :untrusted_clock}, _state} =
             Selection.discover(state, "other", snapshot("b", 30), 20)
  end

  test "origin timestamps govern evidence even if processing completed later" do
    initial = record("a", 10)
    # Record.new/4 receives the time after staging, which may differ from headers.
    {:ok, source, _config} = Source.from_input({:binary, "a"}, sources: %{})
    staged = Record.new(source, :crypto.hash(:sha256, "a"), initial.origin, 30)
    candidate = %Snapshot{revision: make_ref(), record: staged, age_margin: 2}
    assert {{:hit, ^candidate}, _state} = Selection.discover(new(), "key", candidate, 12)
  end

  test "a record with no validation start cannot clear a cutoff with its completion time" do
    {{:ok, _}, state} = Selection.publish(new(max_entries: 1), "key", record("a", 10), 12)
    {{:ok, _}, state} = Selection.publish(state, "other", record("b", 15), 17)
    {:ok, source, _config} = Source.from_input({:binary, "a"}, sources: %{})
    completed = Record.new(source, :crypto.hash(:sha256, "a"), nil, 30)
    candidate = %Snapshot{revision: make_ref(), record: completed}

    assert {{:error, :requires_validation}, _state} =
             Selection.discover(state, "key", candidate, 32)
  end

  test "304 publication keeps identity and retained origin evidence" do
    first = record("a", 10)
    {{:ok, old}, state} = Selection.publish(new(), "key", first, 12)
    refreshed = Record.refresh(first, record("a", 30).origin)
    {{:ok, selected}, state} = Selection.publish(state, "key", refreshed, 32)
    assert selected.record.byte_identity == old.record.byte_identity
    assert selected.record == refreshed
    refute selected.revision == old.revision
    state = Selection.invalidate(state, "key", old.revision, 33)
    assert {{:hit, ^selected}, _state} = Selection.lookup(state, "key", 33)
  end

  test "discovery replaces the age margin without accumulating it or rewriting evidence" do
    candidate = %{snapshot("a", 10) | age_margin: 20}
    assert {{:hit, selected}, _state} = Selection.discover(new(), "key", candidate, 12)
    assert selected.age_margin == 2
    assert selected.record == candidate.record
  end

  property "churn never forgets a rejected candidate after its marker is evicted" do
    check all keys <- list_of(integer(0..20), min_length: 1, max_length: 100) do
      candidate = snapshot("a", 10)
      {{:hit, ^candidate}, state} = Selection.discover(new(max_entries: 1), "key", candidate, 12)
      state = Selection.invalidate(state, "key", candidate.revision, 15)

      state =
        Enum.reduce(Enum.with_index(keys, 100), state, fn {key, now}, state ->
          {{:ok, _}, state} =
            Selection.publish(state, Integer.to_string(key), record("b", now), now)

          state
        end)

      assert {{:error, :requires_validation}, _state} =
               Selection.discover(state, "key", candidate, 300)
    end
  end

  property "selection payloads and rejection buckets stay bounded under churn" do
    check all keys <- list_of(integer(0..20), max_length: 100) do
      state =
        Enum.reduce(
          Enum.with_index(keys, 100),
          new(max_entries: 3, max_bytes: 2_048, barrier_slots: 4),
          fn
            {key, now}, state ->
              {{:ok, selected}, state} =
                Selection.publish(state, Integer.to_string(key), record("body", now), now)

              state = Selection.invalidate(state, Integer.to_string(key), selected.revision, now)
              stats = Selection.stats(state)
              assert stats.entries <= 3
              assert stats.bytes <= 2_048
              assert stats.barriers <= 4
              state
          end
        )

      assert Selection.stats(state).entries <= 3
    end
  end

  defp new(opts \\ []),
    do:
      Selection.new(
        Keyword.merge([max_entries: 4, max_bytes: 4_096, barrier_slots: 16, clock_skew: 2], opts)
      )

  defp snapshot(body, received, requested \\ nil),
    do: %Snapshot{
      revision: :crypto.strong_rand_bytes(24),
      record: record(body, received, requested),
      age_margin: 2
    }

  defp record(body, received, requested \\ nil) do
    {:ok, source, _config} = Source.from_input({:binary, body}, sources: %{})
    request = Req.new(url: "https://example.test/image")

    response = %{
      status: 200,
      headers: %{"cache-control" => ["max-age=60"], "etag" => ["\"#{body}\""]},
      request: request
    }

    origin = Origin.from_response(response, {requested || received, received})
    Record.new(source, :crypto.hash(:sha256, body), origin, received)
  end
end
