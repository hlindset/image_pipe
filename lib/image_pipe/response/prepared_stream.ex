defmodule ImagePipe.Response.PreparedStream do
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :next, :cancel, :resolved_output]
  defstruct @enforce_keys ++ [debug: nil, cache_key: nil]

  @type next_result() :: {:chunk, binary()} | :done | {:error, term()}
  @type cancel_result() :: :ok | {:error, term()}

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          next: (-> next_result()),
          cancel: (-> cancel_result()),
          resolved_output: Resolved.t(),
          debug: Info.t() | nil,
          cache_key: String.t() | nil
        }
end
