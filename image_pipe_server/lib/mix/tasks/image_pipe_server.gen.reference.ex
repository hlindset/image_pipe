defmodule Mix.Tasks.ImagePipeServer.Gen.Reference do
  @shortdoc "Writes the configuration reference into docs/configuration.md"

  @moduledoc """
  Regenerates the configuration reference in `docs/configuration.md` from the
  loader's schemas (see `ImagePipeServer.Config.Reference`).

      mix image_pipe_server.gen.reference
  """

  use Mix.Task

  alias ImagePipeServer.Config.Reference

  @path "docs/configuration.md"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    File.write!(@path, Reference.replace(File.read!(@path)))
    Mix.shell().info("Updated #{@path}")
  end
end
