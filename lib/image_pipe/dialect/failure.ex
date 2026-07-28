defmodule ImagePipe.Dialect.Failure do
  @moduledoc """
  A lifecycle failure wrapped with the phase that produced it.

  A dialect whose error rendering or telemetry classification depends on
  *where* a failure came from — rather than on the reason alone — returns
  its reason inside this struct. The runner passes the wrapper unchanged to
  `c:ImagePipe.Dialect.classify_error/1` and `c:ImagePipe.Dialect.render_error/3`,
  and unwraps it only to compute the telemetry error tag.

  Provenance is preserved structurally, never inferred from a tag allowlist:
  an unrecognized reason keeps the phase's own answer (a parse rejection
  stays a client error, a post-parse failure stays a server-side one)
  instead of falling into whichever bucket a shared tag table happens to
  own.
  """

  @enforce_keys [:phase, :reason]
  defstruct @enforce_keys

  @type t :: %__MODULE__{phase: :parse, reason: term()}
end
