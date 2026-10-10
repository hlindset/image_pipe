defmodule ImagePipe.Source.Routes do
  @moduledoc false

  # Validated sources and the routing tables built from their match rules.
  # See `ImagePipe.Source` for the configuration shape.

  alias ImagePipe.Source.Object
  alias ImagePipe.Source.Path
  alias ImagePipe.Source.URL

  defstruct sources: %{}, prefixes: %{}, schemes: %{}, path: nil

  @type t :: %__MODULE__{
          sources: %{atom() => {module(), keyword()}},
          prefixes: %{String.t() => atom()},
          schemes: %{String.t() => atom()},
          path: atom() | nil
        }

  @builtin_scheme_identifiers %{"http" => URL, "https" => URL, "s3" => Object}
  @identifiers [Path, URL, Object]
  @scheme_pattern ~r/\A[a-z][a-z0-9+.\-]*\z/

  @source_schema NimbleOptions.new!(
                   adapter: [type: :atom, required: true],
                   match: [type: :any, required: true],
                   options: [type: :keyword_list, default: []]
                 )

  @spec validate(term()) :: {:ok, t()} | {:error, {:source, term()}}
  def validate(sources) when is_list(sources) do
    if Keyword.keyword?(sources) and unique_names?(sources) do
      with {:ok, routes} <- add_sources(sources),
           :ok <- unique_file_roots(routes),
           do: {:ok, routes}
    else
      {:error, {:source, {:invalid_sources, "expected a keyword list of uniquely named sources"}}}
    end
  end

  def validate(_sources),
    do: {:error, {:source, {:invalid_sources, "expected a keyword list of named sources"}}}

  @doc false
  @spec scheme?(t(), String.t()) :: boolean()
  def scheme?(%__MODULE__{schemes: schemes}, scheme), do: Map.has_key?(schemes, scheme)

  @doc false
  @spec fetch(t(), atom()) :: {:ok, module(), keyword()} | {:error, {:source, :missing_adapter}}
  def fetch(%__MODULE__{sources: sources}, name) do
    case sources do
      %{^name => {module, opts}} -> {:ok, module, opts}
      _sources -> {:error, {:source, :missing_adapter}}
    end
  end

  @doc """
  Selects the configured source for a plan source. Returns that source's name
  and the plan source as its adapter receives it (prefix or custom scheme
  removed).
  """
  @spec route(struct(), t()) :: {:ok, atom(), struct()} | {:error, {:source, atom()}}
  def route(%Path{scheme: nil, segments: [first | rest]} = source, %__MODULE__{} = routes) do
    case routes.prefixes do
      %{^first => name} -> path_route(name, %{source | segments: rest})
      _prefixes when is_nil(routes.path) -> {:error, {:source, :not_found}}
      _prefixes -> path_route(routes.path, source)
    end
  end

  def route(%Path{scheme: scheme} = source, %__MODULE__{} = routes) when is_binary(scheme) do
    case routes.schemes do
      %{^scheme => name} -> path_route(name, %{source | scheme: nil})
      _schemes -> {:error, {:source, :not_found}}
    end
  end

  def route(%URL{scheme: scheme} = source, %__MODULE__{} = routes),
    do: scheme_route(Atom.to_string(scheme), source, routes)

  def route(%Object{scheme: scheme} = source, %__MODULE__{} = routes),
    do: scheme_route(scheme, source, routes)

  # The source parser rejects URL and object schemes no configured source matches.
  defp scheme_route(scheme, source, routes),
    do: {:ok, Map.fetch!(routes.schemes, scheme), source}

  # Origins may normalize dot segments, and a bare prefix names no source.
  defp path_route(name, %Path{segments: segments} = source) do
    if segments == [] or Enum.any?(segments, &(&1 in ["", ".", ".."])),
      do: {:error, {:source, :denied_path}},
      else: {:ok, name, source}
  end

  # File caches identify files by root_id, so one root_id naming two
  # directories would serve one directory's cached files for the other's.
  defp unique_file_roots(%__MODULE__{sources: sources}) do
    roots =
      for {_name, {ImagePipe.Source.File, opts}} <- sources,
          uniq: true,
          do: {opts[:root_id], opts[:root]}

    duplicate =
      roots
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.find(fn {_root_id, count} -> count > 1 end)

    case duplicate do
      nil ->
        :ok

      {root_id, _count} ->
        {:error,
         {:source,
          {:invalid_sources, "root_id #{inspect(root_id)} names more than one directory"}}}
    end
  end

  defp unique_names?(sources), do: sources |> Keyword.keys() |> then(&(Enum.uniq(&1) == &1))

  defp add_sources(sources) do
    Enum.reduce_while(sources, {:ok, %__MODULE__{}}, fn {name, config}, {:ok, routes} ->
      case add_source(routes, name, config) do
        {:ok, routes} -> {:cont, {:ok, routes}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_source(routes, name, config) when is_list(config) do
    with {:ok, config} <- validate_source_shape(name, config),
         {:ok, rules} <- parse_match(name, Keyword.fetch!(config, :match)),
         module = Keyword.fetch!(config, :adapter),
         {:ok, opts} <- validate_adapter_options(name, module, Keyword.fetch!(config, :options)),
         :ok <- check_identifiers(name, module, opts, rules),
         {:ok, routes} <- add_rules(routes, name, rules) do
      {:ok, %{routes | sources: Map.put(routes.sources, name, {module, opts})}}
    end
  end

  defp add_source(_routes, name, _config),
    do: invalid_source(name, "expected a keyword list with :adapter, :match, and :options")

  defp validate_source_shape(name, config) do
    case NimbleOptions.validate(config, @source_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> invalid_source(name, Exception.message(error))
    end
  end

  defp parse_match(_name, :path), do: {:ok, [{:path, nil}]}

  defp parse_match(name, match) when is_list(match) and match != [] do
    if Keyword.keyword?(match) and Enum.all?(Keyword.keys(match), &(&1 in [:prefix, :scheme])) do
      rules =
        Enum.flat_map(match, fn {kind, values} -> Enum.map(List.wrap(values), &{kind, &1}) end)

      if rules != [] and Enum.all?(rules, &valid_rule?/1),
        do: {:ok, rules},
        else: invalid_source(name, "invalid match rule #{inspect(match)}")
    else
      invalid_source(name, "match must be :path or a keyword list of :prefix and :scheme")
    end
  end

  defp parse_match(name, _match),
    do: invalid_source(name, "match must be :path or a keyword list of :prefix and :scheme")

  defp valid_rule?({:prefix, prefix}) when is_binary(prefix),
    do: prefix not in ["", ".", ".."] and not String.contains?(prefix, "/")

  defp valid_rule?({:scheme, scheme}) when is_binary(scheme),
    do: Regex.match?(@scheme_pattern, scheme)

  defp valid_rule?(_rule), do: false

  # The identifier struct a rule routes: http, https, and s3 schemes route URL
  # and object identifiers; a prefix or any other scheme routes paths.
  defp rule_identifier({:scheme, scheme}), do: Map.get(@builtin_scheme_identifiers, scheme, Path)
  defp rule_identifier(_rule), do: Path

  defp check_identifiers(name, module, opts, rules) do
    supported = module.identifiers(opts)
    needed = rules |> Enum.map(&rule_identifier/1) |> Enum.uniq()

    cond do
      not (is_list(supported) and Enum.all?(supported, &(&1 in @identifiers))) ->
        invalid_source(name, "#{inspect(module)}.identifiers/1 returned #{inspect(supported)}")

      Enum.all?(needed, &(&1 in supported)) ->
        :ok

      true ->
        invalid_source(
          name,
          "#{inspect(module)} resolves #{inspect(supported)}, but match needs #{inspect(needed)}"
        )
    end
  end

  defp validate_adapter_options(name, module, options) do
    case module.validate_options(options) do
      {:ok, validated} when is_list(validated) ->
        {:ok, order_like(options, validated)}

      {:error, {:invalid_source_config, message}} when is_binary(message) ->
        invalid_source(name, message)

      {:error, reason} ->
        invalid_source(name, inspect(reason))

      other ->
        invalid_source(name, "#{inspect(module)}.validate_options/1 returned #{inspect(other)}")
    end
  end

  # Keep the host's option order, then any keys the adapter added.
  defp order_like(input, validated) do
    keys = Keyword.keys(input)
    ordered = for key <- keys, Keyword.has_key?(validated, key), do: {key, validated[key]}
    ordered ++ Enum.reject(validated, fn {key, _value} -> key in keys end)
  end

  defp add_rules(routes, name, rules) do
    Enum.reduce_while(rules, {:ok, routes}, fn rule, {:ok, acc} ->
      case add_rule(acc, name, rule) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp add_rule(%{path: nil} = routes, name, {:path, nil}), do: {:ok, %{routes | path: name}}

  defp add_rule(%{path: other}, name, {:path, nil}),
    do: invalid_source(name, "match :path is already used by source #{inspect(other)}")

  defp add_rule(routes, name, {:prefix, prefix}) do
    case routes.prefixes do
      %{^prefix => other} ->
        invalid_source(
          name,
          "prefix #{inspect(prefix)} is already used by source #{inspect(other)}"
        )

      prefixes ->
        {:ok, %{routes | prefixes: Map.put(prefixes, prefix, name)}}
    end
  end

  defp add_rule(routes, name, {:scheme, scheme}) do
    case routes.schemes do
      %{^scheme => other} ->
        invalid_source(
          name,
          "scheme #{inspect(scheme)} is already used by source #{inspect(other)}"
        )

      schemes ->
        {:ok, %{routes | schemes: Map.put(schemes, scheme, name)}}
    end
  end

  defp invalid_source(name, reason), do: {:error, {:source, {:invalid_source, name, reason}}}
end
