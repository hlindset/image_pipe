defmodule ImagePipe.Dialect.Native.Negotiation do
  @moduledoc """
  The native dialect's negotiation outcome [native §Output & delivery].

  Carries exactly what `ImagePipe.Dialect.Native.Identity.material/4` needs to
  compose identity, plus the one `%ImagePipe.Output.Policy{}` that later
  drives `Policy.resolve/2` and encode — so the one-`%Policy{}` invariant
  (identity and encode never look at two different policy structs) is
  structural, not prose. Identity code reads only `:selected` and
  `:policy_material`; it never reads `:policy`.

  Constructed by `ImagePipe.Dialect.Native.negotiate/3` (a later task) from
  the canonical request, the incoming `conn`, and dialect config.
  """

  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output

  @enforce_keys [:selected, :vary?, :policy_material]
  defstruct [:selected, :vary?, :policy_material, :policy]

  @typedoc """
  The negotiated terminal + format selection:

    * `{:image, format}` — the image terminal, with either a concrete
      `Output.format()` (explicit `format=` or the negotiated auto-candidate
      head) or the `:source_negotiated` sentinel when format selection must
      defer to the decoded source format.
    * `{:terminal, :blurhash}` — a fixed non-image terminal; it has no format
      selection to carry.
  """
  @type selected :: {:image, Output.format() | :source_negotiated} | {:terminal, :blurhash}

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
