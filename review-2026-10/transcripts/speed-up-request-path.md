# Speed up request path

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:44:45Z

Speed up request path

## Claude · 2026-10-04T11:49:06Z

Heads up on the cloud setup: `mise run setup` failed in this session, so deps weren't fetched automatically. `mise install` couldn't get python, uv, pnpm, rust and shot-scraper because `mise-versions.jdx.dev` isn't in the network allowlist and the unauthenticated GitHub API calls hit the rate limit (403). Erlang 29.1.1 and Elixir 1.20.4 did install, and hex.pm works.

I've worked around it here (`MISE_EXEC_AUTO_INSTALL=false`, then `mix deps.get` by hand), so the Elixir work can go ahead. To fix it for future sessions, add `mise-versions.jdx.dev` to the environment's allowed hosts. Pnpm, uv and rust would still fail on the GitHub rate limit unless a `GITHUB_TOKEN` is set as an environment secret, or the setup hook installs only erlang and elixir (`mise install erlang elixir`).

## Claude · 2026-10-04T11:49:23Z

I've stopped. I hadn't changed any code yet, so there's nothing to commit. All four fixes are still open: skip the double option parse, batch streamed chunks, build cache headers once, and parse cookies only when needed.

One thing to know if you do them locally. On a cache miss that has to fetch the source, the context gets re-represented after the open (`execution.ex:186`). So "build cache headers once" can only reuse the first set when the representation and source record didn't change, or when the request isn't degraded.

## Claude · 2026-10-04T14:16:56Z

There was nothing to push from this thread. I stopped before changing any code, and the working tree is clean. All four request-path fixes are still to do, along with the cache-headers caveat in my last message.
