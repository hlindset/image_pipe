# Publishes image_pipe_url and then image_pipe to Hex at their shared version.
# A version already on Hex is skipped, so a failed release can be rerun.
#
# With --dry-run, builds and checks both packages without publishing. While
# image_pipe_url's version isn't on Hex yet, image_pipe can't resolve it, so
# the dry run builds image_pipe's docs and package and accepts only the error
# for that missing dependency.
#
# Usage: mise run release:hex [--dry-run]

Mix.install([{:req, "~> 0.8.0-rc.0"}])

defmodule ReleaseHex do
  @root Path.expand("..", __DIR__)
  @missing_url_dep "Dependencies excluded from the package (only Hex packages can be dependencies): image_pipe_url"

  def main(args) do
    dry_run? =
      case args do
        [] -> false
        ["--dry-run"] -> true
        _ -> Mix.raise("usage: release_hex.exs [--dry-run]")
      end

    version = version!()

    step("image_pipe_url #{version}", fn ->
      unless published?("image_pipe_url", version) do
        mix!("image_pipe_url", ["deps.get"])
        mix!("image_pipe_url", ["docs", "--warnings-as-errors"])
        hex_publish!("image_pipe_url", dry_run?)
      end
    end)

    step("image_pipe #{version}", fn ->
      cond do
        published?("image_pipe", version) ->
          :ok

        not dry_run? or published?("image_pipe_url", version) ->
          publish_image_pipe(dry_run?)

        true ->
          check_image_pipe_without_url(version)
      end
    end)
  end

  defp version! do
    case System.cmd(Path.join(@root, "scripts/check-versions.sh"), [], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _status} -> Mix.raise(String.trim(output))
    end
  end

  defp step(title, fun) do
    IO.puts(IO.ANSI.format([:bright, "==> #{title}"]))
    fun.()
  end

  defp published?(package, version) do
    case Req.get!("https://hex.pm/api/packages/#{package}/releases/#{version}") do
      %{status: 200} ->
        IO.puts("#{package} #{version} is already on Hex; skipping")
        true

      %{status: 404} ->
        false

      %{status: status} ->
        Mix.raise("hex.pm returned #{status} for #{package} #{version}")
    end
  end

  # Switching to the Hex dependency rewrites mix.lock; restore it afterwards.
  defp publish_image_pipe(dry_run?) do
    lock = Path.join([@root, "image_pipe", "mix.lock"])
    original = File.read!(lock)

    try do
      # A fresh release can take a moment to reach the registry mix resolves from.
      retry(6, fn -> mix("image_pipe", ["deps.get"], publish: true) == 0 end)
      mix!("image_pipe", ["docs", "--warnings-as-errors"], publish: true)
      hex_publish!("image_pipe", dry_run?, publish: true)
    after
      File.write!(lock, original)
    end
  end

  defp check_image_pipe_without_url(version) do
    mix!("image_pipe", ["deps.get"])
    mix!("image_pipe", ["docs", "--warnings-as-errors"])

    tmp = Path.join(System.tmp_dir!(), "image_pipe-#{System.unique_integer([:positive])}.tar")

    try do
      case System.cmd("mix", ["hex.build", "--output", tmp],
             cd: Path.join(@root, "image_pipe"),
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          IO.puts(output)
          Mix.raise("expected the build to stop on the unpublished image_pipe_url")

        {output, _status} ->
          if build_errors(output) != [@missing_url_dep] do
            IO.puts(output)
            Mix.raise("image_pipe package build failed")
          end

          IO.puts("image_pipe package is valid apart from the unpublished image_pipe_url #{version}")
      end
    after
      File.rm(tmp)
    end
  end

  defp build_errors(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop_while(&(not String.contains?(&1, "Stopping package build due to errors")))
    |> Enum.drop(1)
  end

  defp retry(attempts, fun) do
    cond do
      fun.() ->
        :ok

      attempts > 1 ->
        IO.puts("retrying in 20 seconds")
        Process.sleep(20_000)
        retry(attempts - 1, fun)

      true ->
        Mix.raise("gave up retrying")
    end
  end

  # hex.publish asks for credentials even in a dry run and, finding none, offers
  # an interactive sign-in that hangs CI. A placeholder key skips the prompt: a
  # dry run uploads nothing, and Hex reports and ignores the 401 from its
  # account lookup.
  defp hex_publish!(project, dry_run?, opts \\ []) do
    if dry_run? do
      opts = Keyword.put(opts, :env, [{"HEX_API_KEY", "dry-run"}])
      mix!(project, ["hex.publish", "--yes", "--dry-run"], opts)
    else
      mix!(project, ["hex.publish", "--yes"], opts)
    end
  end

  defp mix!(project, args, opts \\ []) do
    status = mix(project, args, opts)
    if status != 0, do: Mix.raise("mix #{Enum.join(args, " ")} failed in #{project}")
  end

  defp mix(project, args, opts) do
    publish_env = if opts[:publish], do: [{"IMAGE_PIPE_PUBLISH", "1"}], else: []
    env = publish_env ++ Keyword.get(opts, :env, [])

    {_output, status} =
      System.cmd("mix", args,
        cd: Path.join(@root, project),
        env: env,
        into: IO.stream(),
        stderr_to_stdout: true
      )

    status
  end
end

ReleaseHex.main(System.argv())
