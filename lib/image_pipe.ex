defmodule ImagePipe do
  @moduledoc """
  Package namespace for ImagePipe.
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
    exports: [Plug]

  @type imgp_pixels :: {:pixels, non_neg_integer()}
  @type imgp_ratio :: {number(), number()}
end
