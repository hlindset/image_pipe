defmodule ImagePipe.Dialect.Declarative.Identity do
  @moduledoc """
  Composes a declarative dialect's representation identity material from its
  `%ImagePipe.Plan{}`.

    * `representation` — byte-affecting data: the canonical semantic operation
      chains (`ImagePipe.Plan.KeyData.data/1` per operation), `auto_rotate`,
      the terminal identity (`:image`, or the renderer module + params), the
      canonical output plan, the resolved detector identity, and the
      negotiation outcome + effective output policy material.
    * `storage_only` — the plan's cachebuster plus configured `storage_inputs`
      values. Excluded from the ETag: both partition storage without changing
      the delivered bytes.

  `dialect_behavior` is the host dialect's module plus `@declarative_epoch` —
  the tier's own behavioral epoch, bumped when a change to this derivation must
  invalidate every representation every declarative dialect has built.

  `plan.expires` and `plan.response` are deliberately absent from both buckets:
  `expires` is a gate, not identity, and `response` is delivery presentation
  (including `debug?`, which must never move the key or ETag).
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  @declarative_epoch 1

  @spec material(module(), Plan.t(), Negotiation.t(), Plug.Conn.t(), keyword(), term()) ::
          IdentityMaterial.t()
  def material(dialect, %Plan{} = plan, %Negotiation{} = negotiation, conn, config, detector) do
    {storage_only, storage_vary_names} =
      Representation.storage_inputs(conn, Keyword.get(config, :storage_inputs, []))

    representation =
      [
        pipelines: pipelines_data(plan.pipelines),
        auto_rotate: plan.auto_rotate,
        detector: detector,
        output: output_data(plan.output, config)
      ] ++
        terminal_material(plan, negotiation.selected) ++
        [output_policy: negotiation.policy_material]

    vary_header_names =
      if negotiation.vary?,
        do: Enum.uniq(storage_vary_names ++ ["Accept"]),
        else: storage_vary_names

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only ++ [cachebuster: plan.cachebuster],
      dialect_behavior: {dialect, @declarative_epoch},
      vary_header_names: vary_header_names
    }
  end

  defp pipelines_data(pipelines) do
    Enum.map(pipelines, fn %Pipeline{operations: operations} ->
      Enum.map(operations, &KeyData.data/1)
    end)
  end

  # A render terminal's identity IS the renderer module + params. It rides the
  # Plan, not `negotiation.selected` — the promoted `%Negotiation{}`'s
  # `selected` type is `{:terminal, atom()}`, and widening a public SDK type to
  # carry a renderer spec would be a contract change for a value only this
  # module reads.
  defp terminal_material(_plan, {:image, _selection} = selected),
    do: [terminal: :image, selection: selected]

  defp terminal_material(%Plan{render: {:custom, module, params}}, {:terminal, :render}),
    do: [terminal: {:render, module, params}]

  # A custom render carries no image output plan.
  defp output_data(nil, _config), do: []

  defp output_data(%Output{mode: :automatic} = output, config) do
    [
      mode: :automatic,
      auto: [
        jpeg_xl: Keyword.get(config, :auto_jpeg_xl, true),
        avif: Keyword.get(config, :auto_avif, true),
        webp: Keyword.get(config, :auto_webp, true)
      ]
    ] ++ common_output_data(output, output.encoder_options)
  end

  defp output_data(%Output{mode: {:explicit, format}} = output, _config) do
    # Explicit format: only the selected format's encoder options shape the
    # bytes (`Policy.resolved/2` forwards only `Map.get(.., format)`), so the
    # digest narrows to it.
    [mode: :explicit, format: format] ++
      common_output_data(output, Map.take(output.encoder_options, [format]))
  end

  defp common_output_data(%Output{} = output, encoder_options) do
    [
      quality: output.quality,
      format_qualities: output.format_qualities,
      quality_search: KeyData.quality_search_data(output.quality_search),
      max_bytes: output.max_bytes,
      strip_metadata: output.strip_metadata,
      color_profile: output.color_profile,
      keep_copyright: output.keep_copyright,
      hdr: output.hdr,
      flatten_background: Color.key_data(output.flatten_background),
      encoder_options:
        Map.new(encoder_options, fn {format, struct} -> {format, Map.from_struct(struct)} end)
    ]
  end
end
