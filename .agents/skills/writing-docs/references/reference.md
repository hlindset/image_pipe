# Reference

Reference describes the machinery: options, functions, URL syntax, status
codes, telemetry events. The reader consults it while working, looks up one
fact, and leaves. It should be accurate, complete, and boringly consistent.

## Where reference lives in this repo

- **Modules and functions:** `@moduledoc` and `@doc`. This is the default home.
  Docs next to the code are more likely to stay true, and ExDoc already
  presents them as reference.
- **Configuration options:** the moduledoc of the module that validates them.
  Each option gets its type, default, and what it does.
- **URL options:** the pages under `docs/processing/`. They are reference for
  the URL grammar, written for image consumers. Examples use tabs, URL
  first and Elixir second (see `references/audiences.md`).
- **Cross-cutting tables:** `docs/telemetry-events.md`, `docs/errors.md`.

Guides link to these. They don't repeat them.

## Scope of a reference page

A reference page covers its own subject and nothing else. How URLs, groups,
and option values work in general is shared material: it lives on one
general page, and option pages link to it once near the top. A resize page
lists resize options and their behavior. It doesn't teach URL structure,
signing, or where the base URL comes from.

Explain a value type where an entry uses it ("a hex color such as `fff`, or
a CSS name such as `white`"), and link to the shared page for the full
syntax. Don't open the page with a glossary of value types.

## What a reference entry contains

- The name exactly as the code spells it.
- Type or accepted values, and the default.
- What it does, in one or two neutral sentences.
- Surprising behavior, stated with its reason so the reader can predict it:
  "`dpr` multiplies the sizes you request. Without `w`, `h`, `min-w`, or
  `min-h` there is nothing to multiply, so the image keeps its own size."
- Limits, interactions, and errors. "Requires a crop or cover resize in the
  same group. Otherwise the request fails with `400`."
- A short example of correct usage. Keep it to a line or two.

Structure reference like the code is structured. If options are grouped by
module or by URL group in the code, group them the same way in the docs.

## What it leaves out

- Instructions for reaching a goal. Move them to a how-to guide.
- Rationale and history. Move them to explanation.
- Opinion and recommendations, beyond the hard rules ("must", "never").
- Narrative. Each entry should read on its own when someone lands on it from a
  search.

## Language

Neutral and declarative. "`max_body_bytes` limits the size of a stored
response. Larger responses are served but not cached." Use "must" and "never"
for hard rules. No "you might want to".

## Signs of drift

- "You should use this when…" (a how-to or explanation sentence)
- A paragraph on why the design is the way it is
- An example that grows into a multi-step walkthrough
- Entries in different shapes on the same page
- An option table in a guide that duplicates a moduledoc

## Elixir conventions

- Moduledoc: one-sentence summary, a short example, then sections for the
  concepts a caller needs (options, return values, errors).
- `@doc`: what the function does, its options, an `## Examples` section with
  `iex>` examples where the output is deterministic.
- Link modules and functions with backticks (`` `ImagePipe.run/4` ``) so ExDoc
  autolinks them.
