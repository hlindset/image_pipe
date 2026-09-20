defmodule ImagePipe.Plug.Terminal do
  @moduledoc false

  alias ImagePipe.Processing.Terminal

  def render(source, request, config) do
    with {:ok, content_type, data} <- Terminal.render(source, request, config) do
      body = if request.output.terminal == :info, do: JSON.encode_to_iodata!(data), else: data
      {:ok, content_type, body}
    end
  end
end
