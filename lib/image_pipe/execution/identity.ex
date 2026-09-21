defmodule ImagePipe.Execution.Identity do
  @moduledoc """
  Builds representation identity from canonical request data and the
  resolved output policy. Byte-affecting groups, terminal, output selection,
  and detector identity enter both the cache key and ETag. Source info carries
  only its terminal identity.

  The cachebuster and configured request-header/cookie storage inputs partition
  cache storage without changing the ETag. Expiry, signatures, filenames,
  attachment, and debug presentation do not enter identity. The caller passes
  source byte identity separately to `ImagePipe.Representation.build/3`.
  """

  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Output.Terminal.LqipCss
  alias ImagePipe.Plan.Request
  alias ImagePipe.Representation.IdentityMaterial

  @doc """
  Builds the representation identity material for `request`, given the negotiation
  outcome, the normalized request inputs (consulted only for configured
  `storage_inputs`), and mount `config`.
  """
  @spec material(Request.t(), Policy.t() | nil, Inputs.t(), keyword(), term() | nil) ::
          IdentityMaterial.t()
  def material(
        %Request{} = request,
        policy,
        %Inputs{} = inputs,
        config,
        detector_identity
      )
      when is_list(config) do
    {configured_storage_only, storage_vary_names} =
      Inputs.storage_material(inputs, Keyword.get(config, :storage_inputs, []))

    storage_only = cachebuster_material(request.cachebuster) ++ configured_storage_only

    representation = representation_material(request, policy, detector_identity)

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

  defp representation_material(
         %Request{output: %{terminal: :info}},
         nil,
         _detector_identity
       ) do
    [terminal: {:info, 1}]
  end

  defp representation_material(
         %Request{output: %{terminal: terminal}} = request,
         nil,
         detector_identity
       )
       when terminal in [:blurhash, :lqip_css] do
    [orient: request.orient, groups: canonical_groups(request.groups)] ++
      [terminal: terminal_identity(terminal), output_policy: []] ++
      detector_material(detector_identity)
  end

  defp representation_material(request, %Policy{} = policy, detector_identity) do
    [
      orient: request.orient,
      groups: canonical_groups(request.groups),
      terminal: :image,
      selection: {:image, selected_format(policy)},
      output_policy: Policy.identity_material(policy)
    ] ++ detector_material(detector_identity)
  end

  defp cachebuster_material(nil), do: []
  defp cachebuster_material(cachebuster), do: [cachebuster: cachebuster]

  defp terminal_identity(:blurhash), do: Blurhash.identity()
  defp terminal_identity(:lqip_css), do: LqipCss.identity()

  defp selected_format(policy) do
    case Policy.identity_selection(policy) do
      {:explicit, format} -> format
      {:auto_head, format} -> format
      :source_negotiated -> :source_negotiated
    end
  end

  defp varies_by_accept?(nil), do: false
  defp varies_by_accept?(%Policy{mode: {:explicit, _format}}), do: false
  defp varies_by_accept?(%Policy{}), do: true

  defp detector_material(nil), do: []
  defp detector_material(identity), do: [detector: identity]

  defp canonical_groups(groups), do: Enum.map(groups, &Map.from_struct/1)
end
