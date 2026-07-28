defmodule ImagePipe.Plug do
  @moduledoc """
  The single mount interface for ImagePipe (design decision U2).

      plug ImagePipe.Plug, dialect: MyApp.Dialect, sources: [...]

  `:dialect` names a module implementing `ImagePipe.Dialect` — an ordered
  dialect that owns its own pipeline, or a declarative one built on
  `ImagePipe.Dialect.Declarative`. Every other option is the dialect's flat
  config, validated by its `c:ImagePipe.Dialect.validate_config!/1` at init.

  This module is the lifecycle runner: parse → prepare → source resolve →
  representation → conditional gate → cache → terminal → deliver. It branches
  only on `%ImagePipe.Dialect.Resolved{}` fields and neutral core structs, and
  never names a dialect (design decision U4).
  """

  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Dialect,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Plug.DialectRunner

  @impl Plug
  def init(opts) do
    dialect = Keyword.fetch!(opts, :dialect)

    unless is_atom(dialect) do
      raise ArgumentError, "dialect: expected a module, got: #{inspect(dialect)}"
    end

    [dialect: dialect] ++ dialect.validate_config!(Keyword.delete(opts, :dialect))
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    DialectRunner.run(conn, Keyword.fetch!(opts, :dialect), opts)
  end
end
