# Branches from the October 2026 review threads

All are on `origin`, none has a PR. Fetch them with:

```
git fetch origin fix/request-handling-bugs claude/fix-server-bugs-tpeoil claude/project-thread-s2qem3 claude/project-thread-6djvq7 claude/project-thread-8jzkwh claude/project-thread-xuj4ql
```

| Branch | Thread | What it holds |
| --- | --- | --- |
| `fix/request-handling-bugs` | Fix request handling bugs | All 5 request-handling bugs fixed test-first: preset trailing newline, signature malleability, `wm-enc` preset without keys, `Vary` on late errors, `q=0.` parsing. Precommit gate passed except 15 container-only failures that also fail on main. |
| `claude/fix-server-bugs-tpeoil` | Fix standalone server bugs | All 7 standalone-server bugs fixed in 6 commits: Erlang distribution off by default, Docker health check against the configured listener, env conversions that failed open, and the rest. `precommit:server` not run. |
| `claude/project-thread-s2qem3` | Fix image processing bugs | Bug 1 only: exact origins for odd-sized region crops. Bugs 2 to 13 untouched. Full precommit not run. |
| `claude/project-thread-6djvq7` | Speed up image processing | Crop-score tile references built once per quality search (17-23% faster), concurrent face and object detection, and the trim shrink-on-load design note. Full precommit not run. |
| `claude/project-thread-8jzkwh` | Speed up sources and caching | 8 commits: indexed admission lookups, no rewrite of unchanged source records, sendfile with size-only check on cache hits, cache options validated once, Finch pools started once, parallel IPv4/IPv6 DNS, raw open for readability check, docs. Partial: full precommit not finished, a hit checks size on the open file but sends by path, docs wording needs a fix, DNS change unmeasured. |
| `claude/project-thread-xuj4ql` | Fix sources and caching bugs | One WIP commit with reproducing tests for findings 2, 3 and 8. Tests not run, no fixes. |
| `claude/project-thread-wf1l3z` | Explore ImagePipe repository | Cloud SessionStart hook, already merged as PR #671. |

Not on GitHub: `feat/flat-url-config` (image_plug-gjwo) is a local branch in `~/src/image_plug` on Håvard's Mac.

The Speed up request path and Speed up standalone server threads made no code changes.
