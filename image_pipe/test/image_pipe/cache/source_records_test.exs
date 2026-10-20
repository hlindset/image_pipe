defmodule ImagePipe.Cache.SourceRecordsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.SourceRecords

  setup do
    table = Module.concat(__MODULE__, "T#{System.unique_integer([:positive])}")
    start_supervised!({SourceRecords, table})
    %{table: table}
  end

  test "keeps at most the given number of records", %{table: table} do
    for i <- 1..4, do: :ok = SourceRecords.put(table, "key#{i}", %{i: i}, 3)

    assert :ets.info(table, :size) == 3
    assert SourceRecords.get(table, "key4") == %{i: 4}
  end

  test "replacing a record in a full table evicts nothing", %{table: table} do
    for i <- 1..3, do: :ok = SourceRecords.put(table, "key#{i}", %{i: i}, 3)
    :ok = SourceRecords.put(table, "key2", %{i: 20}, 3)

    assert Enum.map(1..3, &SourceRecords.get(table, "key#{&1}")) == [%{i: 1}, %{i: 20}, %{i: 3}]
  end

  test "putting nil forgets a record", %{table: table} do
    :ok = SourceRecords.put(table, "key", %{i: 1}, 3)
    :ok = SourceRecords.put(table, "key", nil, 3)

    assert SourceRecords.get(table, "key") == nil
  end

  test "put_new/4 keeps a record already in the table", %{table: table} do
    :ok = SourceRecords.put(table, "key", %{i: 1}, 3)
    :ok = SourceRecords.put_new(table, "key", %{i: 2}, 3)
    :ok = SourceRecords.put_new(table, "other", %{i: 3}, 3)

    assert SourceRecords.get(table, "key") == %{i: 1}
    assert SourceRecords.get(table, "other") == %{i: 3}
  end

  test "put_new/4 into a full table evicts first", %{table: table} do
    for i <- 1..4, do: :ok = SourceRecords.put_new(table, "key#{i}", %{i: i}, 3)

    assert :ets.info(table, :size) == 3
    assert SourceRecords.get(table, "key4") == %{i: 4}
  end

  test "a full table forgets records that weren't used recently", %{table: table} do
    :rand.seed(:exsss, {1, 2, 3})
    limit = 1_000

    for i <- 1..limit, do: :ok = SourceRecords.put(table, "old#{i}", %{i: i}, limit, 0)
    for i <- 1..200, do: SourceRecords.get(table, "old#{i}", 5)
    for i <- 1..600, do: :ok = SourceRecords.put(table, "new#{i}", %{i: i}, limit, 10)

    used = Enum.count(1..200, &:ets.member(table, "old#{&1}"))
    new = Enum.count(1..600, &:ets.member(table, "new#{&1}"))

    # Random eviction would keep about 110 of the used and 450 of the new.
    assert used >= 170
    assert new >= 570
  end
end
