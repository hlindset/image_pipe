defmodule ImagePipe.Plan.Source.Identity do
  @moduledoc false

  @spec valid?(term()) :: boolean()
  def valid?(identity) when is_list(identity) and identity != [] do
    Keyword.keyword?(identity) and keyword_material?(identity)
  end

  def valid?(_identity), do: false

  defp keyword_material?(keyword) do
    Enum.all?(keyword, fn {key, value} -> is_atom(key) and material?(value) end)
  end

  defp material?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp material?(value) when is_atom(value), do: not module_atom?(value)

  defp material?(value) when is_list(value) do
    if Keyword.keyword?(value) do
      keyword_material?(value)
    else
      Enum.all?(value, &material?/1)
    end
  end

  defp material?(_value), do: false

  defp module_atom?(value) do
    value
    |> Atom.to_string()
    |> String.starts_with?("Elixir.")
  end
end
