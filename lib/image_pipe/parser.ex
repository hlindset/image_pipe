defmodule ImagePipe.Parser do
  @moduledoc """
  Behaviour for parsing image request paths into execution plans.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ],
    exports: []

  alias ImagePipe.Plan

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t(), keyword()) ::
              {:ok, Plan.t()}
              | {:redirect, 303, String.t()}
              | {:error, any()}

  @doc """
  Render request parsing or request validation errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()

  @doc """
  Validate and normalize the host options the parser owns.

  Called once at `ImagePipe.Plug.init/1` time with the full host option list. A
  parser inspects only its own option namespace, validates/normalizes it, and
  returns the (possibly updated) full option list. Raises on invalid
  configuration — this runs at init, not per-request.

  Optional: a parser that takes no host options omits it, and
  `validate_options!/2` is an identity.
  """
  @callback validate_options!(opts :: keyword()) :: keyword()

  @optional_callbacks validate_options!: 1

  @doc """
  Dispatch parser option validation generically.

  Invokes `parser.validate_options!/1` when the parser implements it, otherwise
  returns `opts` unchanged. This keeps the core unaware of any concrete parser:
  the parser owns its own option contract.
  """
  @spec validate_options!(module(), keyword()) :: keyword()
  def validate_options!(parser, opts) when is_atom(parser) and is_list(opts) do
    if Code.ensure_loaded?(parser) and function_exported?(parser, :validate_options!, 1) do
      validate_returned_options!(parser, parser.validate_options!(opts))
    else
      opts
    end
  end

  defp validate_returned_options!(parser, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: opts,
      else: raise(ArgumentError, keyword_return_error(parser, opts))
  end

  defp validate_returned_options!(parser, opts),
    do: raise(ArgumentError, keyword_return_error(parser, opts))

  defp keyword_return_error(parser, returned) do
    "#{inspect(parser)}.validate_options!/1 must return a keyword list, got: #{inspect(returned)}"
  end

  @doc """
  Coerce a URL boolean flag value shared across dialect parsers.

  Accepts the boolean spellings `1`/`t`/`true` and `0`/`f`/`false`; any other
  value is `{:error, {:invalid_boolean, value}}`.
  """
  @spec parse_boolean(String.t()) :: {:ok, boolean()} | {:error, {:invalid_boolean, String.t()}}
  def parse_boolean(value) when value in ["1", "t", "true"], do: {:ok, true}
  def parse_boolean(value) when value in ["0", "f", "false"], do: {:ok, false}
  def parse_boolean(value), do: {:error, {:invalid_boolean, value}}
end
