defmodule ImagePipe.Dialect.Native.Identity do
  @moduledoc """
  Composes the native dialect's representation identity material [native
  §Canonical form and identity].

  `material/4` builds an `ImagePipe.Representation.IdentityMaterial` from the
  canonical `%Request{}` plus the negotiation outcome (Task 15's
  `negotiate/3`) — never from raw `conn` state beyond configured
  `storage_inputs`, and never from `expires`, the signature, or the matched
  signing-key index (those are gates, not identity):

    * `representation` — the canonical transform groups, the terminal
      identity (`:image`, or `Output.Terminal.Blurhash.identity/0` for the
      `blurhash` terminal), the negotiated format selection outcome (image
      terminal only), and the effective output policy material
      (`negotiation.policy_material`).
    * `storage_only` — configured `storage_inputs` values
      (`ImagePipe.Representation.storage_inputs/2`); `conn` contributes to
      identity only through this.
    * `dialect_behavior` — `@dialect_epoch`, this dialect's behavioral epoch.
    * `vary_header_names` — the configured storage-vary header names, plus
      `"Accept"` when `negotiation.vary?` is true.

  `source` is never part of this material — it is a separate
  `source_identity` (from `ImagePipe.Source.Resolved`) that the dialect
  passes to `Representation.build/2` alongside this material.
  """

  alias ImagePipe.Dialect.Native.Negotiation
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Output
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  # This dialect's behavioral epoch — bumped whenever a parser/pipeline
  # semantics change must invalidate every representation this dialect has
  # ever built, independent of the core's own execution epoch.
  @dialect_epoch {ImagePipe.Dialect.Native, 1}

  @doc """
  Builds the pre-fetch identity material for `request`, given the negotiation
  outcome, the incoming `conn` (consulted only for configured
  `storage_inputs`), and dialect `config`.
  """
  @spec material(Request.t(), Negotiation.t(), Plug.Conn.t(), keyword()) :: IdentityMaterial.t()
  def material(%Request{} = request, %Negotiation{} = negotiation, %Plug.Conn{} = conn, config)
      when is_list(config) do
    {storage_only, storage_vary_names} =
      Representation.storage_inputs(conn, Keyword.get(config, :storage_inputs, []))

    representation =
      [groups: canonical_groups(request.groups)] ++
        selection_material(negotiation.selected) ++
        [output_policy: negotiation.policy_material]

    vary_header_names =
      if negotiation.vary? do
        Enum.uniq(storage_vary_names ++ ["Accept"])
      else
        storage_vary_names
      end

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only,
      dialect_behavior: @dialect_epoch,
      vary_header_names: vary_header_names
    }
  end

  @doc """
  Builds the requested output intent from `request.output`: `mode` from
  `format` presence (`{:explicit, format}` if set, else `:automatic`),
  `quality` from `q` (`{:quality, n}` if set, else `:default`), every other
  field left at its `%ImagePipe.Plan.Output{}` constructor default. Task 15's
  `negotiate/3` builds its `%ImagePipe.Output.Policy{}` from this.
  """
  @spec plan_output(Request.t()) :: Output.t()
  def plan_output(%Request{output: %Request.Output{} = output}) do
    mode = if output.format, do: {:explicit, output.format}, else: :automatic
    quality = if output.quality, do: {:quality, output.quality}, else: :default

    %Output{mode: mode, quality: quality}
  end

  defp selection_material({:image, _selection} = selected) do
    [terminal: :image, selection: selected]
  end

  defp selection_material({:terminal, :blurhash}) do
    [terminal: Blurhash.identity()]
  end

  defp canonical_groups(groups), do: Enum.map(groups, &Map.from_struct/1)
end
