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

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{}, _opts), do: raise("TwicPics request execution is not implemented")
end
