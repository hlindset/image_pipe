defmodule ImagePipe.Execution.Inputs do
  @moduledoc false
  @derive {Inspect, except: [:headers, :cookies]}
  defstruct headers: [], cookies: %{}

  @type t :: %__MODULE__{
          headers: [{String.t(), String.t()}],
          cookies: %{String.t() => String.t()}
        }

  @doc false
  def schema do
    [
      headers: [
        type: {:list, {:custom, __MODULE__, :validate_header, []}},
        type_doc: "list of `{String.t(), String.t()}`",
        default: [],
        doc: """
        Header values, such as `[{"x-tenant", "one"}]`. Names must be valid header \
        names, and values can't contain control characters.
        """
      ],
      cookies: [
        type: {:map, {:custom, __MODULE__, :validate_cookie_name, []}, :string},
        type_doc: "map of `t:String.t/0` to `t:String.t/0`",
        default: %{},
        doc: "Cookie values by name, such as `%{\"session\" => \"abc\"}`."
      ]
    ]
  end

  def new(options) do
    %__MODULE__{
      headers:
        options
        |> Keyword.get(:headers, [])
        |> Enum.map(fn {name, value} -> {String.downcase(name), value} end),
      cookies: Keyword.get(options, :cookies, %{})
    }
  end

  @doc false
  def validate_header({name, value} = header) when is_binary(name) and is_binary(value) do
    if Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name) and
         not String.match?(value, ~r/[\x00-\x1F\x7F]/),
       do: {:ok, header},
       else: {:error, "expected a valid header name and value, got: #{inspect(name)}"}
  end

  def validate_header(header),
    do: {:error, "expected a {name, value} pair of strings, got: #{inspect(header)}"}

  @doc false
  def validate_cookie_name(name) when is_binary(name) and name != "", do: {:ok, name}
  def validate_cookie_name(name), do: {:error, "expected a cookie name, got: #{inspect(name)}"}

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
end
