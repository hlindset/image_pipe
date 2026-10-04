# Explanation

Explanation gives understanding. It answers "why does it work this way?" and
"how do these pieces fit together?". The reader is stepping back from the
work. Diátaxis's test is that it's the only kind you could read in the bath.

## What explanation contains

- **A question that frames it.** "Why the cache key and the ETag use different
  inputs." "How ImagePipe orders operations." The question keeps the page
  bounded.
- **Context.** Design decisions, constraints, trade-offs, and alternatives
  that were rejected and why.
- **Connections.** How this topic relates to others in ImagePipe, and to
  outside ideas the reader may know (HTTP caching semantics, libvips lazy
  evaluation, imgproxy's URL format).
- **Perspective.** Explanation may hold an opinion: "Deriving the ETag from
  request inputs, not output bytes, is what makes a `304` possible before any
  work."
- **Diagrams or small examples** when they show the mechanism, not to teach
  steps.

## What it leaves out

- Instructions. If a paragraph tells the reader what to type, move it to a
  how-to guide and link.
- Exhaustive technical description. Link to reference for the option list.

## Concrete first

Explanation is where docs most often turn into abstract prose that only
makes sense to someone who already understands the system. Ground every idea
in a specific case before generalizing.

Abstract:

> ImagePipe never tracks a separate lifetime for a processed image. Each
> cached output belongs to a specific version of its original, and the
> original carries the freshness.

Concrete:

> A resized `cat.jpg` has no expiry time of its own. It stays valid as long
> as the original `cat.jpg` it was made from is up to date.

The second version names a real file, uses plain words instead of abstract
nouns, and gets to the point in two sentences. Being concrete doesn't mean
telling a story: avoid setting up a scenario ("Say a request arrives…")
before the rule. Test a paragraph by asking whether a reader
new to ImagePipe could explain it back.

## Effects, not internals

Explain what the reader sees or can rely on, not how the code stores it.
Internal names (records, digests, entries, structs) are a warning sign: the
reader doesn't know them and rarely needs to.

Internal:

> The record of the original holds the origin's response headers and the
> time they arrived. It is stored in the output cache as well as alongside
> the original bytes. The original bytes can therefore be evicted while their
> processed copies keep being served, until the record itself needs checking.

Effect:

> Processed copies can still be served after the original image has been
> evicted from the cache.

Mention a mechanism only when it changes what the reader does: how they size
a cache, configure a source, or debug a surprising response.

## Discursive is not padded

Explanation allows more prose than other kinds, which makes padding easy.
A section that frames the topic ("Freshness answers one question, storage
answers another"), states its facts, then restates the opening at the end
can usually shrink to a third of its length. Keep the reasons that help the
reader predict behavior. Cut the ones that only explain why the docs are
arranged the way they are.

## Language

Discursive and reasoned. "The reason for this is…" "X is similar to Y,
except…" "An alternative would be…, but…". Paragraphs are fine here, more
than in any other kind.

## Signs of drift

- Code blocks the reader is meant to copy into their app
- A list of options with defaults
- Steps numbered 1, 2, 3

## ImagePipe notes

- Titles and section headings should work after "About": "Caching and
  freshness", "Processing order", "Source identity". A heading that makes a
  claim ("Stable sources skip the question") is editorializing. Name the
  topic and make the claim in the text.
- `docs/architecture/api_contract.md` is the normative contract for code and
  tests, not a product page. Explanation pages describe the behavior
  themselves instead of linking readers to it.
- Good examples to follow: `caching-and-freshness.md`,
  `processing-order.md`, and `streaming-failures.md`.
