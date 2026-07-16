defmodule ImagePipe.Dialect.Imgproxy.Negotiation do
  @moduledoc """
  The imgproxy dialect's negotiation outcome.

  Carries exactly what `ImagePipe.Dialect.Imgproxy.Identity.material/5` needs
  to compose identity, plus the one `%ImagePipe.Output.Policy{}` that later
  drives `Policy.resolve/2` and encode — so the one-`%Policy{}` invariant
  (identity and encode never look at two different policy structs) is
  structural, not prose. Identity code reads only `:selected` and
  `:policy_material`; it never reads `:policy`.

  Constructed by `ImagePipe.Dialect.Imgproxy.negotiate/3` (Task 17) from the
  canonical request, the incoming `conn`, and dialect config.
  """

  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  @enforce_keys [:selected, :vary?, :policy_material]
  defstruct [:selected, :vary?, :policy_material, :policy]

  @typedoc """
  The negotiated terminal + format selection:

    * `{:image, format}` — the image terminal, with either a concrete
      `Output.format()` (explicit `format=`/`f=` or the negotiated
      auto-candidate head) or the `:source_negotiated` sentinel when format
      selection must defer to the decoded source format.
    * `{:terminal, :info}` — the `/info` JSON terminal; it has no format
      selection to carry.
  """
  @type selected :: {:image, Output.format() | :source_negotiated} | {:terminal, :info}

  @type t :: %__MODULE__{
          selected: selected(),
          # {:terminal, _} is always false — a fixed terminal never varies by Accept.
          vary?: boolean(),
          # Output.Policy.identity_material/1 over :policy; [] for terminals.
          policy_material: keyword(),
          # THE struct that later drives Policy.resolve/2 and encode.
          policy: Policy.t() | nil
        }
end
