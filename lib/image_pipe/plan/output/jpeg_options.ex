defmodule ImagePipe.Plan.Output.JpegOptions do
  @moduledoc """
  libvips `jpegsave` encoder options (product-neutral; the imgproxy parser
  translates `jpgo` into this). Every field is optional (`nil` ⇒ emit no token,
  leaving libvips' default).
  """
  defstruct [
    :interlace,
    :subsample_mode,
    :trellis_quant,
    :overshoot_deringing,
    :optimize_scans,
    :quant_table
  ]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          subsample_mode: nil | :auto | :on | :off,
          trellis_quant: nil | boolean(),
          overshoot_deringing: nil | boolean(),
          optimize_scans: nil | boolean(),
          quant_table: nil | 0..8
        }

  @doc "Sparse override: non-nil fields of `over` win; nil keeps `base`."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over) do
    Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)
  end

  @doc "True when no field is set."
  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o),
    do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
