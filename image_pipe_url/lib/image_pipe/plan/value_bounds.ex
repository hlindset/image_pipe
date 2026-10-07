defmodule ImagePipe.Plan.ValueBounds do
  @moduledoc false

  @max_axis 2_147_483_647
  @max_padding 1_000_000_000

  defguard axis?(value) when is_integer(value) and value > 0 and value <= @max_axis

  defguard scale?(value) when is_number(value) and value > 0 and value <= @max_axis

  defguard length?(value) when is_number(value) and abs(value) <= @max_axis

  defguard padding?(value)
           when is_integer(value) and value >= 0 and value <= @max_padding

  defguard blur?(value) when is_number(value) and value >= 0 and value <= 1000

  defguard sharpen?(value)
           when is_number(value) and (value == 0 or (value >= 0.000001 and value <= 10))
end
