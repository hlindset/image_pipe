defmodule ImagePipe.Dialect.TwicPics.Negotiation do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  @enforce_keys [:selected, :vary?, :policy_material, :policy]
  defstruct @enforce_keys

  @type selected :: {:image, Output.format() | :source_negotiated}

  @type t :: %__MODULE__{
          selected: selected(),
          vary?: boolean(),
          policy_material: keyword(),
          policy: Policy.t()
        }

  @doc false
  @spec negotiate(Plug.Conn.t(), Request.t(), keyword()) ::
          {:ok, t()} | {:error, {:unsupported_output_format, Policy.format()}}
  def negotiate(%Plug.Conn{} = conn, %Request{} = request, config) when is_list(config) do
    policy = Policy.from_output_plan(conn, request.output, config)

    with :ok <- Policy.ensure_capable(policy, config) do
      {selected_format, vary?} = normalize_selection(Policy.identity_selection(policy))

      {:ok,
       %__MODULE__{
         selected: {:image, selected_format},
         vary?: vary?,
         policy_material: Policy.identity_material(policy),
         policy: policy
       }}
    end
  end

  defp normalize_selection({:explicit, format}), do: {format, false}
  defp normalize_selection({:auto_head, format}), do: {format, true}
  defp normalize_selection(:source_negotiated), do: {:source_negotiated, true}
end
