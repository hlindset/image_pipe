defmodule ImagePipe.Dialect.Negotiation do
  @moduledoc """
  The negotiation outcome carried on `ImagePipe.Dialect.Resolved` — one
  struct replacing the per-dialect copies. `plan_output` is the neutral
  output plan the negotiation was built from, carried so the runner can
  compute `Policy.supports_hdr?/3` without reaching into the opaque request.

  Distinct from `ImagePipe.Output.Negotiation` (an Accept-parsing helper
  module with no struct), which is unchanged.
  """

  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  @enforce_keys [:selected, :vary?, :policy_material, :policy, :plan_output]
  defstruct @enforce_keys

  @type selected ::
          {:image, Output.format() | :source_negotiated} | {:terminal, atom()}

  @type t :: %__MODULE__{
          selected: selected(),
          vary?: boolean(),
          policy_material: keyword(),
          policy: Policy.t() | nil,
          plan_output: Output.t() | nil
        }

  @doc """
  Negotiates the image terminal from a neutral output plan — the
  `Policy.from_output_plan → ensure_capable → identity_selection` sequence
  every dialect ran privately.
  """
  @spec negotiate(Plug.Conn.t(), Output.t(), keyword()) ::
          {:ok, t()} | {:error, {:unsupported_output_format, Policy.format()}}
  def negotiate(%Plug.Conn{} = conn, %Output{} = plan_output, config)
      when is_list(config) do
    policy = Policy.from_output_plan(conn, plan_output, config)

    with :ok <- Policy.ensure_capable(policy, config) do
      {selected_format, vary?} = normalize_selection(Policy.identity_selection(policy))

      {:ok,
       %__MODULE__{
         selected: {:image, selected_format},
         vary?: vary?,
         policy_material: Policy.identity_material(policy),
         policy: policy,
         plan_output: plan_output
       }}
    end
  end

  @doc "A fixed non-image terminal: nothing to select, vary by, or carry as policy."
  @spec terminal(atom()) :: t()
  def terminal(name) when is_atom(name) do
    %__MODULE__{
      selected: {:terminal, name},
      vary?: false,
      policy_material: [],
      policy: nil,
      plan_output: nil
    }
  end

  defp normalize_selection({:explicit, format}), do: {format, false}
  defp normalize_selection({:auto_head, format}), do: {format, true}
  defp normalize_selection(:source_negotiated), do: {:source_negotiated, true}
end
