# Reviewing a docs change

You are reviewing a documentation change with fresh eyes. You did not write
it. Read `SKILL.md`, `references/style.md`, and `references/audiences.md`
first, then the reference file for the page's kind. Review only the changed
text and anything it now contradicts. Report problems. Don't rewrite the page yourself.

## What to check

**Audience and kind**

- Which audience and which kind is the changed text for? Does it stay there?
- Material for another audience (Elixir on a page for image consumers or
  server operators, configuration on a URL reference page)?
- URL examples shown with Elixir side by side instead of in tabs (URL first)?
  Elixir spellings in prose on a page for non-Elixir readers?

**Drift between kinds**

- Explanation inside a how-to or tutorial, instructions inside reference,
  option lists inside a guide, technical detail inside explanation.

**Sentences**

- Framing, announcing, restating, or sentences about the page itself.
- Sentences the reader wouldn't miss: expected behavior, re-explained
  standards, arguments with imaginary readers.
- Internal vocabulary ("mount", "record", "digest", "seed") or invented names
  for settings. Terms or settings used before they are explained or linked.
- Option values used as adjectives ("isn't trusted").
- Mind verbs ("asks", "knows", "decides") and chains of "it".
- Paragraphs that a single sentence could replace.
- Semicolons and em-dashes outside code, including ones already in a
  sentence the change touched.

**Headings**

- Claims, vague labels, lists of members, missing goal in how-to titles,
  clipped fragments, more than about 30 characters.

**Facts and project rules**

- Pick the claims most likely to be wrong and check them against the code.
- New pages added to `@guide_groups`, links that resolve, Hex dependencies,
  `api_contract.md` changed only when behavior or a wrong statement demands it.

**Code problems**

- Anything in the code that looks like a bug or an awkward API, found while
  checking facts. List these separately so the author can file them.

## Report format

List findings worst first. For each: the quoted text, the rule it breaks, and
a suggested fix in one line. End with problems on the page that the change
didn't touch, as a separate short list, so the author can decide whether they
are in scope. If you find nothing, say so.
