defmodule Mix.Tasks.ImagePipe.SharedCache.Build do
  use Mix.Task
  use Boundary, deps: [], exports: []

  @shortdoc "Build the optional POSIX shared-cache directory helper"
  @moduledoc """
  Builds the streaming directory reader used by the shared filesystem cache.

      mix image_pipe.shared_cache.build

  Run in the deployment target's build environment before assembling a release.
  Requires a POSIX C compiler (`CC`, default `cc`); no compiler is needed at runtime.
  The local filesystem cache does not need this helper.
  """
  @requirements ["compile"]

  @impl true
  def run([]) do
    directory = Path.join(to_string(:code.priv_dir(:image_pipe)), "shared_cache")
    source = Path.join(directory, "list_directory.c")
    output = Path.join(directory, "list_directory")
    temporary = output <> ".build-#{System.unique_integer([:positive])}"
    compiler = System.get_env("CC", "cc")
    args = ["-std=c99", "-O2", "-Wall", "-Wextra", "-Werror", source, "-o", temporary]

    try do
      case System.cmd(compiler, args, stderr_to_stdout: true) do
        {_output, 0} ->
          File.chmod!(temporary, 0o755)
          File.rename!(temporary, output)
          Mix.shell().info("Built shared-cache directory helper")

        {diagnostic, status} ->
          Mix.raise("Directory helper compilation failed (#{status}):\n#{diagnostic}")
      end
    after
      File.rm(temporary)
    end
  end
end
