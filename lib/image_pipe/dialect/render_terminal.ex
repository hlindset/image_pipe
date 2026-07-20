defmodule ImagePipe.Dialect.RenderTerminal do
  @moduledoc """
  A non-image terminal, values only. Phase A supports exactly one delivery:
  the shared complete-body lifecycle (cache-tagged entries, wildcard-INM on
  hit, fail-open write). The spec's `cache: :none` + `offers` variant
  (`Sender`'s `{:rendered, …}` delivery, for the declarative path) is a
  Phase C WIDENING of this struct — deliberately not represented here so the
  Phase A type cannot advertise semantics the runner does not implement.
  """

  alias ImagePipe.Source

  @enforce_keys [:fun]
  defstruct [:fun]

  @type render_fun ::
          (Source.Resolved.t(), keyword() ->
             {:ok, content_type :: String.t(), iodata()} | {:error, term()})

  @type t :: %__MODULE__{fun: render_fun()}
end
