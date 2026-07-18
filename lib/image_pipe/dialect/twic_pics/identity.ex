defmodule ImagePipe.Dialect.TwicPics.Identity do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics.Negotiation
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  @dialect_epoch {ImagePipe.Dialect.TwicPics, 1}

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
    {storage_only, storage_vary_names} =
      Representation.storage_inputs(conn, Keyword.fetch!(config, :storage_inputs))

    representation =
      [
        steps: canonical_steps(request.steps),
        auto_rotate: request.auto_rotate,
        selection: negotiation.selected,
        output: canonical(request.output),
        output_policy: negotiation.policy_material
      ] ++ detector_material(request, detector_identity)

    %IdentityMaterial{
      representation: representation,
      storage_only: storage_only,
      dialect_behavior: @dialect_epoch,
      vary_header_names: vary_names(storage_vary_names, negotiation.vary?)
    }
  end

  defp detector_material(%Request{} = request, detector_identity) do
    case face_assist?(request.steps) and not is_nil(detector_identity) do
      true -> [detector: detector_identity]
      false -> []
    end
  end

  defp face_assist?(steps) do
    steps
    |> Enum.reduce_while(:inactive, fn
      :set_auto_focus, _mode -> {:cont, :active}
      {:set_focus, _operand}, _mode -> {:cont, :inactive}
      {:operation, %CropRegion{}}, _mode -> {:cont, :inactive}
      {:focused, _operation}, :active -> {:halt, :used}
      _step, mode -> {:cont, mode}
    end)
    |> Kernel.==(:used)
  end

  # A list of two-tuples whose first elements are atoms is a keyword list, and
  # MaterialDigest deliberately sorts keyword lists. Number each step so the
  # digest preserves the dialect's positional semantics.
  defp canonical_steps(steps) do
    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} -> {index, canonical(step)} end)
  end

  # ex_dna:disable-for-next-line
  defp canonical(%module{} = struct),
    do: {module, struct |> Map.from_struct() |> canonical()}

  defp canonical(%{} = map), do: Map.new(map, fn {key, value} -> {key, canonical(value)} end)
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)

  defp canonical(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&canonical/1)
    |> List.to_tuple()
  end

  defp canonical(other), do: other

  defp vary_names(storage_vary_names, true), do: Enum.uniq(storage_vary_names ++ ["Accept"])
  defp vary_names(storage_vary_names, false), do: storage_vary_names
end
