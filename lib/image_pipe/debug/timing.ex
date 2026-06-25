defmodule ImagePipe.Debug.Timing do
  @moduledoc false

  @doc """
  Runs `fun`, returning `{result, microseconds}` where microseconds is the
  wall-clock duration of `fun`. Used to record per-stage durations for the
  `Server-Timing` debug header.
  """
  @spec measure((-> result)) :: {result, non_neg_integer()} when result: term()
  def measure(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - start}
  end
end
