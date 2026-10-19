# Performance review 4: request path

Scope: the Plug request lifecycle from parse through delivery, as a warm request sees it: parse, source resolve and revalidation, source-record and output cache reads, representation, the conditional gate, and the response. Reviewed at `main` 8edf03b. No code was changed. Paths are relative to `image_pipe/lib/image_pipe/`.

## How this was measured

Everything ran against the real code in this container (Elixir 1.20.4, OTP 29, 4 vCPU Firecracker VM, shared).

- **Setup.** One `ImagePipe` instance with a bounded output cache and an input cache, HEAD/GET requests for `/w=300/format=webp/src/imageN.jpg` (32 KB WebP from `priv/static/images/waterfall.jpg`) through `ImagePipe.Plug.call/2`. Three source setups:
  - **file:** `ImagePipe.Source.File` with default options (`verify: :stat`).
  - **http_fresh:** `ImagePipe.Source.HTTP` against a local Bandit origin sending `Cache-Control: public, max-age=3600` and an ETag.
  - **http_nocache:** the same origin sending `Cache-Control: no-cache`, so every request revalidates.
- **VM flags.** Unless a table says otherwise, the BEAM ran with the server release's flags, `+sbwt none +sbwtdcpu none +sbwtdio none` (`image_pipe_server/rel/vm.args.eex`).
- **CPU per request** is whole-VM CPU (`:erlang.statistics(:runtime)`), the median of 7 interleaved rounds of 2,000 requests. **Throughput** is 4,000 HEAD requests across 8 tasks, for one source or spread over 8.
- **What-if patches** were applied behind a `:persistent_term` flag, measured interleaved with the baseline in the same VM, and reverted. They bound what a fix can win; they are not the fix.
- **Counts and callers** come from `tprof` and Erlang call tracing with `caller_line`.

### Baseline on main

| file source | CPU | wall |
|---|---|---|
| warm HEAD hit | 510–610 µs | 650–795 µs |
| warm GET hit | 690–860 µs | 910–1,080 µs |
| 304 for a matching `If-None-Match` | 360–415 µs | 440–540 µs |

| source | warm HEAD CPU | 304 CPU | 8 tasks, 1 source | 8 tasks, 8 sources |
|---|---|---|---|---|
| file | 510–610 µs | 360–415 µs | 3,750–4,800 req/s | 4,000–4,700 req/s |
| http_fresh | 486–542 µs | 317–372 µs | 5,400–6,500 req/s | 6,000–6,600 req/s |
| http_nocache | 1,416–1,565 µs | 1,222–1,251 µs | 2,800–3,100 req/s | about 1,980 req/s |

Pass 3 measured 710–810 µs CPU per file-source HEAD hit and 1,500 req/s for one hot source, so the request path is about 25% cheaper and the single-source ceiling is gone. (The http_nocache single-source row is higher than eight sources because concurrent revalidations of one source now share one conditional request.)

Stage durations for a warm file-source HEAD hit (wall, from telemetry):

| stage | µs |
|---|---|
| parse | 42 |
| source resolve | 45 |
| source fetch (revalidates the file) | 122 |
| cache lookups (source record + output entry) | 2 × 51 |
| send | 32 |
| **request** | **636** |

A warm file-source HEAD hit makes 10 file calls that run on dirty I/O schedulers: 2 `read_link` (the source path check in resolve and again in fetch), 1 `stat`, an `open` and `close` of the source file, 2 metadata `read_file`s, and an `open`, `fstat` and `close` of the cached body. A GET adds the adapter's own `open`/`sendfile`/`close`. That count drives findings 1–3.

## Findings, ranked by payoff against risk

### 1. The file source opens and closes the original on every revalidation, even when its stat hasn't changed

- **Severity:** Medium–High. Measured.
- **Where:** `source/file.ex:136-150` (`fetch/3`), with `readable/1` at `source/file.ex:220-225`.
- **Evidence:**
  - `fetch/3` runs `readable(path)` (an `:file.open` and `:file.close`) before it compares the stat evidence with the previous record. A warm hit or a 304 always ends in the `unchanged?` branch, which returns `{:not_modified, …}` and never reads the bytes. The open only matters when the response is `{:ok, %Response{}}`, because the bytes are read later, during staging (the comment at lines 217-219 says so).
  - The open and close cost **36 µs** in a micro-benchmark with busy-waiting on and **55–63 µs** with the shipped flags, about a tenth of a warm hit.
  - What-if patch: run `readable/1` only in the branch that returns `{:ok, %Response{}}`.

    | | baseline | patched |
    |---|---|---|
    | 304 CPU (median) | 412 µs | **321 µs (−22%)** |
    | 304 wall (median) | 542 µs | **380 µs (−30%)** |
    | HEAD hit CPU (two runs) | 566 / 610 µs | 543 / 544 µs (−4% to −11%) |
    | 8 tasks, 1 source | 3,750–4,800 req/s | **4,780–5,430 req/s (about +20%)** |
    | 8 tasks, 8 sources | 4,000–4,650 req/s | 4,790–5,400 req/s (about +18%) |
- **Why it's safe:** a file that becomes unreadable through `chmod` changes its ctime, so its stat evidence changes, `unchanged?` is false, and the open still runs. An unsearchable parent directory already fails at the `stat` (`regular_file/1`), which the test "fetch reports an unsearchable parent directory as unreadable" (`test/image_pipe/source/file_test.exs:130`) pins. Files with no stat evidence (`verify: :hash`, or touched this second) never match `unchanged?`, so they keep the open too.
- **Suggested fix:** move `readable(path)` after the `unchanged?` check, into the branch that returns `{:ok, %Response{path: path, origin: evidence}}`. Write the test first: a file whose stat is unchanged returns `{:not_modified, _}` without an open (for example, by checking that an unchanged file returns `:not_modified` after its read permission is removed with the ctime restored, or by counting opens in a trace).
- **Not recommended:** the same patch also measured skipping the second path check in `fetch/3`, which won about as much again. That was decided against in `image_plug-e4a.15.11` (the fetch-time recheck guards a symlink swapped in between resolve and fetch), so it isn't proposed here.

### 2. With `+sbwtdio none`, each file call on a warm hit waits for a sleeping dirty I/O scheduler

- **Severity:** Medium. Measured; needs Håvard's decision.
- **Where:** `image_pipe_server/rel/vm.args.eex:6-8`, added for `image_plug-e4a.9.7` (PR #854), which measured the processing families under `--cpus 2`.
- **Evidence:**
  - Every file call above runs on a dirty I/O scheduler. When those schedulers sleep instead of spinning, each call pays a wake-up. In a micro-benchmark a raw `stat` cost **5 µs** with busy-waiting and **33–36 µs** with `+sbwtdio none`. The same `SafePath.relative` check cost 6 µs and 35 µs.
  - Same warm loop, only `+sbwtdio` changed (`+sbwt none +sbwtdcpu none` kept), two runs each:

    | `+sbwtdio` | HEAD CPU | HEAD wall | 304 CPU | 304 wall |
    |---|---|---|---|---|
    | `none` (shipped) | 573–579 µs | 719–747 µs | 376–404 µs | 493–496 µs |
    | `very_short` | 824–882 µs | **535–565 µs** | 510–529 µs | **360–380 µs** |
    | `short` | 903–951 µs | 520–555 µs | 577–631 µs | 368–413 µs |

    Sequentially, spinning cuts wall time by 25–30% and costs about 45% more CPU per request, all of it spinning.
  - Under load the spinning pays for itself here. 8 tasks, file source, three rounds each:

    | `+sbwtdio` | 1 source | 8 sources |
    |---|---|---|
    | `none` | 3,917–4,287 req/s | 4,090–4,527 req/s |
    | `very_short` | **5,574–6,833 req/s** | **5,630–6,204 req/s** |

    That is about +45% warm-hit throughput on 4 unthrottled vCPUs.
- **Open question for Håvard:** the flags were adopted for processing load, where spinning takes CPU from libvips and from a CFS quota. Warm hits and 304s, which a CDN-fronted deployment serves most of, gain from dirty I/O spinning instead. Only `+sbwtdio` matters for this, because libvips work runs on its own threads and dirty CPU work isn't involved in a warm hit. Is it worth a perf-labelled PR that tries `+sbwtdio very_short` with the other two flags kept at `none`? Two things to check there:
  - whether the perf workflow has a warm-hit or 304 family at all. The numbers above suggest one is needed to judge this flag.
  - behaviour under a CPU quota (Bunny Magic Containers), where spinning counts against the limit. These numbers are from an unthrottled VM.
- **Suggested fix:** whatever the flag decision, fewer file calls per warm hit pays twice under `+sbwtdio none`, which makes findings 1 and 3 worth more than their CPU share suggests.

### 3. A cache hit opens, checks and closes the body even for HEAD, and a GET opens it twice

- **Severity:** Low. Inferred from the per-call costs above; not measured end to end.
- **Where:** `cache/file_system/store.ex:386-392` (`read_entry` opens the body through `ImagePipe.Cache.File.open/2`, `cache/file.ex:13-31`, which also runs `read_file_info` on the descriptor); `response/sender.ex:132-134` (HEAD uses only `file.size`) and `:139-140` (GET calls `send_file` with the path, so the adapter opens the body again).
- **Evidence:**
  - Per hit: `open`, `fstat` and `close` of the body. With the shipped flags each costs about the same as the `stat` above (30–35 µs wall), so about 100 µs of wall time per hit.
  - For HEAD, the open does nothing the metadata doesn't already give. The metadata carries `body_byte_size`, and `send_body/2` for HEAD sends only that.
  - For GET, the open descriptor is the fallback that `image_plug-e4a.3.17` added for a body evicted between the open and `send_file`. That trade-off is deliberate, so this finding doesn't propose removing it for GET.
- **Suggested fix:** for HEAD, return a hit without opening the body. A body deleted underneath would then still answer HEAD with 200 and the stored length, which seems acceptable, since the next GET finds the miss. **Question for Håvard:** is that acceptable, or should HEAD keep proving that the body exists? A single `stat` by path (1 call instead of 3) would keep the size check.

### 4. Every output hit decodes the stored debug info, which is about half the metadata

- **Severity:** Low. Measured in isolation.
- **Where:** `cache/file_system/store.ex:474-524` (`read_metadata` → `safe_term`), with the metadata written at `:488-498`.
- **Evidence:**
  - An output entry's metadata is about 1.3–1.4 KB and holds a `%ImagePipe.Debug.Info{}` with 23 fields. `:erlang.binary_to_term(bin, [:safe])` takes **16–19 µs** per hit for it. The same metadata without `:debug` decodes in 7–9 µs, because most of the cost is the atoms (map keys and struct names) the decoder has to look up.
  - The debug info is only rendered when `debug?` is on (`response/sender.ex:83-95`: `hit_debug_headers` returns `[]` otherwise). `allow_debug_headers` defaults to `false`.
- **Suggested fix:** store the debug info as its own `term_to_binary` blob inside the metadata and decode it only in `hit_debug_headers` when it will be rendered. That saves about 8–10 µs per output hit. Changing the stored shape would make existing entries miss, so per the cache guidelines it needs a `Changed` changelog entry and no version bump. Bundle it with other metadata work only; it isn't worth a change by itself.

### 5. Per-request telemetry setup scans the handler table and recompiles a regex

- **Severity:** Low. Measured in isolation.
- **Where:**
  - `telemetry/summary.ex:55`. `Summary.open/2` calls `:telemetry.list_handlers(prefix ++ [:request, :summary])` at every request start. `list_handlers/1` runs `:ets.match_object` over the whole handler table, not a lookup by event name.
  - `telemetry.ex:304-305`. `redact_path/1` runs an inline `~r{\A(.*?/)(src|src64|enc)/(.*)\z}s` for the `[:request]` start metadata on every request. Under OTP 28+ an inline regex is re-imported on each call.
- **Evidence:**
  - `list_handlers` takes 2.7 µs with nothing attached, **5.2 µs with the default Logger and the tracer attached** (133 handler rows), and 14 µs with 300 more handlers. `:telemetry_handler_table.list_for_event/1` answers the same question in 0.6 µs, but it is internal API.
  - `Telemetry.request_path/2` takes 4.5 µs for `/w=300/format=webp/src/image0.jpg` and 10–12 µs for a path with an `http` source URL. The regex re-import is about 2.4 µs of that. Pass 3 #5 removed the other hot-path regexes, and this one is left.
- **Suggested fix:**
  - Replace the regex with a binary scan for the first `/src/`, `/src64/` or `/enc/` segment.
  - For the summary, ImagePipe can't cache the answer, because hosts attach their own handlers and `:telemetry` has no attach notification. The options are to accept the 5 µs, or to always collect the summary fields (a few `Process.put`s) and drop the check. Bundle this only with other telemetry work.

## Fixed or decided since pass 3 (verified on main)

- **#1, the `Work` lock on a hot source:** fixed (`image_plug-e4a.15.10`, PR #754). One source now reaches the same throughput as eight, and the trace shows no `Cache.Work` calls on a warm hit.
- **#2, file-server calls through `Path.safe_relative/2`:** fixed (`image_plug-e4a.15.11`). `ImagePipe.SafePath` uses `:prim_file.read_link/1`, and cache partition checks are memoized. Tracing shows no `file_server_2` calls on a warm hit. The fetch-time recheck stays by decision (see finding 1).
- **#3, two Admission hit casts:** closed as not worth it (`image_plug-e4a.15.12`). Still 2 casts per hit, as expected.
- **#4, `Record.state/2` recomputed:** per-call cost fixed in #777. The call count is still 3 per warm hit and 9 per no-cache revalidation (each with 2 `HTTPDate` parses), closed as not worth carrying state through acquisition (`image_plug-e4a.15.13`). At about 4 µs a call it's about 35 µs of a 1.4 ms revalidating request, so it doesn't change that call.
- **#5, recompiled regexes:** fixed except `Telemetry.redact_path/1` (finding 5).
- **#6, `OptionSpec.fetch/1` linear search:** fixed (`image_plug-e4a.15.18`).
- **#7, `telemetry_opts/1` with `Keyword.take`:** dropped as inside noise (`image_plug-e4a.7.5`). Re-measured here at 0.46 µs a call, 9–14 calls a request; a `:lists.keyfind` what-if moved HEAD CPU by −4%, inside noise again. Not re-raised.

## Checked and fine

- **No singleton calls on a warm hit.** The only messages a warm HEAD hit sends are the 2 Admission hit casts and the response. No `Cache.Work`, `file_server_2` or GenServer calls.
- **http_fresh hits** do no source I/O at all: the source record's freshness answers, and the origin saw 8 requests in 30,000.
- **http_nocache revalidation** costs about 0.9 ms more CPU than a fresh hit. Most of that is Req/Mint and the origin itself (it ran in the same VM). ImagePipe's own share is small: about 9 `CacheState.from_headers` builds and 8 `MaterialDigest` hashes.
- **`Source.valid_resolved?/1`** re-validates the adapter's cache policy with NimbleOptions on every resolve. That is the documented boundary check on adapter return values, and it costs 0.3 µs for the default policy.
- **Plug config resolve** (`Keyword.merge` of the mount and instance options, 46 keys) costs 3 µs per request.
- **Representation** builds the cache key, ETag and the input-cache key from one canonical form each, 5–8 `term_to_binary` calls of about 4–5 µs. The input key is needed on a hit, because the source record is indexed by it.

## Suggested order

1. **#1 (open the original only when its stat changed).** A one-branch move with a test, about +20% warm-hit throughput and −22% CPU on file-source 304s.
2. **#2 (the `+sbwtdio` question).** Håvard decides; the perf workflow would need a warm-hit or 304 case to judge it.
3. **#3 (skip the body open for HEAD)** if Håvard accepts the HEAD semantics.
4. **#4 and #5** only alongside other work in those files.
