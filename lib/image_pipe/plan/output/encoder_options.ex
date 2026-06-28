defmodule ImagePipe.Plan.Output.EncoderOptions do
  @moduledoc """
  Shared `merge/2` + `all_nil?/1` for the per-format encoder-option structs
  (`JpegOptions`/`PngOptions`/`WebpOptions`/`AvifOptions`/`JxlOptions`). `use` it
  after the struct's `defstruct`/`@type t` so each module keeps its own typed API
  without duplicating the (identical) sparse-merge logic.
  """

  defmacro __using__(_opts) do
    quote do
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
  end
end
