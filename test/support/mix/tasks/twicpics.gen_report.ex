defmodule Mix.Tasks.Twicpics.GenReport do
  @shortdoc "Self-contained TwicPics differential visual-diff report (no network)"
  @moduledoc """
  Renders ImagePipe live for every constellation in `constellations.ex`, compares
  against the committed TwicPics fixtures via pixel comparison, and writes a single
  self-contained `report.html` (images base64-inlined, slider + fonts from CDN). No
  network — the fixtures are already committed and ImagePipe renders are live. A DX /
  inspection tool only: it touches no fixtures, manifest, or the `mix test` lane.

      mise exec -- mix twicpics.gen_report [--out PATH]

  Auto-selects `MIX_ENV=test` via `mix.exs` `preferred_envs` (the task lives in
  `test/support`). `--out` defaults to `report.html` beside the harness (gitignored).

  Renders ALL cases including triaged — quarantined divergences are the ones most
  worth eyeballing. Each card carries a quarantine badge when its constellation has
  a `triage` key.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Heatmap
  alias ImagePipe.Test.Differential.PixelCompare

  alias ImagePipe.Test.TwicpicsDifferential.{
    Constellations,
    Harness,
    Manifest,
    ReportHtml
  }

  alias Vix.Vips.Operation

  @base "test/support/image_pipe/test/twicpics_differential"
  @manifest_path "#{@base}/manifest.exs"
  @default_out "#{@base}/report.html"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    out = Keyword.get(opts, :out, @default_out)

    {:ok, _} = Application.ensure_all_started(:image_pipe)

    manifest = Manifest.load!(@manifest_path)
    plug_opts = Harness.plug_opts()

    cards = Enum.map(Constellations.all(), fn c -> build_card(c, manifest, plug_opts) end)

    doc = %{provenance: provenance(manifest), cards: cards}
    File.write!(out, ReportHtml.render(doc))
    Mix.shell().info("Wrote visual-diff report (#{length(cards)} cards) to #{Path.expand(out)}")
  end

  defp provenance(manifest) do
    %{
      twicpics_version: manifest.twicpics_version,
      pipe_libvips_at_gen: manifest.pipe_libvips_at_gen,
      runtime_libvips: Vix.Vips.version()
    }
  end

  defp build_card(c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    {body, content_type} = Harness.render(c, plug_opts)
    pipe = Image.open!(body, access: :random, fail_on: :error)
    fixture = Harness.fixture_image(entry)
    tol = c[:tol] || Constellations.default_tol()

    card =
      %{
        id: c.id,
        group: c.group,
        verdict: c.verdict,
        url: Constellations.twicpics_path(c),
        summary: c.chain,
        triage: c[:triage],
        divergence: c[:divergence],
        tol: c[:tol],
        hash_drift?: Manifest.authored_sha256(c) != entry.authored_sha256,
        pipe_dims: PixelCompare.dims(pipe)
      }
      |> Map.merge(status_fields(c, pipe, fixture, tol))
      |> finalize_flags()

    attach_images(card, body, content_type, pipe, entry, tol)
  end

  defp status_fields(c, pipe, fixture, tol) do
    fixture_dims = PixelCompare.dims(fixture)

    cond do
      PixelCompare.dims(pipe) != fixture_dims ->
        %{
          fixture_dims: fixture_dims,
          status: :dims_mismatch,
          metric_text:
            "dims #{fmt_dims(PixelCompare.dims(pipe))} ≠ TwicPics #{fmt_dims(fixture_dims)}"
        }

      c.verdict == :diverges ->
        Map.put(diverges_fields(pipe, fixture, c.divergence), :fixture_dims, fixture_dims)

      true ->
        outliers = PixelCompare.outliers(pipe, fixture, tol.threshold)

        %{
          fixture_dims: fixture_dims,
          status: if(outliers <= tol.budget, do: :pass, else: :over_budget),
          metric_text: "#{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
        }
    end
  end

  # A `:diverges` case is gated by its two-sided band (`classify_divergence/3`), not
  # the `:equal` tolerance budget. In band → `:diverges` (monitored, passes the lane);
  # out of band → `:diverges_out_of_band` (a regression or promote signal — lane red).
  defp diverges_fields(pipe, fixture, divergence) do
    d = PixelCompare.diagnose(pipe, fixture, [2])

    case PixelCompare.classify_divergence(pipe, fixture, divergence) do
      :ok ->
        %{
          status: :diverges,
          metric_text:
            "maxΔ #{d.max_delta} ∈ #{inspect(divergence.max_delta)}, " <>
              "#{Map.fetch!(d.over, 2)} over Δ2 ∈ #{inspect(divergence.outliers)} — within band"
        }

      {:error, bound, %{metric: metric, value: value, band: band}} ->
        %{
          status: :diverges_out_of_band,
          metric_text: "#{metric}=#{value} #{bound} band #{inspect(band)}"
        }
    end
  end

  defp finalize_flags(card) do
    failure? =
      card.hash_drift? or card.status in [:over_budget, :dims_mismatch, :diverges_out_of_band]

    # `flagged?` is anything noteworthy (any divergence — quarantined, monitored, or a
    # failure). `failing?` is the stricter "would the default `mix test` lane go red"
    # subset: a quarantined (`:triage`) case is excluded from the lane, and an in-band
    # `:diverges` case passes it, so both are flagged but not failing.
    card
    |> Map.put(:flagged?, failure? or card.status == :diverges)
    |> Map.put(:failing?, failure? and is_nil(card.triage))
  end

  # Attach base64 data URIs. Images are displayed from ORIGINAL bytes (no
  # re-encode): the TwicPics fixture from its on-disk PNG, the pipe render from
  # the response body. Decoded images feed the heatmaps only.
  defp attach_images(%{status: :dims_mismatch} = card, body, content_type, _pipe, entry, _tol) do
    Map.merge(card, %{
      oracle_img: data_uri("image/png", File.read!(Harness.fixture_path(entry.fixture_filename))),
      pipe_img: data_uri(content_type, body),
      heat_banded: nil,
      heat_raw: nil,
      heat_normalized: nil
    })
  end

  defp attach_images(card, body, content_type, pipe, entry, tol) do
    fixture = Harness.fixture_image(entry)
    a = to_rgb(fixture)
    b = to_rgb(pipe)
    threshold = tol.threshold

    Map.merge(card, %{
      oracle_img: data_uri("image/png", File.read!(Harness.fixture_path(entry.fixture_filename))),
      pipe_img: data_uri(content_type, body),
      heat_banded: data_uri("image/png", Heatmap.png(Heatmap.banded_heatmap(a, b, threshold))),
      heat_raw: data_uri("image/png", Heatmap.png(Heatmap.raw_heatmap(a, b))),
      heat_normalized: data_uri("image/png", Heatmap.png(Heatmap.normalized_heatmap(a, b)))
    })
  end

  defp data_uri(content_type, bytes), do: "data:#{content_type};base64,#{Base.encode64(bytes)}"

  # Align to a common 3-band RGB frame so the heatmap diff never raises on band-count
  # mismatch (TwicPics PNGs are RGBA; an ImagePipe render may be RGB). Visualizes RGB
  # deltas; the verdict metric (PixelCompare) still counts all bands incl. alpha.
  defp to_rgb(image) do
    case Image.bands(image) do
      3 -> image
      n when n > 3 -> ok!(Operation.extract_band(image, 0, n: 3))
      _ -> image
    end
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("vips operation failed: #{inspect(reason)}")

  defp fmt_dims({w, h}), do: "#{w}×#{h}"
end
