defmodule ImagePipe.Transform.Detector.ImageVision.Model do
  @moduledoc false
  # Shared by the image_vision adapters: an unavailable adapter reports its own
  # identity, so a fallback isn't cached under the working model's key.

  @spec identity(module(), boolean(), term()) :: {module(), term()}
  def identity(adapter, true, model), do: {adapter, model}
  def identity(adapter, false, _model), do: {adapter, :unavailable}
end
