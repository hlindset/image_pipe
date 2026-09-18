defmodule ImagePipe.Plan.Request do
  @moduledoc """
  Canonical native request data shared by parsing and execution.

  Groups express fixed-order transform intent. Output holds sparse request
  policy before format negotiation. Delivery controls and request gates travel
  with this data without contributing to pixel identity.
  """

  alias ImagePipe.Plan.Request.Group
  alias ImagePipe.Plan.Request.Output

  @enforce_keys [:groups, :output, :source]
  defstruct groups: [],
            output: nil,
            source: nil,
            orient: :auto,
            filename: nil,
            attachment?: false,
            cachebuster: nil,
            expires: nil,
            debug?: false

  @type t :: %__MODULE__{
          groups: [Group.t()],
          output: Output.t(),
          source: String.t(),
          orient: :auto | :none,
          filename: String.t() | nil,
          attachment?: boolean(),
          cachebuster: String.t() | nil,
          expires: pos_integer() | nil,
          debug?: boolean()
        }
end
