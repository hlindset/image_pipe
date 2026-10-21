defmodule ImagePipe.Execution.Identity do
  # Builds representation identity from canonical request data and the
  # resolved output policy. Byte-affecting groups, terminal, output selection,
  # detector identity, and SVG renderer identity enter both the cache key and
  # ETag. Info identity also
  # carries the placeholders it includes, and the result limits of an explicit
  # format whose encoder lowers them.
  #
  # The cachebuster and the `vary_on` header and cookie values partition cache
  # storage without changing the ETag. Expiry, signatures, filenames,
  # attachment, and debug presentation do not enter identity. The caller passes
  # source byte identity separately to `ImagePipe.Representation.build/3`.
  #
  # Watermark assets enter as their resolved source identity with the host base
  # opacity folded into the effective opacity; host entry names do not.
  @moduledoc false

  alias ImagePipe.Decode
  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Output.Terminal.LqipCss
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Output
  alias ImagePipe.Processing
  alias ImagePipe.Representation.IdentityMaterial

  @doc """
  Builds the representation identity material for `request`, given the negotiation
  outcome, the normalized request inputs (consulted only for configured
  `vary_on`), and mount `config`.
  """
  @spec material(Spec.t(), Policy.t() | nil, Inputs.t(), keyword(), term() | nil) ::
          IdentityMaterial.t()
  def material(%Spec{} = request, policy, %Inputs{} = inputs, config, detector_identity)
      when is_list(config) do
    {vary_material, vary_names} =
      Inputs.vary_material(inputs, Keyword.get(config, :vary_on, []))

    storage_only = cachebuster_material(request.cachebuster) ++ vary_material

    representation =
      representation_material(
        %{request | groups: Enum.map(request.groups, &Map.from_struct/1)},
        policy,
        detector_identity,
        config
      ) ++ Decode.svg_material(Keyword.get(config, :svg))

    vary_header_names =
      if varies_by_accept?(policy) do
        Enum.uniq(vary_names ++ ["Accept"])
      else
        vary_names
      end

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only,
      vary_header_names: vary_header_names
    }
  end

  defp representation_material(%Spec{output: output} = request, nil, detector_identity, config) do
    [orient: request.orient] ++
      page_material(request.page) ++
      [groups: request.groups] ++
      [terminal: terminal_identity(output), output_policy: []] ++
      info_limits_material(output, config) ++
      detector_material(detector_identity)
  end

  defp representation_material(request, %Policy{} = policy, detector_identity, _config) do
    [orient: request.orient] ++
      page_material(request.page) ++
      [
        groups: request.groups,
        terminal: :image,
        selection: {:image, selected_format(policy)},
        output_policy: Policy.identity_material(policy)
      ] ++ detector_material(detector_identity)
  end

  # Absent selects the source's default image, which differs from page 0 for
  # HEIF (its primary image), so only a selected page adds material.
  defp page_material(nil), do: []
  defp page_material(page), do: [page: page]

  defp cachebuster_material(nil), do: []
  defp cachebuster_material(cachebuster), do: [cachebuster: cachebuster]

  defp terminal_identity(%Output{terminal: :info, placeholders: placeholders}),
    do: {:info, Enum.map(placeholders, &placeholder_identity/1)}

  defp terminal_identity(%Output{terminal: terminal}), do: placeholder_identity(terminal)

  # Info clamps its result to an explicit format's encoder limits, so a format
  # that lowers them gets its own identity. Formats that don't share one.
  defp info_limits_material(%Output{terminal: :info, format: format}, config)
       when not is_nil(format) do
    limits = Processing.result_limits(format, config)
    if limits == Processing.result_limits(nil, config), do: [], else: [result_limits: limits]
  end

  defp info_limits_material(_output, _config), do: []

  defp placeholder_identity(:blurhash), do: Blurhash.identity()
  defp placeholder_identity(:lqip_css), do: LqipCss.identity()

  defp selected_format(policy) do
    case Policy.identity_selection(policy) do
      {:explicit, format} -> format
      {:auto_head, format} -> format
      :source_negotiated -> :source_negotiated
    end
  end

  defp varies_by_accept?(nil), do: false
  defp varies_by_accept?(%Policy{headers: headers}), do: {"vary", "Accept"} in headers

  defp detector_material(nil), do: []
  defp detector_material(identity), do: [detector: identity]

  @doc """
  Puts resolved watermark assets into `material`, keyed by asset name with
  their source identity and base opacity.
  """
  @spec put_watermarks(IdentityMaterial.t(), map()) :: IdentityMaterial.t()
  def put_watermarks(%IdentityMaterial{representation: representation} = material, watermarks) do
    groups =
      for group <- Keyword.fetch!(representation, :groups),
          do: Map.update!(group, :watermark, &watermark_material(&1, watermarks))

    %{material | representation: Keyword.put(representation, :groups, groups)}
  end

  # A resolved asset contributes its source identity and folds its base
  # opacity into the effective opacity, so host entry names never matter.
  defp watermark_material(%{asset: asset, opacity: opacity} = watermark, watermarks) do
    case Map.fetch(watermarks, asset) do
      {:ok, [source: identity, opacity: base]} ->
        %{watermark | asset: identity, opacity: opacity * base}

      :error ->
        watermark
    end
  end

  defp watermark_material(nil, _watermarks), do: nil
end
