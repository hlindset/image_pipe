---
name: writing-docs
description: Write, restructure, or review ImagePipe documentation using the Diátaxis framework and the project's house style. Use this whenever you create or edit anything under image_pipe/docs/ or image_pipe_server/docs/, a project README, a guide, a @moduledoc or @doc, or when asked to review, audit, reorganize, or improve docs, even for a small wording fix or a single new section. Also use it when a code change needs its documentation updated.
---

# Writing ImagePipe docs

Good documentation answers one reader need per page. Most weak pages are weak
because they mix needs: a tutorial that stops to explain theory, a how-to guide
that lists every option, a reference page full of advice. This skill keeps each
page doing one job, written in a style modelled on the Elixir getting-started
guide, the Phoenix guides, and the SvelteKit docs.

## Every docs change

Any change to documentation text is docs writing: a new page, a restructure,
or a one-sentence factual fix. Correct facts are necessary but not enough.
A fix that is true but badly written still needs another pass. For every
change, do all of these:

1. Read `references/style.md`, `references/audiences.md`, and the reference
   file for the page's kind.
2. Make the change. Verify every claim against the code. When the code
   looks wrong, surprising, or awkward to document (a likely bug, an API
   that needs a workaround, docs and code that disagree in a way the code
   might need to fix), document what the code does today and file a beads
   issue for it: `bd create "<title>" -l docs-found --deps
   discovered-from:<epic or issue you're working on>` with file:line
   evidence, and a "Docs to update when fixed:" line naming each page and
   section (or moduledoc) that states the current behavior. Don't silently
   document around it.
3. Run the four final-read passes (see "Final read" below) on the text you
   changed.
4. Get a fresh review (workflow step 6).
5. End with a closing summary:

   ```text
   Audience: <audience>   Kind: <kind>
   Final read: passes 1-4 done
   Review: <findings, and what you fixed>
   Left alone: <existing problems on the page outside your change>
   Filed: <beads issues for code problems found, or none>
   ```

## The four kinds

Diátaxis sorts documentation by two questions. Does the text inform **action**
(doing) or **cognition** (knowing)? Does the reader want to **acquire** a skill
(study) or **apply** one (work)?

| | Study | Work |
| --- | --- | --- |
| **Action** | Tutorial: a lesson that builds something | How-to guide: steps to a goal the reader already has |
| **Cognition** | Explanation: why things are the way they are | Reference: facts to look up |

The difference between a tutorial and a how-to guide is study versus work, not
basic versus advanced. The difference between reference and explanation is
whether the reader turns to it while working or while stepping back from the
work.

## The audiences

Kind is one dimension. Audience is the other. A frontend developer requesting
images, an operator running `image_pipe_server`, and an Elixir developer
mounting the Plug need different pages, even about the same feature. Before
writing or reviewing, read `references/audiences.md`. It lists who reads the
docs, what each audience leaves out, and which material is shared between
them.

The house style (page shape, sentences, headings, callouts) is in
`references/style.md`. Before any change to a page, read it and the
reference file for the page's kind:

- `references/tutorial.md`
- `references/how-to.md`
- `references/reference.md`
- `references/explanation.md`

## Workflow

### Writing new docs

1. **Name the audience and their need.** Which audience from
   `references/audiences.md` arrives at this page, what do they already know,
   and what do they want to leave with? Decide what the page will leave out as
   well as what it covers.
2. **Pick the kind** with the compass questions above. If the material needs
   two kinds, write two pages (or one page plus a moduledoc) and link them.
3. **Check where it lives.** Reference material for a module, function, or
   option belongs in `@moduledoc` and `@doc`, next to the code, so it stays
   true when the code changes. Guides link to it instead of copying it.
4. **Verify every claim against the code.** Read the module, run the example,
   request the URL. A plausible sentence that is wrong is worse than no
   sentence.
5. **Draft, then run the boundary check** and the final read below.
6. **Get a fresh review.** Writers miss their own drift, so don't review your
   own draft. Hand the diff to a fresh subagent with the instruction to
   follow `references/review.md`, then fix what it reports. In a tool
   without subagents, re-read `references/review.md` and review the diff as
   a separate pass after drafting.
7. **Close with the summary** from "Every docs change" above.

### Improving existing docs

Work iteratively. Diátaxis is a guide, not a plan, and a big-bang
reorganization leaves the docs broken for weeks.

1. Choose one piece: a page, a section, or a paragraph.
2. Classify each section on its own with the compass questions. A section
   whose answer differs from the page's kind belongs somewhere else.
3. Decide one next action: move, split, cut, rewrite, or link.
4. Do it, following "Every docs change" above, and commit it. Then pick
   the next piece.

A targeted fix stays targeted. If the page has other problems, such as
Elixir side by side with URLs or old punctuation, fix them only where your
change touches the same sentence or table. List the rest in your closing
summary so they can be fixed deliberately, rather than silently left or
silently rewritten.

Never create empty skeleton sections ("Tutorials: coming soon"). Structure
grows from improved content, not the other way round. Not every feature needs
all four kinds. A small option may need only a reference entry and a line in a
how-to guide.

### Boundary check

After drafting, read the page once as its intended reader and look for drift:

- Explanation inside a tutorial or how-to guide: cut it to one clause and link
  to an explanation page.
- An option list inside a guide: keep the options the task needs and link to
  the reference for the rest.
- Instructions inside reference: move them to a how-to guide.
- Technical description inside explanation: move it to reference.
- Material for another audience, such as Elixir configuration on a page for
  server operators: move it to that audience's page and link, or use tabs
  when only the syntax differs.

## Final read

Before finishing any change, do four quick passes over the text you changed.
They check the most important rules in `references/style.md`.

1. Read only the headings, in order. Each should name a topic, and together
   they should read like a sensible table of contents.
2. Read each paragraph as a reader new to ImagePipe. Check that every
   setting, option, and term is explained or linked at its first mention.
   Rewrite sentences with undefined terms, internal vocabulary, mind verbs,
   or abstractions where a concrete example would do.
3. For each paragraph, write the one-sentence version. If it says everything
   the reader needs, replace the paragraph with it. "All copies made from
   `cat.jpg`, at any size or format, expire when the original does" replaces
   three sentences about versions, examples, and guarantees.
4. Search the page for `;` and `—` outside code and rewrite them.

## Project rules

These come from `AGENTS.md` and apply to every doc change in this repo.

- Write for the published Hex release. Installation examples use Hex
  dependencies with the version shown in `docs/installation.md`, never path or
  git dependencies.
- When you remove something, remove it cleanly. Don't leave a note that
  explains or narrates the removal, or says what something no longer is.
  The page should read as if the removed text never existed.
- New guide pages must be added to `@guide_groups` in `image_pipe/mix.exs`,
  or ExDoc won't publish them. Run `mise exec -- mix docs` in `image_pipe/`
  and fix any warnings about broken links or missing references.
- The server docs are extras in `image_pipe`'s ExDoc build. Link between
  `image_pipe/docs/` and `image_pipe_server/docs/` with relative paths, such
  as `../../image_pipe_server/docs/server-configuration.md#cache` and
  `../../image_pipe/docs/telemetry.md`. They work on GitHub and in the
  published docs. ExDoc resolves a `.md` link by its file's basename alone,
  so every guide page needs a basename that is unique across both projects.
  A duplicate makes links to either file silently point at one of them,
  with no `mix docs` warning. That is why the server pages are named
  `server-configuration.md` and `server-deployment.md`. The server's
  `README.md` and `CHANGELOG.md` share basenames with library extras, so
  link them by GitHub URL
  (`https://github.com/hlindset/image_pipe/blob/main/image_pipe_server/README.md`),
  never relatively.
- Telemetry changes update `docs/telemetry-events.md` and `docs/tracing.md`
  alongside the code.
- Transform and URL option changes update the processing pages under
  `docs/processing/`.
- `docs/architecture/api_contract.md` (repo root) is the normative contract
  that the code and tests follow. It isn't published. Change it only when the
  behavior itself changes, not for style, and don't link product docs to it.
- Design notes in `docs/plans/` are working documents, not product docs. This
  skill's style rules apply loosely there.

## Reviewing docs

When asked to review or audit docs, follow `references/review.md`. Report
findings rather than rewriting silently, worst first: the page's intended
audience and kind, material aimed at another audience, sections that drift
from the kind (and where each should go), style problems, and any claim that
disagrees with the code.
