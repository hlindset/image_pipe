# How-to guides

A how-to guide is a recipe. The reader already knows ImagePipe and has a
concrete goal: put a CDN in front, serve from S3, sign URLs. The guide gets
them there and assumes competence along the way.

## What a how-to guide contains

- **A goal in the reader's terms.** "Serving images from private S3
  buckets", not "S3 source adapter configuration". The title names the
  outcome with a gerund, not the machinery.
- **The starting point.** One or two lines: "This assumes you already have an
  ImagePipe set up (see [Getting started with Phoenix](phoenix-getting-started.md))."
- **Steps in a sensible order.** Each step is an action. Actions can include
  judgement ("Decide how long originals may be cached. For mostly static
  catalogs, a day is reasonable.").
- **Forks for real-world variation.** "If your bucket uses temporary
  credentials, add a `credentials` provider instead." Keep forks short and
  link out for long ones.
- **How to confirm it worked.** The response header, the cache file, the
  telemetry event that shows up.
- **A next step or related guides** at the end.

## What it leaves out

- Teaching. The reader is at work, not study. Don't explain what a source is.
- Background and rationale beyond a clause. Link to the explanation page.
- The full option list. Show the options this goal needs and link to the
  reference (the moduledoc or option docs) for the rest.
- Steps any competent Elixir developer already knows ("run `mix deps.get`"
  can stay as a single line, but don't explain what it does).

## Language

"You" and the imperative: "Add a cache to your Plug configuration." "If you need X, do
Y." Conditional imperatives handle variation without becoming a tutorial.

## Signs of drift

- The page is organized around an API surface rather than a goal ("Cache
  options" is reference, "Caching processed images on disk" is a how-to).
- It starts by teaching basics.
- It lists every option with its default.
- The goal is too broad to finish ("Using ImagePipe in production").
  Split it.

## ImagePipe notes

Good examples to follow, each written for both surfaces with Plug and
`image_pipe_server` tabs: `caching-processed-images.md`,
`serving-through-a-cdn.md`, `enabling-detection.md`, and `signing-urls.md`.
