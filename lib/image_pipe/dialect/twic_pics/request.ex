defmodule ImagePipe.Dialect.TwicPics.Request do
  @moduledoc false

  @enforce_keys [:source, :steps, :output, :response, :auto_rotate]
  defstruct @enforce_keys

  @type step ::
          {:set_focus, ImagePipe.Transform.Focus.operand()}
          | :set_auto_focus
          | {:operation, ImagePipe.Plan.Pipeline.operation()}
          | {:focused, ImagePipe.Plan.Pipeline.operation()}

  @type t :: %__MODULE__{
          source: ImagePipe.Plan.Source.t(),
          steps: [step()],
          output: ImagePipe.Plan.Output.t(),
          response: ImagePipe.Plan.Response.t(),
          auto_rotate: boolean()
        }
end
