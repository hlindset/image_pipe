defmodule ImagePipe.Dialect.TwicPics do
  @moduledoc """
  Plug entry point for the TwicPics URL dialect.

  The dialect owns its request chain and depends only on the core image
  processing toolkit. Request execution is added after its parser and pipeline
  have moved into this boundary.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Format,
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

  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Manipulation
  alias ImagePipe.Dialect.TwicPics.Path
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @doc false
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def parse(%Plug.Conn{} = conn, config) do
    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      RequestBuilder.build(source, chain, config)
    end
  end

  @impl Plug
  def call(%Plug.Conn{}, _opts), do: raise("TwicPics request execution is not implemented")
end
