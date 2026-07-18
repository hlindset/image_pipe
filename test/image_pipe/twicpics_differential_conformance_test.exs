defmodule ImagePipe.TwicpicsDifferentialConformanceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest}

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @manifest_path "#{@base}/manifest.exs"
  @arms [:framework, :dialect]
  @constellations Constellations.all()
  @default_render_census for arm <- @arms,
                             constellation <- @constellations,
                             is_nil(constellation[:triage]),
                             do: {arm, constellation}
  @triage_render_census for arm <- @arms,
                            constellation <- @constellations,
                            not is_nil(constellation[:triage]),
                            do: {arm, constellation}

  setup_all do
    unless File.exists?(@manifest_path) do
      raise "No fixtures: missing #{@manifest_path}. Bootstrap: mise run twic:bake"
    end

    {:ok,
     manifest: Manifest.load!(@manifest_path),
     plug_opts: Map.new(@arms, &{&1, Harness.plug_opts(&1)})}
  end

  for {arm, constellation} <- @default_render_census ++ @triage_render_census do
    @arm arm
    @c constellation
    # Recorded-but-unresolved TwicPics divergences are quarantined: excluded by
    # default, runnable via `--include twicpics_triage` (see the constellation's
    # `:triage` reason + tracking issue).
    if constellation[:triage], do: @tag(:twicpics_triage)

    test "#{@arm}: #{@c.id} (#{@c.verdict}/#{@c.group})", %{
      manifest: manifest,
      plug_opts: plug_opts
    } do
      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed — run `mix twicpics.reauthor` (tol/verdict) or re-bake."

      out = Harness.render_image(@c, Map.fetch!(plug_opts, @arm))
      fixture = fixture_image(@c, entry)

      assert PixelCompare.same_dims?(out, fixture),
             "#{@c.id}: dims #{inspect(PixelCompare.dims(out))} != fixture #{inspect(PixelCompare.dims(fixture))}"

      assert_verdict(@c, out, fixture, manifest)
    end
  end

  test "default render census covers each authored non-triaged constellation on both arms" do
    expected_per_arm = Enum.count(@constellations, &is_nil(&1[:triage]))

    assert Enum.frequencies_by(@default_render_census, &elem(&1, 0)) ==
             Map.new(@arms, &{&1, expected_per_arm})
  end

  # Dispatch on verdict: `:equal` asserts a per-band tolerance budget; `:diverges`
  # asserts the live diff sits inside its expected two-sided band (a monitored,
  # accepted divergence). `:triage` cases never reach here — they are `@tag`-excluded
  # above.
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
    tol = c[:tol] || Constellations.default_tol()
    outliers = PixelCompare.outliers(out, fixture, tol.threshold)

    assert outliers <= tol.budget,
           "#{c.id}: #{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})" <>
             libvips_drift_hint(manifest)
  end

  defp band_msg(:above_ceiling), do: "above its expected"
  defp band_msg(:below_floor), do: "below its expected (consider promoting to :equal)"

  # Fixtures are baked against specific source bytes (the manifest records each
  # source's hash). If a committed source drifts, every fixture comparison silently
  # compares against stale bytes — so verify the sources match here, with a clear
  # message, rather than letting it surface as a confusing pixel mismatch.
  test "committed sources match the manifest's recorded hashes", %{manifest: manifest} do
    for {filename, %{sha256: recorded}} <- manifest.sources do
      assert Manifest.file_sha256(Path.join(@sources_dir, filename)) == recorded,
             "source #{filename} changed since bake — restore it or re-bake (`mise run twic:bake`)."
    end
  end

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} -> entry
      :error -> flunk("#{id}: no manifest entry. Run: mise run twic:bake")
    end
  end

  defp fixture_image(c, entry) do
    path = Harness.fixture_path(entry.fixture_filename)

    unless File.exists?(path) do
      flunk("#{c.id}: missing fixture #{path}. Run: mise run twic:bake")
    end

    assert Manifest.file_sha256(path) == entry.fixture_sha256,
           "#{c.id}: fixture sha256 mismatch — corrupted or edited; re-bake."

    Harness.fixture_image(entry)
  end

  # Tolerances are calibrated against the ImagePipe libvips that baked the fixtures.
  # On a different runtime libvips a pixel diff may be version skew rather than a
  # regression — surface that right in the failure. The manifest may not yet record
  # the calibration version (added in a later task); when absent, emit no hint.
  defp libvips_drift_hint(manifest) do
    case Map.get(manifest, :pipe_libvips_at_gen) do
      nil ->
        ""

      at_gen ->
        runtime = Vix.Vips.version()

        if runtime == at_gen do
          ""
        else
          " (runtime libvips #{runtime}; fixtures calibrated at #{at_gen} — " <>
            "a diff may be version skew, not a regression)"
        end
    end
  end
end
