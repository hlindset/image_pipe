defmodule ImagePipeServer.Config.Tree do
  @moduledoc """
  Reads the configuration tree from the TOML file and the environment.

  The file is named by `IPS_CONFIG`, or the default path, which may be absent.
  Environment variables flatten the same tree: `IPS_` followed by the levels
  joined with `__`, lowercased. A variable overrides the matching leaf in the
  file. A variable ending in `_FILE` reads its value from that file, without
  trailing whitespace.

  File values keep their TOML types. Environment values are strings, tagged
  `{:env, string}` so conversion can parse them.
  """

  alias ImagePipeServer.Config.TomlError
  alias ImagePipeServer.ConfigError

  @prefix "IPS_"
  @config_var "IPS_CONFIG"

  @type t :: %{String.t() => term()}

  @spec read!(%{String.t() => String.t()}, Path.t()) :: t()
  def read!(env, default_path) do
    merge(file!(env, default_path), env!(env))
  end

  defp file!(env, default_path) do
    case Map.fetch(env, @config_var) do
      {:ok, path} ->
        if File.regular?(path),
          do: decode!(path),
          else: raise(ConfigError, "#{@config_var} names a missing file: #{path}")

      :error ->
        if File.regular?(default_path), do: decode!(default_path), else: %{}
    end
  end

  defp decode!(path) do
    case Toml.decode_file(path) do
      {:ok, tree} ->
        tree

      {:error, {:invalid_toml, reason}} ->
        raise ConfigError, TomlError.message(reason, path)

      {:error, reason} ->
        raise ConfigError, "cannot read #{path}: #{inspect(reason)}"
    end
  end

  defp env!(env) do
    env
    |> Enum.filter(fn {name, _value} ->
      String.starts_with?(name, @prefix) and name != @config_var
    end)
    |> Enum.sort()
    |> Enum.map(&env_entry!(&1, env))
    |> Enum.reduce(%{}, fn {path, value}, tree -> put_leaf!(tree, path, value, []) end)
  end

  defp env_entry!({name, value}, env) do
    levels = name |> String.replace_prefix(@prefix, "") |> String.split("__")

    if Enum.any?(levels, &(&1 == "")),
      do: raise(ConfigError, "#{name} has an empty level")

    path = Enum.map(levels, &String.downcase/1)

    case String.split(name, ~r/_FILE\z/) do
      [plain, ""] -> {file_path!(path), {:env, read_secret!(name, plain, value, env)}}
      [_name] -> {path, {:env, value}}
    end
  end

  defp file_path!(path) do
    List.update_at(path, -1, &String.replace_suffix(&1, "_file", ""))
  end

  defp read_secret!(name, plain, path, env) do
    if Map.has_key?(env, plain),
      do: raise(ConfigError, "both #{plain} and #{name} are set")

    case File.read(path) do
      {:ok, contents} -> String.trim_trailing(contents)
      {:error, reason} -> raise ConfigError, "cannot read #{name}: #{:file.format_error(reason)}"
    end
  end

  defp put_leaf!(tree, [key], value, parents) do
    if is_map(Map.get(tree, key)), do: conflict!([key | parents])
    Map.put(tree, key, value)
  end

  defp put_leaf!(tree, [key | rest], value, parents) do
    case Map.get(tree, key, %{}) do
      %{} = child -> Map.put(tree, key, put_leaf!(child, rest, value, [key | parents]))
      _leaf -> conflict!([key | parents])
    end
  end

  defp conflict!(reversed_path) do
    path = reversed_path |> Enum.reverse() |> Enum.join(".")
    raise ConfigError, "environment sets both a value and a table at #{path}"
  end

  @doc false
  @spec merge(t(), t()) :: t()
  def merge(base, override) do
    Map.merge(base, override, fn
      _key, %{} = left, %{} = right -> merge(left, right)
      _key, _left, right -> right
    end)
  end
end
