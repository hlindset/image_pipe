defmodule ImagePipe.Execution.Identity do
  # Builds representation identity from canonical request data and the
  # resolved output policy. Byte-affecting groups, terminal, output selection,
  # and detector identity enter both the cache key and ETag. Info identity also
  # carries the placeholders it includes.
  #
  # The cachebuster and configured request-header/cookie storage inputs partition
  # cache storage without changing the ETag. Expiry, signatures, filenames,
  # attachment, and debug presentation do not enter identity. The caller passes
  # source byte identity separately to `ImagePipe.Representation.build/3`.
  #
  # Watermark assets enter as their resolved source identity with the host base
  # opacity folded into the effective opacity; host entry names do not.
  @moduledoc false

  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Output.Terminal.LqipCss
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Output
  alias ImagePipe.Representation.IdentityMaterial

  @doc """
  Builds the representation identity material for `request`, given the negotiation
  outcome, the normalized request inputs (consulted only for configured
  `storage_inputs`), and mount `config`.
  """
  @spec material(Spec.t(), Policy.t() | nil, Inputs.t(), keyword(), term() | nil) ::
          IdentityMaterial.t()
  def material(%Spec{} = request, policy, %Inputs{} = inputs, config, detector_identity)
      when is_list(config) do
    {configured_storage_only, storage_vary_names} =
      Inputs.storage_material(inputs, Keyword.get(config, :storage_inputs, []))

    storage_only = cachebuster_material(request.cachebuster) ++ configured_storage_only

    representation =
      representation_material(
        %{request | groups: Enum.map(request.groups, &Map.from_struct/1)},
        policy,
        detector_identity
      )

    vary_header_names =
      if varies_by_accept?(policy) do
        Enum.uniq(storage_vary_names ++ ["Accept"])
      else
        storage_vary_names
      end

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only,
      vary_header_names: vary_header_names
    }
  end

  defp representation_material(%Spec{output: output} = request, nil, detector_identity) do
    [orient: request.orient] ++
      page_material(request.page) ++
      [groups: request.groups] ++
      [terminal: terminal_identity(output), output_policy: []] ++
      detector_material(detector_identity)
  end

  defp representation_material(request, %Policy{} = policy, detector_identity) do
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
