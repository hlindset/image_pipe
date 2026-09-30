defmodule ImagePipe.Source.StreamError do
  @moduledoc false

  defexception [:reason]

  @type reason :: atom() | {:bad_status, non_neg_integer()}
  @type t :: %__MODULE__{reason: reason()}

  def message(%__MODULE__{reason: reason}), do: "source stream failed: #{inspect(reason)}"
end
