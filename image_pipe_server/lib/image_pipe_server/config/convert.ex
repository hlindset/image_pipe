defmodule ImagePipeServer.Config.Convert do
  @moduledoc """
  Converts configuration tree values to library option values, driven by the
  library's own NimbleOptions schemas.

  File values keep their TOML types; environment values arrive as
  `{:env, string}` and are parsed to the target type. Lists in the environment
  are comma-separated. A `_FILE` variable arrives as
  `{:env_file, variable, path}`: for a setting the schema knows, its value is
  the file's contents without trailing whitespace; otherwise, when the schema
  has `<name>_file` (such as `token_file`), the variable sets that setting to
  `path` itself.

  Settings the schema types as simple values convert here: strings, integers,
  floats, booleans, enumerated atoms, lists, keyword lists with known keys,
  maps, and tagged tuples written as a single-entry table
  (`{ fallback = 60 }`). A `{:custom, ...}` type receives the scalar as
  written, for the library's validator to check. Functions, modules, and
  untyped settings are not supported in the configuration file.

  A schema may also use `{:convert, fun, description}` for an explicit
  conversion. `fun` receives the value and its path and returns
  `{:ok, value}` or `{:error, path, message}`. `description` documents the
  accepted value for `ImagePipeServer.Config.Reference`: a string, or the
  schema of the table `fun` converts.

  Error messages name the setting, never its value.
  """

  alias ImagePipeServer.ConfigError

  @type path :: [String.t() | non_neg_integer()]
  @type result :: {:ok, term()} | {:error, path(), String.t()}

  @unsupported "not supported in the configuration file"

  @doc "Converts a table with `schema`, raising `ImagePipeServer.ConfigError`."
  @spec options!(term(), keyword(), path()) :: keyword()
  def options!(table, schema, path) do
    case options(table, schema, path) do
      {:ok, options} -> options
      {:error, path, message} -> raise ConfigError, error_message(path, message)
    end
  end

  @doc "Formats a conversion error."
  @spec error_message(path(), String.t()) :: String.t()
  def error_message(path, message), do: "invalid configuration: #{format_path(path)}: #{message}"

  @doc "Converts a table to a keyword list with `schema`."
  @spec options(term(), keyword(), path()) :: {:ok, keyword()} | {:error, path(), String.t()}
  def options(%{} = table, schema, path) do
    table
    |> file_settings(schema)
    |> Enum.sort()
    |> map_ok(fn {key, value} ->
      case find_key(schema, key) do
        {:ok, name, spec} ->
          with {:ok, value} <- value(Keyword.get(spec, :type, :any), value, path ++ [key]),
               do: {:ok, {name, value}}

        :error ->
          {:error, path ++ [key], "unknown setting"}
      end
    end)
  end

  def options(_value, _schema, path), do: {:error, path, "expected a table"}

  @doc "An explicit conversion of a table with `schema`."
  @spec table(keyword()) :: {:convert, function(), keyword()}
  def table(schema), do: {:convert, &options(&1, schema, &2), schema}

  @doc "Reads a string from a file or environment value."
  @spec string(term(), path()) :: result()
  def string({:env_file, _variable, _file} = value, path) do
    with {:ok, contents} <- read_file(value, path), do: string(contents, path)
  end

  def string({:env, value}, _path), do: {:ok, value}
  def string(value, _path) when is_binary(value), do: {:ok, value}
  def string(_value, path), do: {:error, path, "expected a string"}

  @doc "Converts one value to `type`."
  @spec value(term(), term(), path()) :: result()
  def value(type, {:env_file, _variable, _file} = value, path) do
    with {:ok, contents} <- read_file(value, path), do: value(type, contents, path)
  end

  def value({:convert, fun, _description}, value, path), do: fun.(value, path)

  def value(:string, value, path), do: string(value, path)

  def value(type, value, path)
      when type in [:integer, :pos_integer, :non_neg_integer, :timeout],
      do: integer(value, path)

  def value(:float, value, _path) when is_float(value), do: {:ok, value}
  def value(:float, value, _path) when is_integer(value), do: {:ok, value / 1}

  def value(:float, {:env, raw}, path) do
    case Float.parse(raw) do
      {float, ""} -> {:ok, float}
      _invalid -> {:error, path, "expected a number"}
    end
  end

  def value(:float, _value, path), do: {:error, path, "expected a number"}

  def value(:boolean, value, _path) when is_boolean(value), do: {:ok, value}
  def value(:boolean, {:env, "true"}, _path), do: {:ok, true}
  def value(:boolean, {:env, "false"}, _path), do: {:ok, false}
  def value(:boolean, _value, path), do: {:error, path, "expected true or false"}

  def value({:in, choices}, value, path) do
    case Enum.find(choices, &choice?(&1, value)) do
      nil -> {:error, path, "expected one of #{describe(choices)}"}
      choice -> {:ok, choice}
    end
  end

  def value({:list, type}, {:env, raw}, path) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&{:env, String.trim(&1)})
    |> value_list(type, path)
  end

  def value({:list, type}, value, path) when is_list(value), do: value_list(value, type, path)
  def value({:list, _type}, _value, path), do: {:error, path, "expected a list"}

  def value({:map, key_type, value_type}, %{} = table, path) do
    with {:ok, pairs} <-
           map_ok(Enum.sort(table), fn {key, value} ->
             with {:ok, key} <- map_key(key_type, key, path ++ [key]),
                  {:ok, value} <- value(value_type, value, path ++ [key]),
                  do: {:ok, {key, value}}
           end),
         do: {:ok, Map.new(pairs)}
  end

  def value({:map, _key_type, _value_type}, _value, path), do: {:error, path, "expected a table"}

  def value({:tuple, [{:in, tags}, type]}, %{} = table, path) when map_size(table) == 1 do
    [{tag, value}] = Map.to_list(table)

    with {:ok, tag} <- value({:in, tags}, tag, path),
         {:ok, value} <- value(type, value, path ++ [tag_name(tag)]),
         do: {:ok, {tag, value}}
  end

  def value({:tuple, [{:in, tags}, _type]}, _value, path),
    do: {:error, path, "expected a table with one of #{describe(tags)}"}

  def value({:or, types}, value, path), do: first_ok(types, value, path)

  def value({:custom, _module, _function, _args}, {:env, raw}, _path), do: {:ok, raw}

  def value({:custom, _module, _function, _args}, value, path) do
    if scalar?(value), do: {:ok, value}, else: {:error, path, @unsupported}
  end

  def value(_type, _value, path), do: {:error, path, @unsupported}

  # A `_FILE` variable for an unknown `name` sets `name_file` when the schema
  # has it, overriding that setting from the file.
  defp file_settings(table, schema) do
    Enum.reduce(table, table, fn
      {key, {:env_file, _variable, file}}, acc ->
        file_key = key <> "_file"

        if find_key(schema, key) == :error and find_key(schema, file_key) != :error,
          do: acc |> Map.delete(key) |> Map.put(file_key, {:env, file}),
          else: acc

      _entry, acc ->
        acc
    end)
  end

  # The error names the variable; the file's path and contents may be secret.
  defp read_file({:env_file, variable, file}, path) do
    case File.read(file) do
      {:ok, contents} -> {:ok, {:env, String.trim_trailing(contents)}}
      {:error, reason} -> {:error, path, "cannot read #{variable}: #{:file.format_error(reason)}"}
    end
  end

  # Keyword lists come through `value/3` with their `keys:` spec, which the
  # type alone doesn't carry, so `find_key/2` routes them here.
  defp keyword_spec(spec) do
    case Keyword.fetch(spec, :keys) do
      {:ok, keys} -> Keyword.put(spec, :type, table(keys))
      :error -> spec
    end
  end

  defp find_key(schema, key) do
    Enum.find_value(schema, :error, fn {name, spec} ->
      if Atom.to_string(name) == key, do: {:ok, name, keyword_spec(spec)}
    end)
  end

  defp integer(value, _path) when is_integer(value), do: {:ok, value}

  defp integer({:env, raw}, path) do
    case Integer.parse(raw) do
      {integer, ""} -> {:ok, integer}
      _invalid -> {:error, path, "expected an integer"}
    end
  end

  defp integer(_value, path), do: {:error, path, "expected an integer"}

  defp choice?(nil, _value), do: false
  defp choice?(choice, _value) when is_boolean(choice), do: false
  defp choice?(choice, {:env, raw}) when is_atom(choice), do: Atom.to_string(choice) == raw
  defp choice?(choice, value) when is_atom(choice), do: Atom.to_string(choice) == value
  defp choice?(choice, {:env, raw}) when is_integer(choice), do: Integer.to_string(choice) == raw
  defp choice?(choice, value), do: choice === value

  defp describe(first..last//_step), do: "#{first}..#{last}"

  defp describe(choices),
    do:
      choices |> Enum.reject(&(is_nil(&1) or is_boolean(&1))) |> Enum.map_join(", ", &to_string/1)

  defp tag_name(tag), do: Atom.to_string(tag)

  defp value_list(values, type, path) do
    values
    |> Enum.with_index()
    |> map_ok(fn {value, index} -> value(type, value, path ++ [index]) end)
  end

  defp map_key(:string, key, _path), do: {:ok, key}

  # Keys name formats, metrics, and similar library atoms, so they must exist.
  defp map_key(:atom, key, path) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, path, "unknown key"}
  end

  defp map_key(_type, _key, path), do: {:error, path, @unsupported}

  defp first_ok(types, value, path) do
    results = for type <- types, type != nil, do: value(type, value, path)

    case Enum.find(results, &match?({:ok, _value}, &1)) do
      {:ok, _value} = ok -> ok
      nil -> alternatives_error(results, path)
    end
  end

  # An error below `path` means an alternative matched the value's shape and
  # failed inside it; report that one rather than a generic mismatch.
  defp alternatives_error(results, path) do
    deeper = Enum.find(results, fn {:error, error_path, _message} -> error_path != path end)

    cond do
      deeper ->
        deeper

      Enum.all?(results, &match?({:error, _path, @unsupported}, &1)) ->
        {:error, path, @unsupported}

      true ->
        {:error, path, "invalid value"}
    end
  end

  defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, _path, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp format_path([first | rest]) do
    Enum.reduce(rest, to_string(first), fn
      index, acc when is_integer(index) -> "#{acc}[#{index}]"
      key, acc -> "#{acc}.#{key}"
    end)
  end
end
