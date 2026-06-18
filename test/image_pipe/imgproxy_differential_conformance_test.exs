defmodule ImagePipe.ImgproxyDifferentialConformanceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Harness, Manifest}

  @base "test/support/image_pipe/test/imgproxy_differential"
  @sources_dir "#{@base}/sources"
  @manifest_path "#{@base}/manifest.exs"

  setup_all do
    unless File.exists?(@manifest_path) do
      raise "No fixtures: missing #{@manifest_path}. " <>
              "Bootstrap: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
    end

    manifest = Manifest.load!(@manifest_path)

    # Provenance note: the fixtures were baked by imgproxy's libvips; ImagePipe runs its
    # own. The two report different version *schemes* — imgproxy exposes only the
    # `.so` ABI soname (no release string, no `vips` CLI in the darthsim image), Vix only
    # the release — so they can't be compared directly. A pixel diff may reflect libvips
    # drift rather than a regression; we record both and always compare.
    IO.puts(
      :stderr,
      "[imgproxy-differential] fixtures baked by imgproxy libvips " <>
        "#{manifest.imgproxy_libvips} (.so ABI soname); ImagePipe running " <>
        "#{Vix.Vips.version()} (release). Different version schemes — not directly " <>
        "comparable; pixel diffs may reflect libvips drift."
    )

    {:ok, manifest: manifest}
  end

  for constellation <- Constellations.all() do
    @c constellation
    # Recorded-but-unresolved imgproxy discrepancies are quarantined: excluded by
    # default, runnable via `--include imgproxy_triage` (see the constellation's
    # `:triage` reason + tracking issue).
    if constellation[:triage], do: @tag(:imgproxy_triage)

    test "#{@c.id} (#{@c.verdict}/#{@c.group})", %{manifest: manifest} do
      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed since generation — run `mix imgproxy.reauthor` " <>
               "(tol/verdict-only edits) or regenerate fixtures."

      run_constellation(@c, entry, manifest)
    end
  end

  # Fixtures are baked against specific source bytes (the manifest records each source's
  # hash). If a committed source drifts, every fixture comparison silently compares
  # against stale bytes — so verify the sources match here, with a clear message, rather
  # than letting it surface as a confusing pixel mismatch.
  test "committed sources match the manifest's recorded hashes", %{manifest: manifest} do
    for {filename, recorded_sha256} <- manifest.sources do
      path = Path.join(@sources_dir, filename)

      assert Manifest.file_sha256(path) == recorded_sha256,
             "source #{filename} changed since the fixtures were baked — restore it or " <>
               "regenerate (`mise run diff:bake`)."
    end
  end

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} ->
        entry

      :error ->
        flunk(
          "#{id}: no manifest entry. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
        )
    end
  end

  defp run_constellation(%{group: :transform} = c, entry, manifest) do
    out = Harness.render_image(c)
    fixture = fixture_image(c, entry)
    assert_same_dims!(c, out, fixture)
    assert_verdict(c, out, fixture, manifest)
  end

  defp run_constellation(%{group: :lossy} = c, entry, _manifest) do
    {body, content_type} = Harness.render(c)
    out = Image.open!(body, access: :random, fail_on: :error)

    assert {Image.width(out), Image.height(out)} == {entry.width, entry.height},
           "#{c.id}: dims #{inspect({Image.width(out), Image.height(out)})} != #{inspect({entry.width, entry.height})}"

    assert content_type == entry.content_type,
           "#{c.id}: content-type #{inspect(content_type)} != #{inspect(entry.content_type)}"
  end

  # Dispatch on verdict: `:equal` asserts a per-band tolerance budget; `:diverges`
  # asserts the live diff sits inside its expected two-sided band (a monitored,
  # accepted divergence). imgproxy has no `:diverges` constellation yet — this is the
  # shared mechanism, wired uniformly so it works the moment one needs it. `:triage`
  # cases never reach here (they are `@tag`-excluded above).
  defp assert_verdict(%{verdict: :diverges} = c, out, fixture, manifest) do
    case PixelCompare.classify_divergence(out, fixture, c.divergence) do
      :ok ->
        :ok

      {:error, bound, %{metric: metric, value: value, band: band}} ->
        flunk(
          "#{c.id}: :diverges #{metric}=#{value} is #{band_msg(bound)} band #{inspect(band)}" <>
            libvips_drift_hint(manifest)
        )
    end
  end

  defp assert_verdict(c, out, fixture, manifest) do
    tol = c.tol || Constellations.default_tol()
    outliers = PixelCompare.outliers(out, fixture, tol.threshold)

    assert outliers <= tol.budget,
           "#{c.id}: #{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})" <>
             libvips_drift_hint(manifest)
  end

  defp band_msg(:above_ceiling), do: "above its expected"
  defp band_msg(:below_floor), do: "below its expected (consider promoting to :equal)"

  defp assert_same_dims!(c, out, fixture) do
    assert PixelCompare.same_dims?(out, fixture),
           "#{c.id}: dims #{inspect(PixelCompare.dims(out))} != fixture #{inspect(PixelCompare.dims(fixture))}"
  end

  # Tolerances are calibrated against the ImagePipe libvips that baked the fixtures
  # (recorded in the manifest, same release scheme as `Vix.Vips.version/0`). On a
  # different runtime libvips (CI, another machine, a Vix bump) a pixel diff may be
  # version skew rather than a regression — surface that right in the failure.
  defp libvips_drift_hint(manifest) do
    runtime = Vix.Vips.version()

    if runtime == manifest.pipe_libvips_at_gen do
      ""
    else
      " (runtime libvips #{runtime}; fixtures calibrated at #{manifest.pipe_libvips_at_gen} — " <>
        "a diff may be version skew, not a regression)"
    end
  end

  defp fixture_image(c, entry) do
    path = Harness.fixture_path(entry)

    unless File.exists?(path) do
      flunk(
        "#{c.id}: missing fixture #{path}. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
      )
    end

    assert Manifest.file_sha256(path) == entry.fixture_sha256,
           "#{c.id}: fixture #{path} sha256 mismatch — corrupted or edited; regenerate."

    Harness.fixture_image(entry)
  end
end
