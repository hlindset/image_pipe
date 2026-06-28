defmodule ImagePipe.Plan.Output.AvifOptions do
  @moduledoc "libvips `heifsave` (AVIF) encoder options (neutral; imgproxy `avifo`/`AVIF_SPEED` translate here)."
  defstruct [:subsample_mode, :effort]

  @type t :: %__MODULE__{
          subsample_mode: nil | :auto | :on | :off,
          effort: nil | 0..9
        }

  @doc "Sparse override: non-nil fields of `over` win; nil keeps `base`."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @doc "True when no field is set."
  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o),
    do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
