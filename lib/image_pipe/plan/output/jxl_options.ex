defmodule ImagePipe.Plan.Output.JxlOptions do
  @moduledoc """
  libvips `jxlsave` encoder options (neutral). `effort` is optional; when unset
  the encoder applies libvips' default (7) — see `ImagePipe.Output.Encoder`.
  """
  defstruct [:effort]

  @type t :: %__MODULE__{effort: nil | 1..9}

  @doc "Sparse override: non-nil fields of `over` win; nil keeps `base`."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @doc "True when no field is set."
  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: is_nil(o.effort)
end
