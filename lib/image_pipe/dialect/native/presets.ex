defmodule ImagePipe.Dialect.Native.Presets do
  @moduledoc """
  Host-configured presets for the native URL dialect [native §Presets,
  trimmed to probe].

  A preset is a named, host-configured option-fragment string restricted
  to group-scoped transform options — no `then`, no `preset`, no
  `src`/`src64`, no request-scoped keys (a deliberate probe trim; the full
  spec's override families and multi-group presets are post-probe). Both
  the config-time check (`validate_config/1`, called from
  `ImagePipe.Dialect.Native.Config` at `init/1`) and request-time expansion
  (`expand/4`, called from `ImagePipe.Dialect.Native.Parser`) parse a
  fragment the same way: `Parser.parse_option_fragment/2` already rejects
  `then`, `src`/`src64`, and any request-scoped key (including `preset`
  itself, whose `OptionSpec` entry is `scope: :request`), so this module
  does not re-implement that restriction.

  **Precedence** is a strict chain, lowest to highest: the `default`
  preset (applied automatically when configured, whether or not the URL
  names it) < each name in `preset=<name>,<name>,...` in the order
  listed < the URL's own explicit group-scoped options. A key set at two
  different levels resolves to the higher level. Duplicate keys *within*
  one level (one preset's own fragment, or the URL's own explicit
  segments) are unaffected by this module — they still follow the
  parser's normal duplicate-option rule, enforced where that level is
  itself parsed.

  Expansion applies only to a request's first pipeline group: a preset's
  fragment carries no `then`, so it can only ever contribute one group's
  worth of options (multi-group presets are out of scope for this probe).

  Preset names are host configuration, not request data — the merged
  option map this module returns feeds the same group-assembly code path
  as the URL's own explicit options, and nothing downstream reads a
  preset's name, so it never reaches the canonical `%Request{}` (cache-key
  transparency, Task 10, follows for free).
  """

  alias ImagePipe.Dialect.Native.Diagnostic
  alias ImagePipe.Dialect.Native.Parser

  @default_preset_name "default"

  @type fragment_map :: %{optional(String.t()) => String.t()}
  @type option_map :: %{optional(String.t()) => term()}

  @doc """
  Config-time validation: every configured preset fragment must parse as a
  group-scoped-only option fragment. Presets are host configuration, not
  request input, so failures return a plain error message (not a
  `Diagnostic` list) for `NimbleOptions`/`ArgumentError` to surface at
  `init/1`.
  """
  @spec validate_config(fragment_map()) :: {:ok, fragment_map()} | {:error, String.t()}
  def validate_config(presets) when is_map(presets) do
    presets
    |> Enum.find_value(&fragment_config_error/1)
    |> case do
      nil -> {:ok, presets}
      error -> error
    end
  end

  defp fragment_config_error({name, fragment}) do
    case Parser.parse_option_fragment(fragment, []) do
      {:ok, _option_map} ->
        nil

      {:error, diagnostics} ->
        messages = Enum.map_join(diagnostics, "; ", & &1.message)
        {:error, "preset #{inspect(name)} is invalid: #{messages}"}
    end
  end

  @doc """
  Expands presets into a request's first pipeline group [native §Presets].

  `group_map` is the URL's own explicit, clean group-0 option map (highest
  precedence); `preset_names` is the parsed `preset=` value (request order,
  empty when the URL states no `preset`); `presets_config` is the host's
  configured name-to-fragment map; `preset_key_span` is the span of the
  URL's `preset=` segment, used only to anchor an `:unknown_preset`
  diagnostic (never dereferenced when no unknown name is present).

  Returns `{merged_map, []}` on success, or `{group_map, diagnostics}`
  unchanged when one or more named presets are not configured — expansion
  is all-or-nothing, mirroring how the rest of request validation
  accumulates errors without partially applying a request.
  """
  @spec expand(option_map(), [String.t()], fragment_map(), Diagnostic.span()) ::
          {option_map(), [Diagnostic.t()]}
  def expand(group_map, preset_names, presets_config, preset_key_span)
      when is_map(group_map) and is_list(preset_names) and is_map(presets_config) do
    case unknown_preset_names(preset_names, presets_config) do
      [] ->
        {merge_presets(group_map, preset_names, presets_config), []}

      unknown_names ->
        {group_map, Enum.map(unknown_names, &unknown_preset_diagnostic(&1, preset_key_span))}
    end
  end

  defp unknown_preset_names(preset_names, presets_config) do
    Enum.filter(preset_names, &(not Map.has_key?(presets_config, &1)))
  end

  # The static wording ("unknown preset") lives in `Parser.message_for/1`
  # — the same central table every other reason's message comes from —
  # this module only appends the request-supplied name the table itself
  # can't hold.
  defp unknown_preset_diagnostic(name, span) do
    %Diagnostic{
      reason: :unknown_preset,
      message: "#{Parser.message_for(:unknown_preset)}: #{name}",
      spans: [span]
    }
  end

  defp merge_presets(group_map, preset_names, presets_config) do
    fragment_names = [@default_preset_name | preset_names]

    fragment_names
    |> Enum.map(&Map.get(presets_config, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&fetch_fragment_map!/1)
    |> Enum.reduce(%{}, fn preset_map, acc -> Map.merge(acc, preset_map) end)
    |> Map.merge(group_map)
  end

  # Presets are host configuration, already validated at `init/1`
  # (`validate_config/1`) — a fragment that fails to parse here is a
  # producer bug in `Config`, not request input, so this trusts the
  # config and lets a malformed fragment raise rather than threading a
  # dead error branch through request-time expansion.
  defp fetch_fragment_map!(fragment) do
    {:ok, option_map} = Parser.parse_option_fragment(fragment, [])
    option_map
  end
end
