defmodule ImagePipe.Source.Mounts do
  @moduledoc false

  # Validated source mounts and the routing tables built from their match
  # rules. See `ImagePipe.Source` for the configuration shape.

  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.URL

  defstruct mounts: %{}, prefixes: %{}, schemes: %{}, path: nil

  @type t :: %__MODULE__{
          mounts: %{atom() => {module(), keyword()}},
          prefixes: %{String.t() => atom()},
          schemes: %{String.t() => atom()},
          path: atom() | nil
        }

  @builtin_scheme_identifiers %{"http" => URL, "https" => URL, "s3" => Object}
  @identifiers [Path, URL, Object]
  @scheme_pattern ~r/\A[a-z][a-z0-9+.\-]*\z/

  @mount_schema NimbleOptions.new!(
                  adapter: [type: :atom, required: true],
                  match: [type: :any, required: true],
                  options: [type: :keyword_list, default: []]
                )

  @spec validate(term()) :: {:ok, t()} | {:error, {:source, term()}}
  def validate(sources) when is_list(sources) do
    if Keyword.keyword?(sources) and unique_names?(sources),
      do: add_mounts(sources),
      else:
        {:error,
         {:source, {:invalid_sources, "expected a keyword list of uniquely named mounts"}}}
  end

  def validate(_sources),
    do: {:error, {:source, {:invalid_sources, "expected a keyword list of named mounts"}}}

  @doc false
  @spec custom_schemes(t()) :: [String.t()]
  def custom_schemes(%__MODULE__{schemes: schemes}),
    do: schemes |> Map.keys() |> Enum.reject(&Map.has_key?(@builtin_scheme_identifiers, &1))

  @doc false
  @spec fetch(t(), atom()) :: {:ok, module(), keyword()} | {:error, {:source, :missing_adapter}}
  def fetch(%__MODULE__{mounts: mounts}, name) do
    case mounts do
      %{^name => {module, opts}} -> {:ok, module, opts}
      _mounts -> {:error, {:source, :missing_adapter}}
    end
  end

  @doc """
  Selects the mount for a plan source. Returns the mount name and the source as
  the adapter receives it (prefix or custom scheme removed).
  """
  @spec route(struct(), t()) :: {:ok, atom(), struct()} | {:error, {:source, atom()}}
  def route(%Path{scheme: nil, segments: [first | rest]} = source, %__MODULE__{} = mounts) do
    case mounts.prefixes do
      %{^first => name} -> path_route(name, %{source | segments: rest})
      _prefixes when is_nil(mounts.path) -> {:error, {:source, :not_found}}
      _prefixes -> path_route(mounts.path, source)
    end
  end

  def route(%Path{scheme: scheme} = source, %__MODULE__{} = mounts) when is_binary(scheme) do
    case mounts.schemes do
      %{^scheme => name} -> path_route(name, %{source | scheme: nil})
      _schemes -> {:error, {:source, :not_found}}
    end
  end

  def route(%URL{scheme: scheme} = source, %__MODULE__{} = mounts),
    do: scheme_route(Atom.to_string(scheme), source, mounts)

  def route(%Object{scheme: scheme} = source, %__MODULE__{} = mounts),
    do: scheme_route(scheme, source, mounts)

  def route(_source, _mounts), do: {:error, {:source, :missing_adapter}}

  defp scheme_route(scheme, source, mounts) do
    case mounts.schemes do
      %{^scheme => name} -> {:ok, name, source}
      _schemes -> {:error, {:source, :missing_adapter}}
    end
  end

  # Origins may normalize dot segments, and a bare prefix names no source.
  defp path_route(name, %Path{segments: segments} = source) do
    if segments == [] or Enum.any?(segments, &(&1 in ["", ".", ".."])),
      do: {:error, {:source, :denied_path}},
      else: {:ok, name, source}
  end

  defp unique_names?(sources), do: sources |> Keyword.keys() |> then(&(Enum.uniq(&1) == &1))

  defp add_mounts(sources) do
    Enum.reduce_while(sources, {:ok, %__MODULE__{}}, fn {name, mount}, {:ok, mounts} ->
      case add_mount(mounts, name, mount) do
        {:ok, mounts} -> {:cont, {:ok, mounts}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_mount(mounts, name, mount) when is_list(mount) do
    with {:ok, mount} <- validate_mount_shape(name, mount),
         {:ok, rules} <- parse_match(name, Keyword.fetch!(mount, :match)),
         module = Keyword.fetch!(mount, :adapter),
         :ok <- check_identifiers(name, module, rules),
         {:ok, opts} <- validate_adapter_options(module, Keyword.fetch!(mount, :options)),
         {:ok, mounts} <- add_rules(mounts, name, rules) do
      {:ok, %{mounts | mounts: Map.put(mounts.mounts, name, {module, opts})}}
    end
  end

  defp add_mount(_mounts, name, _mount),
    do: invalid_mount(name, "expected a keyword list with :adapter, :match, and :options")

  defp validate_mount_shape(name, mount) do
    case NimbleOptions.validate(mount, @mount_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> invalid_mount(name, Exception.message(error))
    end
  end

  defp parse_match(_name, :path), do: {:ok, [{:path, nil}]}

  defp parse_match(name, match) when is_list(match) and match != [] do
    if Keyword.keyword?(match) and Enum.all?(Keyword.keys(match), &(&1 in [:prefix, :scheme])) do
      rules =
        Enum.flat_map(match, fn {kind, values} -> Enum.map(List.wrap(values), &{kind, &1}) end)

      if rules != [] and Enum.all?(rules, &valid_rule?/1),
        do: {:ok, rules},
        else: invalid_mount(name, "invalid match rule #{inspect(match)}")
    else
      invalid_mount(name, "match must be :path or a keyword list of :prefix and :scheme")
    end
  end

  defp parse_match(name, _match),
    do: invalid_mount(name, "match must be :path or a keyword list of :prefix and :scheme")

  defp valid_rule?({:prefix, prefix}) when is_binary(prefix),
    do: prefix not in ["", ".", ".."] and not String.contains?(prefix, "/")

  defp valid_rule?({:scheme, scheme}) when is_binary(scheme),
    do: Regex.match?(@scheme_pattern, scheme)

  defp valid_rule?(_rule), do: false

  # The identifier struct a rule routes: http, https, and s3 schemes route URL
  # and object identifiers; a prefix or any other scheme routes paths.
  defp rule_identifier({:scheme, scheme}), do: Map.get(@builtin_scheme_identifiers, scheme, Path)
  defp rule_identifier(_rule), do: Path

  defp check_identifiers(name, module, rules) do
    supported = module.identifiers()
    needed = rules |> Enum.map(&rule_identifier/1) |> Enum.uniq()

    cond do
      not (is_list(supported) and Enum.all?(supported, &(&1 in @identifiers))) ->
        invalid_mount(name, "#{inspect(module)}.identifiers/0 returned #{inspect(supported)}")

      Enum.all?(needed, &(&1 in supported)) ->
        :ok

      true ->
        invalid_mount(
          name,
          "#{inspect(module)} resolves #{inspect(supported)}, but match needs #{inspect(needed)}"
        )
    end
  end

  defp validate_adapter_options(module, options) do
    case module.validate_options(options) do
      {:ok, validated} when is_list(validated) -> {:ok, order_like(options, validated)}
      {:error, {:source, _reason}} = error -> error
      {:error, reason} -> {:error, {:source, reason}}
      _other -> {:error, {:source, :invalid_adapter_config}}
    end
  end

  # Keep the host's option order, then any keys the adapter added.
  defp order_like(input, validated) do
    keys = Keyword.keys(input)
    ordered = for key <- keys, Keyword.has_key?(validated, key), do: {key, validated[key]}
    ordered ++ Enum.reject(validated, fn {key, _value} -> key in keys end)
  end

  defp add_rules(mounts, name, rules) do
    Enum.reduce_while(rules, {:ok, mounts}, fn rule, {:ok, acc} ->
      case add_rule(acc, name, rule) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_rule(%{path: nil} = mounts, name, {:path, nil}), do: {:ok, %{mounts | path: name}}

  defp add_rule(%{path: other}, name, {:path, nil}),
    do: invalid_mount(name, "match :path is already used by mount #{inspect(other)}")

  defp add_rule(mounts, name, {:prefix, prefix}) do
    case mounts.prefixes do
      %{^prefix => other} ->
        invalid_mount(
          name,
          "prefix #{inspect(prefix)} is already used by mount #{inspect(other)}"
        )

      prefixes ->
        {:ok, %{mounts | prefixes: Map.put(prefixes, prefix, name)}}
    end
  end

  defp add_rule(mounts, name, {:scheme, scheme}) do
    case mounts.schemes do
      %{^scheme => other} ->
        invalid_mount(
          name,
          "scheme #{inspect(scheme)} is already used by mount #{inspect(other)}"
        )

      schemes ->
        {:ok, %{mounts | schemes: Map.put(schemes, scheme, name)}}
    end
  end

  defp invalid_mount(name, reason), do: {:error, {:source, {:invalid_mount, name, reason}}}
end
