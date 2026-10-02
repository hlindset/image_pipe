# House style

These rules come from the docs the maintainer admires (Elixir, Phoenix,
SvelteKit) and from reviewing drafts. They apply to every kind unless the
kind's reference file says otherwise. The final-read passes in `SKILL.md`
check the most important of them.

## Page shape

- **Open with the point.** The first sentence says what the reader will be
  able to do (guides) or what the thing is (reference, explanation).
  Prerequisites come right after it.
- **Show, then explain.** Lead with a small, real example, then one or two
  sentences on what to notice. Show the result: response headers, output
  dimensions, the `iex>` return value, or the error the reader will see.
- **Runnable examples.** Real module names, options, and URL syntax. Label
  code that belongs in a file with its path (`# lib/my_app_web/router.ex`).
  Start minimal and grow it.
- **Defer out loud** and link: "Signing is covered in
  [Signing URLs and rotating keys](signing-urls.md)." One pointer can sit in a
  sentence. Two or more parallel pointers go in a short list, each with a few
  words on what the reader finds there.
- **End with a next step** in guides.

## Sentences

**Say only what the reader needs.**

- Lead with the fact, then stop. Cut sentences that frame the topic,
  announce what's coming, restate an earlier paragraph, or justify how the
  docs are organized. End a sentence once its point is made: "The resized
  copy is served from the cache" needs no ", with no fetch, decode, or
  encode".
- Ask whether the reader would be surprised if the sentence were missing.
  Expected behavior needs no sentence (`no-cache` means revalidate).
  Standards the audience already knows (HTTP caching, `Accept` negotiation,
  Plug pipelines) get a link, not a re-explanation or worked arithmetic.
  Document where ImagePipe makes its own choice, plainly: "If the origin
  sends no lifetime, ImagePipe revalidates with the origin on every request,
  unless you configure a fallback lifetime."
- Don't argue with imaginary readers. Say what happens instead of refuting
  an expectation nobody holds ("Serving a cached copy never moves the expiry
  later"), and skip comparisons with other tools unless readers really
  expect that behavior.
- Debugging-only edge cases go in reference or a troubleshooting note, not
  in explanation.

**Use the reader's words.**

- Define a term in plain words at its first use, and never refer to a
  setting or concept the page hasn't introduced or linked.
- Vocabulary from the code and `AGENTS.md` ("mount", "representation",
  "plan", "seed", "record", "digest") is not the reader's. Describe the
  effect the reader sees instead of the mechanism behind it: "Processed
  copies can still be served after the original has been evicted", not a
  paragraph about where records are stored.
- When a page serves several audiences, describe a setting in plain words
  ("allow storage for that source") and link to where each surface
  configures it. Never invent a neutral name ("the storage override").
- Describe the property, not the option value, when the value's name would
  mislead: "a source that isn't trusted" sounds like a security warning for
  a setting that only says whether files change. When the value already
  names the property, use it, so the reader doesn't have to translate. A
  source with `stable: :immutable` is an "immutable source", not a
  "write-once" one.

**Write plainly and directly.**

- Put a concrete case inside the sentence that states the rule, without
  staging a scenario first: "A resized `cat.jpg` has no expiry time of its
  own. It stays valid as long as the original `cat.jpg` is up to date."
- Name the part that acts (the cache, the server, the source adapter) rather
  than "ImagePipe" every time, with plain verbs: "checks" not "asks", "has"
  not "knows", "uses" not "decides", "needs" not "wants".
- Don't chain conditions that lean on "it" ("If it hasn't…. If it has…").
  Repeat the noun, and put branching outcomes in a list, one per item, each
  naming its subject.
- Short sentences, active voice. "You" in how-to guides and reference, "we"
  in tutorials. No marketing language.
- Avoid semicolons and em-dashes. A period, a comma, or a new sentence
  almost always reads better.

## Headings

Headings label the topic. The claim goes in the text below. ExDoc's sidebar
lists every page title and its `##` headings, so write them for scanning:

- Short (about 30 characters), with the distinguishing word first.
- Complete, not clipped. Drop the product name when it adds nothing
  ("Caching", not "ImagePipe caching"), but never cut a title into a
  fragment ("Using with a CDN"). Naming the reader's goal often gives a title
  that is both short and complete. If the page needs a longer title, set a
  sidebar label in the extras config: `{"docs/cdn.md", title: "…"}`.
- Specific and unique across the site. No "Overview", "How it works",
  "Details", or "Options" sections that look identical in search.
- `##` headings on a page share one form and carry no "Step 1:" numbering.
- How-to titles name the goal with a gerund, as Phoenix does ("Serving
  images through a CDN"), and hold for every audience the page serves. Their
  step headings may be short imperatives ("Turn on cache headers").
- Reference headings use the names the code uses.

| Avoid | Prefer | Why |
| --- | --- | --- |
| A processed image is as fresh as its original | Processed images and their originals | A label, not a claim |
| Where freshness comes from | Cache lifetime from origin headers | Name the concrete subject |
| Fresh, stale, or needs validation | Cache states for originals | Name the category, not its members |
| Choices ImagePipe makes on purpose | How origin headers are interpreted | Say what the section contains |

## Callouts

Use an ExDoc admonition only for a genuine gotcha:

```markdown
> #### Detection needs a Rust toolchain {: .warning}
>
> `ortex` compiles a native NIF, so `cargo` must be on the build machine.
```
