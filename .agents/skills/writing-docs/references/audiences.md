# Audiences

ImagePipe has several kinds of reader, and most of them never touch most of
the product. Every page serves one audience (or one shared layer, below) and
one Diátaxis kind. Decide both before writing.

## Who reads the docs

**Image consumer.** A frontend developer, a Phoenix template author, a
designer, requesting images from an ImagePipe server that runs separately
from their code. Often they or their own organization run that server, so
don't assume a stranger does: describe server settings as "set in the
server's configuration", not "ask whoever runs ImagePipe". They want to know how to
request an image and what the options do, at the level of "what will the
picture look like". They read URLs, not Elixir. Leave out mount options,
TOML, deployment, and caching internals.

**Server operator.** Runs `image_pipe_server` from Docker with `config.toml`
and environment variables. Knows HTTP, containers, and CDNs, not necessarily
Elixir. Never show them Elixir code. Configuration examples are TOML or env
vars.

**Elixir integrator.** An Elixir developer who adds `image_pipe` to their own
app. They may mount `ImagePipe.Plug` to serve images over HTTP, call
`ImagePipe.run/4` to process uploads or background jobs, or both with one
shared `ImagePipe.config/1`. Knows Elixir, Plug, and `mix`. Configuration
examples are Elixir keyword lists. Serving and in-process processing are
different tasks for the same reader, so they get separate how-to guides, not
separate audiences. A guide about processing in a job leaves out mounts, HTTP
caching headers, and CDNs.

**URL builder user.** An Elixir app that only generates signed URLs with
`image_pipe_url` for a server running elsewhere. Needs the builder, presets,
and signing keys. Leave out libvips, sources, and caches.

**Extender.** Writes a custom source or detector adapter, or a
telemetry handler. Reads behaviours, callbacks, and event reference. Usually
also an Elixir integrator.

Contributors are not an audience for product docs. `AGENTS.md` and
`docs/plans/` serve them.

## Shared layers

Some material is the same for several audiences. Write it once, in a form
that doesn't assume a surface, and link to it from each audience's pages.

- **The URL API.** Options, grammar, and what each option does to the image.
  Shared by image consumers, server operators, Elixir integrators, and URL
  builder users. Show every example as ExDoc tabs with the URL tab first
  (the default view) and the Elixir builder tab second. Option names in the
  prose use the URL spelling. Never mix Elixir into the prose.
- **Concepts.** Caching and freshness, processing order, signing, source
  identity. These work the same under the server and the Plug, so explanation
  pages talk about the behavior, not about one configuration syntax. When
  such a page mentions a setting, describe it in plain words ("allow storage
  for that source") and link to where each surface configures it. Never
  invent a neutral-sounding name ("the storage override") that appears
  nowhere in the code, the TOML, or the page.

## Paired audiences

Some audiences are two halves of one deployment. Keep them as separate
audiences, since they are usually different people, but connect their docs.

**Server operator and URL builder user.** The operator runs
`image_pipe_server`. The app builds signed URLs for it with `image_pipe_url`.
Both sides must agree on the signing keys, source encryption keys, preset
names, source prefixes, watermark names, and the base URL (see
`image_pipe/docs/shared-url-settings.md`).

- Document that agreement once, as a reference page that shows each setting's
  TOML and Elixir spelling side by side. This is the one place where both
  spellings belong on the same page.
- Keep one walkthrough that covers both sides end to end
  (`docs/building-server-urls.md`), and link to it from both audiences' entry
  points.
- When a page for one side touches the shared settings, link to the matching
  page for the other side ("configure the builder to match").

**Image consumer and the server's configuration.** The consumer needs a base
URL, preset names, and possibly signed URLs, all of which come from the
server's configuration. Their pages say which of these they need, and link to
where the server sets them up.

## Where audiences diverge

- **Configuration.** The same concept (a source, a cache, a signing key) is
  spelled as TOML for the server and as Elixir options for the Plug.
  Configuration reference is separate per surface. How-to guides split by
  surface only when the steps differ. When the steps are the same and only
  the syntax differs, as when putting a CDN in front, write one guide for
  both, state the prerequisite for both ("ImagePipe running in
  your app or as `image_pipe_server`"), and show each configuration block in
  ExDoc tabs:

  ```markdown
  <!-- tabs-open -->

  ### Plug

  (Elixir configuration)

  ### image_pipe_server

  (TOML configuration)

  <!-- tabs-close -->
  ```

- **Tutorials and getting-started guides.** One per entry point. "Serve your
  first image" looks completely different for a server operator and an Elixir
  integrator.

## Checks

- Could the intended reader follow this page without knowing anything the
  audience entry above says they lack? If a server page needs Elixir to make
  sense, it's a Plug page or it needs rewriting.
- Does the page drag in material for another audience? Move it and link.
- Does the landing page give each audience an obvious first link?
