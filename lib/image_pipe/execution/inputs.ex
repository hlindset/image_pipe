defmodule ImagePipe.Execution.Inputs do
  @moduledoc false
  @derive {Inspect, except: [:headers, :cookies]}
  defstruct headers: [], cookies: %{}

  @type t :: %__MODULE__{
          headers: [{String.t(), String.t()}],
          cookies: %{String.t() => String.t()}
        }

  def new!(options) do
    unless Keyword.keyword?(options) and
             Enum.all?(Keyword.keys(options), &(&1 in [:headers, :cookies])) and
             length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) do
      invalid!()
    end

    headers = Keyword.get(options, :headers, [])
    cookies = Keyword.get(options, :cookies, %{})

    unless is_list(headers) and Enum.all?(headers, &valid_header?/1) and
             is_map(cookies) and Enum.all?(cookies, &valid_cookie?/1), do: invalid!()

    %__MODULE__{
      headers: Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end),
      cookies: cookies
    }
  end

  def storage_material(%__MODULE__{} = inputs, configured) do
    names =
      configured
      |> Enum.flat_map(fn
        {:header, name} -> [String.downcase(name)]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    headers =
      Enum.map(names, fn name -> {name, for({^name, value} <- inputs.headers, do: value)} end)

    cookies =
      configured
      |> Enum.flat_map(fn
        {:cookie, name} -> [name]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        case Map.fetch(inputs.cookies, name) do
          {:ok, value} -> [{name, value}]
          :error -> []
        end
      end)

    {[headers: headers, cookies: cookies], names}
  end

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value),
    do:
      Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name) and
        not String.match?(value, ~r/[\x00-\x1F\x7F]/)

  defp valid_header?(_value), do: false
  defp valid_cookie?({name, value}), do: is_binary(name) and name != "" and is_binary(value)
  defp invalid!, do: raise(ArgumentError, "request_inputs must contain valid headers and cookies")
end
