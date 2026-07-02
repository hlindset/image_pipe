defmodule Mix.Tasks.Twicpics.GenFixtures do
  @shortdoc "Bake TwicPics differential fixtures from the live hosted API (network)"
  @moduledoc """
  Incremental bake against live hosted TwicPics. For each constellation, fetches
  the oracle output ONLY when new / signature-changed / PNG missing-or-corrupt;
  unchanged cases are skipped with zero requests. Uploads any source lacking a
  recorded hosted URL to catbox. Prunes orphaned entries + PNGs. Writes
  `manifest.exs`, reference PNGs, and `REPORT.md`. Requires network; never on the
  default test lane.

  When a new source is uploaded to catbox, its `source_bytes_url` (the catbox
  direct-download URL) must be added to the corresponding `SourceInventory` entry
  so that future `verify_remote!` runs can confirm the hosted bytes still match the
  committed source file.

      mise run twic:bake                 # incremental
      mix twicpics.gen_fixtures --force  # re-bake all
      mix twicpics.gen_fixtures --only cover_square,inside_wide_lr
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Parser.TwicPics

  alias ImagePipe.Test.TwicpicsDifferential.{
    Constellations,
    Manifest,
    SourceInventory
  }

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"
  @manifest_path "#{@base}/manifest.exs"
  @catbox "https://catbox.moe/user/api.php"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean, only: :string])
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    File.mkdir_p!(@fixtures_dir)

    # Fail fast: a chain that doesn't parse must abort BEFORE any live oracle call
    # (network is the expensive/rate-limited resource here) — imgproxy's pre-bake
    # parse gate, adapted. Triaged cases (known parser gaps) are skipped.
    validate_parses!()

    only = opts[:only] && String.split(opts[:only], ",", trim: true) |> MapSet.new()

    prior =
      if File.exists?(@manifest_path), do: Manifest.load!(@manifest_path), else: empty_manifest()

    sources = resolve_sources(prior.sources)
    # Bake EVERY case, including triaged ones (imgproxy discipline): a triaged case
    # still has valid oracle output, and keeping its fixture lets the report show it and
    # lets un-triaging light it up without a re-bake. The parse gate (above) skips
    # triaged cases; only the conformance COMPARISON is quarantined, not the bake.
    cases = Constellations.all()

    {entries, baked_count, server_header} =
      Enum.reduce(cases, {%{}, 0, nil}, fn c, {acc, n, server} ->
        {entry, baked?, case_server} =
          bake_case(c, sources, prior.entries[c.id], opts[:force], only)

        {Map.put(acc, c.id, entry), n + if(baked?, do: 1, else: 0), case_server || server}
      end)

    prune_orphans!(entries)

    # Keep a no-op re-bake idempotent: only stamp a new `baked_at` when something was
    # actually fetched. Otherwise the timestamp (and REPORT) would churn git on every
    # incremental run that skips everything.
    baked_at = if baked_count > 0, do: timestamp(), else: prior.baked_at || timestamp()

    # Provenance: capture the live TwicPics version (from the oracle `Server` header)
    # whenever a case was actually fetched; otherwise preserve the prior value. The
    # ImagePipe libvips is captured fresh each run (it's the version the recorded
    # fixtures are calibrated against, feeding the conformance test's libvips_drift_hint).
    twicpics_version = server_header || prior.twicpics_version || "unknown"
    pipe_libvips_at_gen = Vix.Vips.version()

    manifest = %{
      twicpics_api: "v1",
      baked_at: baked_at,
      twicpics_version: twicpics_version,
      pipe_libvips_at_gen: pipe_libvips_at_gen,
      sources: sources,
      entries: entries
    }

    Manifest.write!(@manifest_path, manifest)
    write_report!(manifest)
    Mix.shell().info("Baked #{baked_count}/#{map_size(entries)} cases (#{@manifest_path}).")
  end

  defp validate_parses! do
    import Plug.Test, only: [conn: 2]

    parser_opts = TwicPics.validate_options!([])

    failures =
      Constellations.all()
      |> Enum.reject(& &1[:triage])
      |> Enum.flat_map(fn c ->
        case TwicPics.parse(conn(:get, Constellations.twicpics_path(c)), parser_opts) do
          {:ok, _} -> []
          other -> [{c.id, c.chain, other}]
        end
      end)

    if failures != [] do
      detail =
        Enum.map_join(failures, "\n", fn {id, ch, r} -> "  #{id}: #{ch} → #{inspect(r)}" end)

      Mix.raise(
        "parse gate: #{length(failures)} chain(s) don't parse — fix or triage:\n#{detail}"
      )
    end
  end

  # --- per-case ---
  defp bake_case(c, sources, prior, force, only) do
    src = sources[Constellations.source_file(c)]

    sig =
      Manifest.oracle_signature(%{
        chain: c.chain,
        suffix: Constellations.suffix(),
        source_sha256: src.sha256
      })

    fixture = "#{c.id}.png"
    path = Path.join(@fixtures_dir, fixture)

    case decide(c, prior, sig, path, force, only) do
      :keep ->
        Mix.shell().info("skip  #{c.id} (unchanged)")
        # prior is non-nil here (decide only returns :keep with a prior entry).
        {%{prior | authored_sha256: Manifest.authored_sha256(c)}, false, nil}

      :bake ->
        Mix.shell().info("bake  #{c.id}")
        {body, server_header} = fetch_oracle!(c, sources)
        File.write!(path, body)

        {%{
           authored_sha256: Manifest.authored_sha256(c),
           oracle_signature: sig,
           fixture_filename: fixture,
           fixture_sha256: Manifest.file_sha256(path)
         }, true, server_header}
    end
  end

  # Pure-ish skip decision (the staleness check itself is Manifest.fresh?/3):
  #   --force            → bake everything
  #   --only, listed     → bake (explicit request)
  #   --only, unlisted   → keep prior if present (no network), else bake (no prior to keep)
  #   no flags, fresh    → keep
  #   no flags, stale    → bake
  defp decide(c, prior, sig, path, force, only) do
    cond do
      force -> :bake
      only && MapSet.member?(only, c.id) -> :bake
      only && not is_nil(prior) -> :keep
      is_nil(only) and Manifest.fresh?(prior, sig, path) -> :keep
      true -> :bake
    end
  end

  defp fetch_oracle!(c, sources) do
    src = sources[Constellations.source_file(c)]
    url = "#{src.hosted_url}?twic=v1/#{c.chain}/#{Constellations.suffix()}"

    case Req.get(url, decode_body: false, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: body} = resp} ->
        # Req lowercases header keys; `server` is a list (e.g. ["TwicPics/1.8.2"]).
        # Store the bare version (strip the "TwicPics/" product prefix) so the
        # recorded `twicpics_version` matches the committed value and a re-bake
        # doesn't churn it.
        server =
          case resp.headers["server"] |> List.wrap() |> List.first() do
            nil -> nil
            s -> String.replace_prefix(s, "TwicPics/", "")
          end

        {body, server}

      {:ok, %{status: s}} ->
        Mix.raise("#{c.id}: TwicPics returned #{s} for #{url}")

      {:error, e} ->
        Mix.raise("#{c.id}: #{Exception.message(e)} for #{url}")
    end
  end

  # --- sources: reuse recorded hosted URL + verify remote matches committed bytes;
  # upload to catbox only when no hosted URL is recorded. ---
  defp resolve_sources(prior) do
    Map.new(SourceInventory.all(), fn entry ->
      path = Path.join(@sources_dir, entry.file)
      committed = Manifest.file_sha256(path)
      # Prefer the inventory's pinned URL; else reuse a URL recorded by a prior bake
      # (so an uploaded source isn't re-uploaded each run); else upload once.
      recorded_url = get_in(prior, [entry.file, :hosted_url])
      hosted_url = entry.hosted_url || recorded_url || upload_catbox!(path, entry)
      verify_remote!(entry, committed)
      {entry.file, %{sha256: committed, hosted_url: hosted_url}}
    end)
  end

  defp verify_remote!(%{source_bytes_url: nil}, _committed), do: :ok

  defp verify_remote!(%{source_bytes_url: url} = entry, committed) do
    case Req.get(url, decode_body: false, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        remote = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        if remote != committed do
          Mix.raise(
            "source #{entry.file}: hosted bytes (#{url}) differ from committed — re-upload or re-download."
          )
        end

      {:ok, %{status: s}} ->
        Mix.raise("source #{entry.file}: hosted bytes returned HTTP #{s} (#{url}).")

      {:error, e} ->
        Mix.raise(
          "source #{entry.file}: could not fetch hosted bytes — #{Exception.message(e)} (#{url})."
        )
    end
  end

  # Anonymous catbox upload → returns the file URL as plain text.
  defp upload_catbox!(path, entry) do
    form = [
      reqtype: "fileupload",
      fileToUpload: {File.read!(path), filename: entry.file, content_type: "image/png"}
    ]

    case Req.post(@catbox, form_multipart: form, decode_body: false) do
      {:ok, %{status: 200, body: body}} ->
        id = body |> String.trim() |> Path.basename()
        "https://imagepipe.twic.pics/#{id}"

      other ->
        Mix.raise("catbox upload failed for #{entry.file}: #{inspect(other)}")
    end
  end

  defp prune_orphans!(entries) do
    keep = entries |> Map.values() |> Enum.map(& &1.fixture_filename) |> MapSet.new()

    @fixtures_dir
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, Path.basename(&1)))
    |> Enum.each(fn orphan ->
      Mix.shell().info("prune #{Path.basename(orphan)}")
      File.rm!(orphan)
    end)
  end

  defp empty_manifest,
    do: %{
      twicpics_api: "v1",
      baked_at: nil,
      twicpics_version: nil,
      pipe_libvips_at_gen: nil,
      sources: %{},
      entries: %{}
    }

  defp write_report!(manifest), do: File.write!("#{@base}/REPORT.md", report_md(manifest))

  defp report_md(m) do
    rows =
      m.entries
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map_join("\n", fn {id, e} ->
        "| `#{id}` | #{e.fixture_filename} | #{String.slice(e.fixture_sha256, 0, 12)} |"
      end)

    "# TwicPics differential — bake report\n\n" <>
      "Baked: #{m.baked_at} · TwicPics: #{m.twicpics_version} · " <>
      "libvips (at gen): #{m.pipe_libvips_at_gen}\n\n" <>
      "| case | fixture | sha256 |\n|---|---|---|\n" <> rows <> "\n"
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
