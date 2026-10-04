# Tutorials

A tutorial is a lesson. The reader is a newcomer at study, and the tutorial
takes full responsibility for getting them to a working result. What the
reader *does* (build a thumbnail endpoint) is a vehicle for what they *learn*
(how sources, configuration, and URLs fit together).

## What a tutorial contains

- **A destination up front.** "In this guide we'll add an image endpoint to a
  Phoenix app and serve a resized thumbnail from it." Say what we will build,
  not "you will learn".
- **Prerequisites.** Elixir version, a Phoenix app or `mix new` project,
  libvips if relevant, and any earlier guide the reader must have finished.
- **One concrete path.** Exact commands, exact file paths, exact code. No
  forks, no "alternatively".
- **A visible result at every step.** After each change, show what the reader
  should see: the response status and content type, the image dimensions, the
  `iex>` output. Results build the reader's confidence that they're on track.
- **Expected output, including failures they might hit.** "If you see a `415`,
  your libvips build is missing the JPEG loader." This is the Phoenix habit of
  troubleshooting at the point of failure.
- **"Notice that…" prompts.** Point at the one thing worth seeing in each
  result, without explaining the theory behind it.
- **A close that looks back and forward.** One sentence on what was built, then
  links to the how-to guides and explanation that pick up from here.

## Teach ImagePipe, not the tools

The tools are the vehicle. Give Docker, curl, and shell commands without
commentary unless a detail matters for using ImagePipe (a flag the server
needs, for example). Everything else about a tool belongs in that tool's
docs. Spend every "notice that" on ImagePipe itself: what the
config does, how the URL maps to the image, what changing `w=` or `fit=`
does to the result. If a step's explanation is about a Docker flag, an HTTP
header, or `file` output, it is teaching the wrong thing. Prefer the most
natural way to see the result, usually opening the URL in a browser.

Leave production concerns (signing, TLS, caches, limits) out of the steps
and out of asides. Don't comment on the guide itself ("which keeps this
guide short"). Point to them once, at the end: "Before exposing the server,
set up [URL signing](…)."

## What it leaves out

- Explanation beyond a clause. "ImagePipe resolves the source before checking
  the cache (see [Cache](cache.md))" is enough.
- Options and alternatives. A tutorial that shows three ways to configure a
  source has become a how-to guide.
- Real-world variation: S3 credentials, CDN setup, production limits. Those
  are how-to guides the tutorial links to at the end.
- Reference tables.

## Language

Use "we" for the shared journey: "First, we add the dependency." "Now let's
request the image." Imperative steps, present tense, short sentences.

## Signs of drift

- A paragraph starts with "Under the hood" or "The reason for this is".
- The reader is asked to choose between options.
- A step can fail in a way the page doesn't mention.
- The page assumes the reader already knows what a source adapter or a group is.

## ImagePipe notes

- Use the Plug entry point for the first tutorial. It gives the most visible
  result (an image in the browser) for the least setup.
- Use `ImagePipe.Source.File` with a local directory so the tutorial needs no
  network or credentials.
- Show the URL and the result together:

  ```text
  GET /images/w=300/h=200/fit=cover/src/cat.jpg
  200 OK, content-type: image/webp, 300×200
  ```

- Tutorials are the only kind that must be tested end to end by actually
  following them. Do that before calling one finished.
