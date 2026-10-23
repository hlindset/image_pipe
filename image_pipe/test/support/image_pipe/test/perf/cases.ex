defmodule ImagePipe.Test.Perf.Cases do
  @moduledoc """
  Requests `mix imgproxy.bench --compare` times besides the imgproxy reference
  cases: costs imgproxy has no equivalent for, on photo-sized sources.

  The sources live under `perf/` in the bench's source directory:

    * `photo12.jpg` is `priv/static/images/flower.jpg` (3024×4032, sRGB).
    * The server under test makes the other variants from it before the
      run, with the requests in `variants/0`, so every image compared reads
      the same files.
    * `photo1.heic`, `photo1.jxl`, and `cmyk1.jpg` sit in `sources/` next to
      this file, since no server can write those formats. They're
      `flower.jpg` at 900×1200, saved by libvips: HEIC at quality 60, JPEG XL
      at Q 80 and effort 7, and JPEG at quality 85 after converting to
      libvips' built-in CMYK profile, which the file embeds.

  A case's `tier` is `:pr` for the set every `perf` pull request runs, or
  `:nightly` for the slower or rarer cases only the scheduled runs and
  `perf-nightly` pull requests time.

  A case's `config` is `:plain` for the bench's usual server, with no cache
  and a file source, or `:cached` for a server with an output cache that
  reads through the `origin` HTTP source from an origin container. A case's `random` puts a new token in every request's URL, so
  every request misses: `:output` in a cachebuster, `:source` in the source
  path, which also makes each request a new original.

  `bursts/1` lists requests that run all at once instead. A burst's
  `originals` is `:one` for concurrent requests for one new original, which
  the origin sends at a paced rate so the requests overlap its download, or
  `:each` for a new original per request, sent at the origin's full rate,
  like a grid of thumbnails loading cold.
  """
  use Boundary, top_level?: true, deps: []

  @type t :: %{
          id: String.t(),
          kind: :lossy,
          family: String.t(),
          tier: :pr | :nightly,
          config: :plain | :cached,
          random: nil | :output | :source,
          source: String.t(),
          native: String.t()
        }

  @type burst :: %{
          id: String.t(),
          kind: :burst,
          family: String.t(),
          tier: :pr | :nightly,
          config: {:burst, :none | :output | :overload},
          originals: :one | :each,
          source: String.t(),
          natives: [String.t()]
        }

  @doc "The families these cases add to the reference suite's."
  @spec families() :: [String.t()]
  def families, do: ~w(decode colour autoquality placeholder cache concurrency)

  @doc """
  The files the server under test makes before the run: `{file, request}`,
  where the request applies to `perf/photo12.jpg`.
  """
  @spec variants() :: [{String.t(), String.t()}]
  def variants do
    [
      {"photo2.jpg", "w=1200/format=jpeg/q=90"},
      {"p3_2.jpg", "w=1200/profile=display-p3/format=jpeg/q=90"},
      {"p3_12.jpg", "profile=display-p3/format=jpeg/q=90"},
      {"adobe12.jpg", "profile=adobe-rgb/format=jpeg/q=90"},
      {"photo12.png", "format=png"},
      {"photo12.webp", "format=webp/q=80"},
      {"photo12.avif", "format=avif/q=60"}
    ]
  end

  @spec all() :: [t()]
  def all do
    [
      # Decoding each source format. Only JPEG and WebP shrink on load.
      c("decode_jpeg_12mp", "decode", :pr, "photo12.jpg", "w=400/format=jpeg"),
      c("decode_png_12mp", "decode", :nightly, "photo12.png", "w=400/format=jpeg"),
      c("decode_webp_12mp", "decode", :nightly, "photo12.webp", "w=400/format=jpeg"),
      c("decode_avif_12mp", "decode", :nightly, "photo12.avif", "w=400/format=jpeg"),
      c("decode_heic_1mp", "decode", :nightly, "photo1.heic", "w=400/format=jpeg"),
      c("decode_jxl_1mp", "decode", :nightly, "photo1.jxl", "w=400/format=jpeg"),
      c("decode_cmyk_1mp", "decode", :pr, "cmyk1.jpg", "w=400/format=jpeg"),
      # Colour policies on profiled sources.
      c("colour_p3_strip", "colour", :pr, "p3_2.jpg", "w=400/format=jpeg"),
      c("colour_p3_preserve", "colour", :pr, "p3_2.jpg", "w=400/profile=preserve/format=jpeg"),
      c(
        "colour_srgb_to_p3",
        "colour",
        :nightly,
        "photo2.jpg",
        "w=400/profile=display-p3/format=jpeg"
      ),
      c("colour_adobe_strip_12mp", "colour", :nightly, "adobe12.jpg", "w=400/format=jpeg"),
      c(
        "colour_cmyk_preserve",
        "colour",
        :nightly,
        "cmyk1.jpg",
        "w=400/profile=preserve/format=jpeg"
      ),
      # Watermarks, whose colour path depends on the source's profile.
      c("wm_p3_srgb", "watermark", :pr, "p3_2.jpg", "w=400/wm=mark/wm-scale=0.25/format=jpeg"),
      c(
        "wm_p3_preserve",
        "watermark",
        :nightly,
        "p3_2.jpg",
        "w=400/wm=mark/wm-scale=0.25/profile=preserve/format=jpeg"
      ),
      c(
        "wm_photo_srgb",
        "watermark",
        :nightly,
        "photo2.jpg",
        "w=400/wm=mark/wm-scale=0.25/format=jpeg"
      ),
      # Encoders at a typical page size.
      c("out_jpeg_800", "output", :nightly, "photo2.jpg", "w=800/format=jpeg"),
      c("out_webp_800", "output", :pr, "photo2.jpg", "w=800/format=webp"),
      c("out_avif_800", "output", :pr, "photo2.jpg", "w=800/format=avif"),
      # Quality searches: several encodes and scores a request.
      c("aq_webp_800", "autoquality", :pr, "photo2.jpg", "w=800/format=webp/autoquality=75"),
      c("aq_avif_800", "autoquality", :nightly, "photo2.jpg", "w=800/format=avif/autoquality=75"),
      c("aq_jpeg_800", "autoquality", :nightly, "photo2.jpg", "w=800/format=jpeg/autoquality=75"),
      c("aq_jpeg_12mp", "autoquality", :nightly, "photo12.jpg", "format=jpeg/autoquality=75"),
      c(
        "max_bytes_webp_800",
        "autoquality",
        :nightly,
        "photo2.jpg",
        "w=800/format=webp/max-bytes=40000"
      ),
      # Non-image outputs from a large source.
      c("info_12mp", "placeholder", :pr, "photo12.jpg", "output=info"),
      c("blurhash_12mp", "placeholder", :nightly, "photo12.jpg", "output=blurhash"),
      c("lqip_css_12mp", "placeholder", :pr, "photo12.jpg", "output=lqip-css"),
      # Caches: a hit, a miss for a new variant of an original fetched before,
      # and a miss that downloads a new original.
      cached("cache_hit", nil),
      cached("cache_miss_warm_source", :output),
      cached("cache_miss_cold", :source)
    ]
  end

  @doc """
  Bursts of `count` concurrent requests, each with the caches it runs with:

    * `burst_same`: identical requests, which should share one download and
      one generation.
    * `burst_sizes`: a different width each, which should share one
      download.

  And, in the `perf` set, `burst_same_wide`, 100 identical requests for one
  new original, which should share one download and one generation however
  many requests wait for them, and `burst_grid`, 100 requests for the same
  small output of 100 new originals. `burst_grid` passes the cache's 64
  writers, so it shows writes the cache drops when its writers or the file
  server can't keep up.

  The `burst_overload` cases send more work than the pool takes, with the
  server's default `max_queue` and `queue_timeout`, so some requests answer
  `503`: `burst_overload_small` 300 cold thumbnails, which a queue of 64
  mostly turns away, and `burst_overload_large` 40 cold full-size AVIF
  encodes, too slow for all of them to start within the queue timeout. Their
  configuration is `:overload`: the output cache, and the pool's defaults.
  """
  @spec bursts(pos_integer()) :: [burst()]
  def bursts(count) do
    same = List.duplicate("w=400/format=jpeg", count)
    sizes = for i <- 1..count, do: "w=#{100 + 100 * i}/format=jpeg"
    wide = List.duplicate("w=400/format=jpeg", 100)
    grid = List.duplicate("w=80/h=120/fit=cover/format=avif", 100)
    thumbnails = List.duplicate("w=80/h=120/fit=cover/format=avif", 300)
    full_size = List.duplicate("format=avif", 40)

    for {name, natives, originals, source, tier, caches} <- [
          {"burst_same", same, :one, "perf/photo2.jpg", :nightly, [:none, :output]},
          {"burst_sizes", sizes, :one, "perf/photo2.jpg", :nightly, [:none, :output]},
          {"burst_same_wide", wide, :one, "perf/photo2.jpg", :pr, [:output]},
          {"burst_grid", grid, :each, "perf/photo2.jpg", :pr, [:output]},
          {"burst_overload_small", thumbnails, :each, "perf/photo2.jpg", :pr, [:overload]},
          {"burst_overload_large", full_size, :each, "perf/photo12.jpg", :pr, [:overload]}
        ],
        cache <- caches do
      %{
        id: "#{name}_#{cache}",
        kind: :burst,
        family: "concurrency",
        tier: tier,
        config: {:burst, cache},
        originals: originals,
        source: source,
        natives: natives
      }
    end
  end

  defp c(id, family, tier, source, native),
    do: %{
      id: id,
      kind: :lossy,
      family: family,
      tier: tier,
      config: :plain,
      random: nil,
      source: "perf/" <> source,
      native: native
    }

  defp cached(id, random),
    do: %{
      c(id, "cache", :pr, "photo2.jpg", "w=400/format=jpeg")
      | config: :cached,
        random: random,
        source: "origin/perf/photo2.jpg"
    }
end
