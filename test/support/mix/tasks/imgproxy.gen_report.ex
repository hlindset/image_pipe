defmodule Mix.Tasks.Imgproxy.GenReport do
  @shortdoc "Generate a self-contained visual-diff HTML report for the imgproxy differential suite"
  @moduledoc """
  Renders ImagePipe live for every constellation in `constellations.ex`, compares
  against the committed imgproxy fixtures, and writes a single self-contained
  `report.html` (images base64-inlined, slider + fonts from CDN). No Docker — the
  imgproxy fixtures are already committed and ImagePipe renders are live. A DX /
  inspection tool only: it touches no fixtures, manifest, or the `mix test` lane.

      mise exec -- mix imgproxy.gen_report [--out PATH]

  Auto-selects `MIX_ENV=test` via `mix.exs` `preferred_envs` (the task lives in
  `test/support`). `--out` defaults to `report.html` beside the harness (gitignored).
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Heatmap

  alias ImagePipe.Test.ImgproxyDifferential.{
    Constellations,
    Harness,
    Manifest,
    OptsSummary,
    PixelCompare,
    ReportHtml
  }

  alias Vix.Vips.Operation

  @base "test/support/image_pipe/test/imgproxy_differential"
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
      imgproxy_digest: manifest.imgproxy_digest,
      imgproxy_libvips: manifest.imgproxy_libvips,
      pipe_libvips_at_gen: manifest.pipe_libvips_at_gen,
      runtime_libvips: Vix.Vips.version()
    }
  end

  defp build_card(c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    {body, content_type} = Harness.render(c, plug_opts)
    pipe = Image.open!(body, access: :random, fail_on: :error)

    card =
      %{
        id: c.id,
        group: display_group(c),
        verdict: c.verdict,
        url: Constellations.imgproxy_path(c),
        summary: OptsSummary.describe(c.opts),
        triage: c.triage,
        tol: c.tol,
        hash_drift?: Manifest.authored_sha256(c) != entry.authored_sha256,
        pipe_dims: dims(pipe)
      }
      |> Map.merge(group_fields(c, entry, pipe, content_type))
      |> finalize_flags()

    attach_images(card, body, content_type, pipe, entry)
  end

  # The `:diverges` constellation is stored as `group: :transform, verdict:
  # :diverges` (it IS a fixture pixel comparison). For the report's display
  # category/filter/counts it's its own `:known_divergence` bucket; the metric
  # dispatch below still uses the constellation's real `group`/`verdict`, so this
  # is display-only.
  defp display_group(%{verdict: :diverges}), do: :known_divergence
  defp display_group(%{group: group}), do: group

  # transform / :diverges: compare against the committed fixture image.
  defp group_fields(%{group: :transform} = c, entry, pipe, _content_type) do
    fixture = Harness.fixture_image(entry)
    fixture_dims = dims(fixture)

    if fixture_dims != dims(pipe) do
      %{
        fixture_dims: fixture_dims,
        status: :dims_mismatch,
        metric_text: "dims #{fmt_dims(dims(pipe))} ≠ imgproxy #{fmt_dims(fixture_dims)}"
      }
    else
      Map.put(metric_fields(c, pipe, fixture), :fixture_dims, fixture_dims)
    end
  end

  defp group_fields(%{group: :lossy}, entry, pipe, content_type) do
    ok? = dims(pipe) == {entry.width, entry.height} and content_type == entry.content_type

    %{
      fixture_dims: nil,
      status: if(ok?, do: :contract_ok, else: :contract_mismatch),
      metric_text:
        "dims #{fmt_dims(dims(pipe))} (expected #{fmt_dims({entry.width, entry.height})}); " <>
          "type #{inspect(content_type)} (expected #{inspect(entry.content_type)})"
    }
  end

  defp metric_fields(%{verdict: :diverges} = c, pipe, fixture) do
    %{metric: :fraction_over, threshold: threshold, floor: floor} = c.divergence
    frac = PixelCompare.fraction_over(pipe, fixture, threshold)

    %{
      status: if(frac >= floor, do: :diverges_ok, else: :diverges_below_floor),
      metric_text: "#{Float.round(frac, 4)} fraction over Δ#{threshold} (floor #{floor})"
    }
  end

  defp metric_fields(%{verdict: :equal} = c, pipe, fixture) do
    tol = c.tol || Constellations.default_tol()
    outliers = PixelCompare.outliers(pipe, fixture, tol.threshold)

    %{
      status: if(outliers <= tol.budget, do: :pass, else: :over_budget),
      metric_text: "#{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
    }
  end

  defp finalize_flags(card) do
    failure? =
      card.hash_drift? or
        card.status in [:over_budget, :diverges_below_floor, :dims_mismatch, :contract_mismatch]

    # `flagged?` is anything noteworthy (a divergence, quarantined or not). `failing?`
    # is the stricter "would the default `mix test` lane go red" subset: a quarantined
    # (`:triage`) case is excluded from the lane, so it is flagged but not failing.
    card
    |> Map.put(:flagged?, failure?)
    |> Map.put(:failing?, failure? and is_nil(card.triage))
  end

  # Attach base64 data URIs. Images are displayed from ORIGINAL bytes (no
  # re-encode): the imgproxy fixture from its on-disk PNG, the pipe render from
  # the response body. Decoded images feed the diff/heatmaps only.
  defp attach_images(%{group: :lossy} = card, body, content_type, _pipe, _entry) do
    Map.merge(card, %{
      imgproxy_img: nil,
      pipe_img: data_uri(content_type, body),
      heat_banded: nil,
      heat_raw: nil,
      heat_normalized: nil
    })
  end

  defp attach_images(%{status: :dims_mismatch} = card, body, content_type, _pipe, entry) do
    Map.merge(card, %{
      imgproxy_img: data_uri("image/png", File.read!(Harness.fixture_path(entry))),
      pipe_img: data_uri(content_type, body),
      heat_banded: nil,
      heat_raw: nil,
      heat_normalized: nil
    })
  end

  defp attach_images(card, body, content_type, pipe, entry) do
    fixture = Harness.fixture_image(entry)
    a = to_rgb(fixture)
    b = to_rgb(pipe)
    threshold = (card.tol || Constellations.default_tol()).threshold

    Map.merge(card, %{
      imgproxy_img: data_uri("image/png", File.read!(Harness.fixture_path(entry))),
      pipe_img: data_uri(content_type, body),
      heat_banded: data_uri("image/png", Heatmap.png(Heatmap.banded_heatmap(a, b, threshold))),
      heat_raw: data_uri("image/png", Heatmap.png(Heatmap.raw_heatmap(a, b))),
      heat_normalized: data_uri("image/png", Heatmap.png(Heatmap.normalized_heatmap(a, b)))
    })
  end

  defp data_uri(content_type, bytes), do: "data:#{content_type};base64,#{Base.encode64(bytes)}"

  # Align to a common 3-band RGB frame so the diff never raises on band-count
  # mismatch (RGB vs RGBA, e.g. alpha_resize / background_alpha). Visualizes RGB
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

  defp dims(image), do: {Image.width(image), Image.height(image)}
  defp fmt_dims({w, h}), do: "#{w}×#{h}"
end
