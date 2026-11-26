defmodule ProsemirrorEx.Model.SchemaEtsTest do
  use ExUnit.Case, async: false

  import ProsemirrorEx.TestHelpers, only: [test_schema: 0]

  test "does not leak ETS tables across 100 Schema.new/1 calls" do
    # Warm up once
    _ = test_schema()
    before_tables = :ets.all()

    for _ <- 1..100 do
      _ = test_schema()
    end

    after_tables = :ets.all()
    assert MapSet.difference(MapSet.new(after_tables), MapSet.new(before_tables)) == MapSet.new()

    owned_tables =
      Enum.filter(after_tables, fn table ->
        :ets.info(table, :owner) == self()
      end)

    assert owned_tables == []
  end
end
