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
end
