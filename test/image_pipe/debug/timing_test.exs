defmodule ImagePipe.Debug.TimingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Timing

  test "measure/1 returns the function result and a non-negative microsecond duration" do
    {result, us} = Timing.measure(fn -> :work_done end)

    assert result == :work_done
    assert is_integer(us)
    assert us >= 0
  end
end
