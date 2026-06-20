defmodule Mix.Tasks.Autoquality.Corpus do
  @shortdoc "Fetch the autoquality benchmark corpus into a shared cache — no git, no LFS"
  @moduledoc """
  Materializes the `mix autoquality.bench` corpus by downloading pinned subsets of
  [`imazen/codec-corpus`](https://github.com/imazen/codec-corpus) plus a fixed set
  of large photographs, into a **shared, worktree-independent cache**:

      ${XDG_CACHE_HOME:-~/.cache}/image_pipe/corpus/<sha>/<source>/

  No `git` and no `git-lfs` are involved: the file list comes from the GitHub
  contents API at the pinned commit, and each file is fetched from its
  `raw.githubusercontent.com` URL (GitHub resolves the LFS objects server-side).
  Because the cache lives outside any working tree, every worktree and the main
  checkout share one copy; nothing lands in a tracked or gitignored repo dir.

  Sources (each capped for balanced, bounded per-source groups — see the bench's
  macro-averaged, per-source reporting):

    * `clic` / `clic_holdout` — CLIC 2025 photographic (train / holdout split)
    * `cid22` — Cloudinary CID22, diverse content (portraits…medical…plots)
    * `gb82` — purpose-built hard photographic (sky gradients, fine texture)
    * `gb82_sc` — real screen content (text / UI / charts)
    * `qoi_web` — large web screenshots
    * `large` — large (~15 MP) photographs for the size-dependent parts (C, E-cost),
      which codec-corpus has no equivalent for; pinned Lorem Picsum ids.

      mise exec -- mix autoquality.corpus                 # fetch everything (~270 MB)
      mise exec -- mix autoquality.corpus --only gb82,gb82_sc
      mise exec -- mix autoquality.corpus --path          # just print the cache dir
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  @repo "imazen/codec-corpus"
  @sha "bb1da434fd3ab9ef58577f505d2f9194123e5d6e"
  @exts ~w(.png .jpg .jpeg .webp)

  # codec-corpus subdirs to pull, with a per-source cap (deterministic by name).
  @codec_subsets [
    %{name: "clic", dir: "clic2025/training", max: 40},
    %{name: "clic_holdout", dir: "clic2025/final-test", max: 40},
    %{name: "cid22", dir: "CID22/CID22-512/training", max: 40},
    %{name: "gb82", dir: "gb82", max: 25},
    %{name: "gb82_sc", dir: "gb82-sc", max: 10},
    %{name: "qoi_web", dir: "qoi-benchmark/screenshot_web", max: 14}
  ]

  # Large photographs (~15 MP) for the size-dependent parts. Pinned Lorem Picsum
  # ids (stable per id), requested center-cropped to a uniform 4800×3200.
  @picsum_ids [107, 110, 146, 157, 201, 204]
  @picsum_dims "4800/3200"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [path: :boolean, only: :string])

    root = cache_root()

    if opts[:path] do
      IO.puts(root)
    else
      {:ok, _} = Application.ensure_all_started(:req)
      only = parse_only(opts[:only])
      File.mkdir_p!(root)

      for s <- @codec_subsets, keep?(s.name, only), do: fetch_codec_subset(s, root)
      if keep?("large", only), do: fetch_large(root)

      IO.puts("\ncorpus ready: #{root}")
    end
  end

  @doc "Absolute path of the shared corpus cache for the pinned revision."
  def cache_root do
    base = System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache")
    Path.join([base, "image_pipe", "corpus", String.slice(@sha, 0, 12)])
  end

  defp parse_only(nil), do: :all
  defp parse_only(str), do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp keep?(_name, :all), do: true
  defp keep?(name, only), do: name in only

  defp fetch_codec_subset(%{name: name, dir: dir, max: max}, root) do
    dest = Path.join(root, name)
    File.mkdir_p!(dest)

    files =
      dir
      |> list_dir()
      |> Enum.filter(&image?/1)
      |> Enum.sort()
      |> Enum.take(max)

    Enum.each(files, fn path ->
      fetch_to(raw_url(path), Path.join(dest, Path.basename(path)))
    end)

    IO.puts("#{String.pad_trailing(name, 13)} #{length(files)} files -> #{dest}")
  end

  defp fetch_large(root) do
    dest = Path.join(root, "large")
    File.mkdir_p!(dest)

    Enum.each(@picsum_ids, fn id ->
      fetch_to(
        "https://picsum.photos/id/#{id}/#{@picsum_dims}",
        Path.join(dest, "picsum_#{id}.jpg")
      )
    end)

    IO.puts("#{String.pad_trailing("large", 13)} #{length(@picsum_ids)} files -> #{dest}")
  end

  defp list_dir(dir) do
    "https://api.github.com/repos/#{@repo}/contents/#{dir}?ref=#{@sha}"
    |> Req.get!(headers: [{"accept", "application/vnd.github+json"}])
    |> Map.fetch!(:body)
    |> Enum.map(& &1["path"])
  end

  defp raw_url(path), do: "https://raw.githubusercontent.com/#{@repo}/#{@sha}/#{URI.encode(path)}"

  defp fetch_to(url, dest) do
    if File.exists?(dest) do
      :ok
    else
      %{status: 200, body: body} = Req.get!(url, decode_body: false)
      File.write!(dest, body)
    end
  end

  defp image?(path), do: path |> Path.extname() |> String.downcase() |> Kernel.in(@exts)
end
