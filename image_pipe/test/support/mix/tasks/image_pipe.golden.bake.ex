defmodule Mix.Tasks.ImagePipe.Golden.Bake do
  @shortdoc "Bake golden images from ImagePipe's current output"
  @moduledoc """
  Renders each case in `ImagePipe.Test.Golden.Cases` through ImagePipe and
  writes its decoded output as a PNG fixture, plus the manifest, under
  `test/support/image_pipe/test/golden/`.

      MIX_ENV=test mise exec -- mix image_pipe.golden.bake [--only id,id]

  Without `--only` it re-bakes every case and removes orphaned fixtures. Bake
  when a change to the output is intended, then review every changed image.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Golden.Cases
  alias ImagePipe.Test.PixelSuite

  @base "test/support/image_pipe/test/golden"
  @fixtures Path.join(@base, "fixtures")
  @manifest Path.join(@base, "manifest.exs")

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [only: :string])
    cases = select(Cases.all(), opts[:only])

    Mix.Task.run("app.start")
    config = PixelSuite.config("golden-bake")
    File.mkdir_p!(@fixtures)

    baked = Map.new(cases, fn c -> {c.id, bake(c, config)} end)
    if opts[:only] == nil, do: remove_orphans(cases)

    write_manifest!(baked)
    Mix.shell().info("Baked #{map_size(baked)} golden case(s)")
  end

  defp select(cases, nil), do: cases

  defp select(cases, only) do
    ids = String.split(only, ",", trim: true)
    selected = Enum.filter(cases, &(&1.id in ids))
    missing = ids -- Enum.map(selected, & &1.id)
    if missing != [], do: Mix.raise("Unknown case id(s): #{Enum.join(missing, ", ")}")
    selected
  end

  defp bake(c, config) do
    response =
      Plug.Test.conn(:get, PixelSuite.request_path(c)) |> ImagePipe.Plug.call(config)

    if response.status != 200 do
      Mix.raise(
        "#{c.id}: #{response.status} #{PixelSuite.request_path(c)}: #{response.resp_body}"
      )
    end

    path = Path.join(@fixtures, "#{c.id}.png")
    decoded = Image.open!(response.resp_body, access: :random, fail_on: :error)
    File.write!(path, Image.write!(decoded, :memory, suffix: ".png"))
    %{fixture_sha256: PixelSuite.file_sha256(path)}
  end

  defp remove_orphans(cases) do
    keep = MapSet.new(cases, &"#{&1.id}.png")

    for file <- File.ls!(@fixtures), file not in keep do
      File.rm!(Path.join(@fixtures, file))
    end
  end

  defp write_manifest!(baked) do
    previous =
      if File.exists?(@manifest),
        do: @manifest |> Code.eval_file() |> elem(0),
        else: %{cases: %{}}

    ids = MapSet.new(Cases.all(), & &1.id)
    cases = previous.cases |> Map.merge(baked) |> Map.filter(fn {id, _} -> id in ids end)

    sources =
      Cases.all()
      |> Enum.map(& &1.source)
      |> Enum.uniq()
      |> Map.new(&{&1, PixelSuite.file_sha256(Path.join(PixelSuite.sources(), &1))})

    manifest = %{libvips: Vix.Vips.version(), sources: sources, cases: cases}

    content =
      manifest
      |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)
      |> Code.format_string!()

    File.write!(@manifest, [content, "\n"])
  end
end
