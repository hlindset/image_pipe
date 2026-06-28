defmodule ImagePipe.Plan.Output.PngOptions do
  @moduledoc "libvips `pngsave` encoder options (neutral; imgproxy `pngo` translates here)."
  defstruct [:interlace, :palette, :bitdepth, :filter]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          palette: nil | boolean(),
          bitdepth: nil | 1 | 2 | 4 | 8 | 16,
          filter: nil | :none | :sub | :up | :avg | :paeth | :all
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
