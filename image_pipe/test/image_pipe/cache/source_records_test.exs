defmodule ImagePipe.Cache.SourceRecordsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.SourceRecords

  setup do
    table = Module.concat(__MODULE__, "T#{System.unique_integer([:positive])}")
    start_supervised!({SourceRecords, table})
    %{table: table}
  end

  test "keeps at most 10,000 records", %{table: table} do
    for i <- 1..10_001, do: :ok = SourceRecords.put(table, "key#{i}", %{i: i})

    assert :ets.info(table, :size) == 10_000
    assert SourceRecords.get(table, "key10001") == %{i: 10_001}
  end

  test "putting nil forgets a record", %{table: table} do
    :ok = SourceRecords.put(table, "key", %{i: 1})
    :ok = SourceRecords.put(table, "key", nil)

    assert SourceRecords.get(table, "key") == nil
  end
end
