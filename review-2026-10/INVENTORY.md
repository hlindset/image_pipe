# October 2026 review inventory

Every thread in the ImagePipe project as of 2026-10-04 14:20 UTC: what it produced, how far it got, and what waits on Håvard. Branch details are in [BRANCHES.md](BRANCHES.md). Every finding is also filed in Beads under epic `image_plug-e4a` in [review-findings.jsonl](review-findings.jsonl).

## Setup

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Explore ImagePipe repository | PR #671, the cloud SessionStart hook (merged) | Complete | Cloud setup still fails for python, rust, uv and pnpm. `mise-versions.jdx.dev` must be allowed, and GitHub API lookups get rate-limited without a `GITHUB_TOKEN` secret. Alternative: have the hook install only `erlang elixir`. |
| File findings in Beads | `review-findings.jsonl` (master epic `image_plug-e4a`, 9 area epics, 77 issues) | Complete except sync | **Open:** run `bd import -i review-findings.jsonl && bd dolt push` locally, because cloud sessions get a 403 on the Beads push. |

## Feature work

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Implement flat URL config options | `feat/flat-url-config`, 4 commits, local on the Mac in `~/src/image_plug` | gjwo complete, 58ia not started | **Decided:** keep it local, not pushed. `precommit:server` and `precommit:fiddle` passed before the docs commit. **Open:** whether to push it, and when to start image_plug-58ia (removing `config!/1` and `url_config/1`). |

## Bug hunts

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Bug hunt: request handling | `bug-hunt/request-handling.md` (5 bugs) | Complete; fixed in Fix request handling bugs | None. |
| Bug hunt: sources and caching | `bug-hunt/sources-and-caching.md` (5 likely bugs, 3 plausible) | Complete, code reading only | Fixes partly started in Fix sources and caching bugs. |
| Bug hunt: image processing and output | `bug-hunt/image-processing-and-output.md` (13 likely bugs) | Complete, code reading only | Fixes partly done in Fix image processing bugs. |
| Bug hunt: URL builder | `bug-hunt/url-builder.md` | Partial: stopped before checking preset expansion and encrypted watermarks | Signature malleability (fixed on `fix/request-handling-bugs`), plus duplicate cache entries for equivalent values such as `crop=10` and `crop=10.0`. |
| Bug hunt: standalone server | `bug-hunt/standalone-server.md` (7 bugs) | Complete; fixed in Fix standalone server bugs | None. |

## Bug fixes

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Fix request handling bugs | `fix/request-handling-bugs` | Complete: all 5 fixed, precommit passed (15 container-only failures that also fail on main) | **Open:** whether to open a PR, and whether to file the `cache/entry.ex` `^…$` header check as a new Beads issue. |
| Fix standalone server bugs | `claude/fix-server-bugs-tpeoil` (6 commits) | Partial: all 7 fixed, `precommit:server` and docs review not run | **Check:** distribution is now off by default (`remote` needs an opt-in), and HEALTHCHECK runs `bin/image_pipe_server eval` (about 0.3 s) instead of curl. |
| Fix image processing bugs | `claude/project-thread-s2qem3` | Partial: bug 1 (odd-sized region crop) fixed, bugs 2 to 13 not started, full precommit not run | Bugs 2 to 13 are in Beads as `image_plug-e4a.1.*`. |
| Fix sources and caching bugs | `claude/project-thread-xuj4ql` (WIP tests) | Partial: tests for findings 2, 3 and 8 written but not run, no fixes | **Open decision:** stop rotating S3 provider credentials from changing cache keys and ETags (recommended: partition by provider config). |

## Performance reviews

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Performance: request path | `perf-review/request-path.md` | Complete | Follow-up in Speed up request path. |
| Performance: sources and caching | `perf-review/sources-and-caching.md` | Complete, code reading only | Follow-up in Speed up sources and caching. |
| Performance: image processing | `perf-review/image-processing.md` | Complete | Follow-up in Speed up image processing. |
| Performance: standalone server | `perf-review/standalone-server.md` | Complete | Follow-up in Speed up standalone server. |

## Performance fixes

| Thread | Produced | Status | Decisions and open questions |
| --- | --- | --- | --- |
| Speed up request path | Nothing | Not started | All four items still open: skip the double option parse, batch streamed chunks, build cache headers once, parse cookies only when needed. Caveat: on a cache miss the context is re-represented after the source opens (`execution.ex:186`), which limits reusing the first cache headers. |
| Speed up sources and caching | `claude/project-thread-8jzkwh` (8 commits) | Partial: full precommit not finished | **Decided:** size check plus sendfile on cache hits, with no per-hit hash. **Open:** a hit checks the size on the open file but sends by path; docs wording; DNS change unmeasured; S3 credential cache, double write of copied originals and spool buffering skipped. |
| Speed up image processing | `claude/project-thread-6djvq7` (3 commits) | Partial: crop-score reuse, concurrent detectors and the trim design note done; full precommit not run | **Decided:** keep AVIF/WebP effort at 4 and document it (docs note not written). **Open:** the operation-cache A/B was stopped before results, and the trim two-pass design note needs review. |
| Speed up standalone server | Nothing | Not started | **Open decision:** add a default processing pool (recommended). Still to do: jemalloc, highway SIMD, dav1d, libvips threads from the CPU limit, BEAM and Bandit tweaks. |
