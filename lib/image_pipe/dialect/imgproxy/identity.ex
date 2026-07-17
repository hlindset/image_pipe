defmodule ImagePipe.Dialect.Imgproxy.Identity do
  @moduledoc """
  Composes the imgproxy dialect's representation identity material and the
  pre-negotiation output intent.

  `material/5` builds an `ImagePipe.Representation.IdentityMaterial` from the
  canonical `%Request{}` plus the negotiation outcome (Task 17's
  `negotiate/3`) and the resolved detector identity — never from raw `conn`
  state beyond configured `storage_inputs`, and never from `signature`,
  `expires`, `source_path`, or ANY of `request.response`
  (`filename`/`disposition`/`debug?` — those select delivery presentation, not
  response bytes):

    * `representation` — the canonical pipelines, `auto_rotate`, the
      negotiated selection outcome (the `/info` terminal or the image
      terminal's format selection), the canonical output intent, the
      effective output policy material (`negotiation.policy_material`), and —
      only for a detection request — the resolved detector identity, so a
      detector/model swap yields a different cache key and ETag instead of
      colliding.
    * `storage_only` — the cachebuster plus configured `storage_inputs`
      values (`ImagePipe.Representation.storage_inputs/2`); `conn`
      contributes to identity only through this.
    * `dialect_behavior` — `@dialect_epoch`, this dialect's behavioral epoch.
    * `vary_header_names` — the configured storage-vary header names, plus
      `"Accept"` when `negotiation.vary?` is true.

  `source` is never part of this material — it is a separate
  `source_identity` (from `ImagePipe.Source.Resolved`) that the dialect
  passes to `Representation.build/3` alongside this material.
  """

  alias ImagePipe.Dialect.Imgproxy.Negotiation
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Plan.Output
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  # This dialect's behavioral epoch — bumped whenever a parser/pipeline
  # semantics change must invalidate every representation this dialect has
  # ever built, independent of the core's own execution epoch.
  @dialect_epoch {ImagePipe.Dialect.Imgproxy, 1}

  @doc """
  Builds the pre-fetch identity material for `request`, given the negotiation
  outcome, the incoming `conn` (consulted only for configured
  `storage_inputs`), dialect `config`, and the resolved `detector_identity`
  (`nil` for a non-detection request, or when detection is disabled).
  """
  @spec material(Request.t(), Negotiation.t(), Plug.Conn.t(), keyword(), term() | nil) ::
          IdentityMaterial.t()
  def material(
        %Request{} = request,
        %Negotiation{} = negotiation,
        %Plug.Conn{} = conn,
        config,
        detector_identity
      )
      when is_list(config) do
    {configured_storage_only, storage_vary_names} =
      Representation.storage_inputs(conn, Keyword.get(config, :storage_inputs, []))

    storage_only = [cachebuster: request.cache.cachebuster] ++ configured_storage_only

    representation =
      [pipelines: canonical_pipelines(request.pipelines), auto_rotate: request.auto_rotate] ++
        selection_material(negotiation.selected) ++
        [output: canonical_output(request.output), output_policy: negotiation.policy_material] ++
        detector_material(detector_identity)

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
  `format` presence, `color_profile`/`hdr` resolved from the raw
  `color_profile`/`strip_color_profile`/`preserve_hdr` request fields, every
  other field a direct pass-through. Never errors on `format: :best` — `Task
  17`'s `negotiate/3` rejects an unsupported explicit format via
  `Output.Policy.ensure_capable/2` (`Capabilities.supports?/2` returns
  `false` for `:best`, reaching `{:unsupported_output_format, :best}` through
  negotiation instead of here). Task 17's `negotiate/3` builds its
  `%ImagePipe.Output.Policy{}` from this.
  """
  @spec plan_output(Request.t()) :: Output.t()
  def plan_output(%Request{output: output}) do
    mode = if output.format, do: {:explicit, output.format}, else: :automatic

    %Output{
      mode: mode,
      quality: output.quality,
      format_qualities: output.format_qualities,
      default_quality: output.default_quality,
      quality_search: output.quality_search,
      max_bytes: output.max_bytes,
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright,
      color_profile: color_profile_policy(output.color_profile, output.strip_color_profile),
      hdr: hdr_policy(output.preserve_hdr),
      encoder_options: output.encoder_options
    }
  end

  # A present cp/icc target wins over scp (imgproxy: cp-embedded profiles are
  # not stripped by strip_color_profile). scp only decides strip vs preserve
  # when no target is set.
  defp color_profile_policy(target, _strip) when not is_nil(target), do: {:convert, target}
  defp color_profile_policy(nil, true), do: :strip
  defp color_profile_policy(nil, false), do: :preserve_source
  defp color_profile_policy(nil, nil), do: :strip

  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map
  defp hdr_policy(nil), do: :tone_map

  defp selection_material({:image, _selection} = selected) do
    [terminal: :image, selection: selected]
  end

  defp selection_material({:terminal, :info}) do
    [terminal: :info]
  end

  # Appended ONLY for a detection request. `Representation.build/3` hashes the
  # material as-is (no nil-dropping), so an always-present `detector: nil` entry
  # would churn every non-detection cache key and ETag — the entry must be
  # absent, not nil, when there is no detector identity.
  defp detector_material(nil), do: []
  defp detector_material(identity), do: [detector: identity]

  defp canonical_pipelines(pipelines), do: canonical(pipelines)

  defp canonical_output(output), do: canonical(output)

  # Recursively rewrites every struct as `{module, plain_map}` before the data
  # reaches `ImagePipe.MaterialDigest`, which raises on any struct value:
  # `MaterialDigest.canonicalize/1` pattern-matches `is_map/1` (true for
  # structs) and then calls `Enum.map/2` on it, but a plain struct does not
  # implement the Enumerable protocol. `%PipelineRequest{}` carries several
  # nested struct fields this way (`effects`, `orientation`, `crop`,
  # `background_color`), and a resolved `quality_search` struct / per-format
  # `encoder_options` structs can appear inside `output` too — so this walks
  # the whole term rather than enumerating fields by hand.
  #
  # The module is part of the canonical term, not stripped: two structs can
  # share a field set, and then the module is their ONLY discriminator.
  # `%QualitySearch.Ssimulacra2{}` and `%QualitySearch.Butteraugli{}` are
  # exactly that pair — same nine fields, both URL-settable
  # (`autoquality:ssimulacra2:…` / `autoquality:butteraugli:…`), with
  # overlapping target ranges — so dropping it gives two requests that encode
  # to different bytes one cache key and one ETag. `ImagePipe.Cache.Key`
  # injects a `metric:` discriminator for this reason (`cache/key.ex`'s
  # `quality_metric_key/2`); carrying the module generalizes it to every struct.
  # Do NOT re-insert `__struct__` into the map instead: `Enum.map/2` on
  # `%{__struct__: Foo}` still dispatches `Enumerable.Foo` and raises.
  defp canonical(%mod{} = struct),
    do: {mod, struct |> Map.from_struct() |> canonical()}

  defp canonical(%{} = map), do: Map.new(map, fn {key, value} -> {key, canonical(value)} end)
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  defp canonical(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()
  end

  defp canonical(other), do: other
end
