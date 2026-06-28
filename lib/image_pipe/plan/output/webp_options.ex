defmodule ImagePipe.Plan.Output.WebpOptions do
  @moduledoc "libvips `webpsave` encoder options (neutral; imgproxy `webpo` translates here)."
  defstruct [:lossless, :near_lossless, :smart_subsample, :preset, :effort]

  @type t :: %__MODULE__{
          lossless: nil | boolean(),
          near_lossless: nil | boolean(),
          smart_subsample: nil | boolean(),
          preset: nil | :default | :photo | :picture | :drawing | :icon | :text,
          effort: nil | 0..6
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
