# Bug hunt 7: standalone server (image_pipe_server)

Date: 2026-10-21. Scope: `image_pipe_server/` on `main` at `6a87579`: the
router (including the new `401`/`404` request lines), health, auth, the
stats endpoints and the new background `df` reader (`Stats.Disk`), config
loading, the log handler's overload settings (`4084998`), `rel/`, the
Dockerfile, and the server docs. Deduped against `bug-hunt/` through
`bug-hunt-6/` and the memory hunt report.

How this was checked: the server ran locally with `mix run --no-halt` and a
TOML file per case (Bandit 1.13.1, OTP 29.1.1, Elixir 1.20.4, libvips 8.18.7
built as in CI), with `curl`, raw sockets from Python for malformed
requests, and a small Python load generator (keep-alive connections asking
for one cached image). The machine has 4 CPUs. The server's own tests pass
(200 passed, 1 skipped). No Docker image was built.

## Bug hunt 6 findings: all four fixed on main

| Hunt 6 finding | Fixed by |
| --- | --- |
| 1. Overlapping scrapes get no disk sizes; a `df` over 2 s never reports | `dc93d4c`: `Stats.Disk` runs `df` every 15 s in the background and keeps the last good sizes with `disk_age_seconds` |
| 2. A busy or restarting admission process drops its cache from `/stats` and `/metrics` after 5 s | `f56d02c`: the cache stays listed with `available: false` after a 1 s wait, plus an `image_pipe_cache_available` gauge |
| 3. Guides say `output`'s `entries` counts originals | `0a22b4c` (checked: the sentence is gone from both guides) |
| 4. The router's own `401`/`404` leave no log line, and the logged path drops `mount_path` | `f1586ca` (checked: both lines appear, in text and JSON formats, and the library's line starts with `/img/...`) |

---

## 1. Low-medium: malformed requests log at `error`, from any client, and can quote a bearer token

- **Files:** `image_pipe_server/lib/image_pipe_server/application.ex:203-220`
  (`http_child/2` sets `http_options: [compress: false]` only) and
  `:181-195` (`health_child/2`, no `http_options`);
  `deps/bandit/lib/bandit/logger.ex:11-35` (`log_protocol_errors`
  defaults to `:short`, logged with `Logger.error/2`)
- **Status:** reproduced.
- **Evidence:** Bandit logs every HTTP protocol error at `error`, before the
  router runs, so the line has no `request_id`, doesn't follow
  `log_requests = false`, and stays at `log_level = "error"`. Requests sent
  with raw sockets, each answered by Bandit with a `4xx`:

  ```text
  request line with a control byte  -> 400
  [error] ** (Bandit.HTTPError) Request line contains invalid characters (RFC9112§3.2)
  20,000-byte path                  -> 414
  [error] ** (Bandit.HTTPError) Request URI is too long
  headers not finished in 10 s      -> 408
  [error] ** (Bandit.HTTPError) Read timeout
  "Bad Header: y"                   -> 400
  [error] ** (Bandit.HTTPError) Header read HTTP error: "Bad Header: y\r\n"
  "Authorization : Bearer secret"   -> 400
  [error] ** (Bandit.HTTPError) Header read HTTP error: "Authorization : Bearer secret\r\n"
  ```

  With `log_format = "json"` the last one is
  `{"message":"** (Bandit.HTTPError) Header read HTTP error: \"Authorization : Bearer secret\\r\\n\"","metadata":{},"severity":"error"}`.

  Three problems:
  - The docs say a `4xx` logs at `warning` and `error` is for `5xx`
    (`docs/server-deployment.md`, Logging). These are client mistakes, and
    any scanner or slow client on the internet can produce them, so an
    alert on `error` lines fires on traffic the server handled correctly.
    The slow-headers case (`408`) also comes from real clients on bad
    networks.
  - A malformed header line is quoted whole. A client or edge that writes
    `Authorization : Bearer <token>` (or any malformed line holding a
    credential) puts the `[server] auth_token` or `[stats] token` in the
    log. The telemetry guidelines keep tokens out of logs.
  - The lines carry no `request_id`, method, or path, so they can't be tied
    to a request or a CDN log.
  Idle keep-alive connections and connections that send nothing log
  nothing (checked), so this is only malformed or stalled requests. A plain
  HTTP connection that receives TLS logs at `warning`
  (`Connection that looks like TLS received on a clear channel`), which is
  fine.
- **Open question for Håvard:** Do you want these lines at all? If yes, at
  `warning` like the library's `4xx` lines, without the raw header?
- **Suggested fix:** Set `log_protocol_errors: false` in `http_options` for
  both listeners (Bandit's Phoenix adapter does the same). If a trace is
  wanted, attach to Bandit's `[:bandit, :request, :stop]` telemetry event,
  which carries `error` and a status, and log a short `warning` line with
  the status and the error kind only. Add a router test that sends a
  malformed header with a token and asserts the token isn't logged.

## 2. Low (docs): the log's overload behavior isn't what the Logging section describes

- **Files:** `image_pipe_server/docs/server-deployment.md` (Logging: "The
  server writes about 1,000 lines a second, and fewer when the log collector
  reads the container's output slowly", and the two-line `notice` example);
  `image_pipe_server/config/config.exs:242-253`;
  OTP `kernel/src/logger_olp.erl` (`check_load/1`,
  `maybe_notify_mode_change/3`)
- **Status:** reproduced on the server and with a standalone script using
  the same handler options.
- **Evidence:** `drop_mode_qlen: 1000` is a queue length, not a rate.
  - With spare CPU, the server keeps every line well above 1,000 a second.
    Writing straight to a file: 2 load processes, 12,772 requests in 10 s,
    12,772 request lines; 4 processes, 18,028 requests (1,800 a second),
    18,028 lines, no drops.
  - When the CPUs are saturated, the handler process gets too little time
    and keeps far fewer. 16 load processes on 4 CPUs: 23,059 requests in
    10 s (2,300 a second), 4,973 request lines (about 450 a second, 22%),
    still writing to a plain file, so the collector wasn't the limit.
  - Drop mode doesn't start once and stop once. `sync_mode_qlen` equal to
    `drop_mode_qlen` leaves no gap between the two thresholds: the handler
    leaves drop mode as soon as one queued line is written (queue 999), the
    next burst puts it back, and OTP writes a `notice` for each change. That
    run logged 66 notices in 10 s, alternating every 50 to 300 ms:

    ```text
    12:23:24.101 [notice] Handler :default switched from :async to :drop mode
    12:23:24.199 [notice] Handler :default switched from :drop to :async mode
    12:23:24.252 [notice] Handler :default switched from :async to :drop mode
    12:23:24.522 [notice] Handler :default switched from :drop to :async mode
    ```

    A standalone script (64 processes logging 250-byte lines, same handler
    options, stdout to an unthrottled reader) logged 2,202 notices in 8 s.
    The guide's example also spells them `Handler default switched from
    async to drop mode`, without the colons the real lines have, so a log
    query copied from the guide finds nothing.
  Nothing here is lost that the guide doesn't already warn about (it says
  the request log can miss lines), but the rate it gives is wrong in both
  directions, and someone counting the notices to measure drops gets
  hundreds of pairs, not one.
- **Suggested fix:** In the guide, say the server keeps up to 1,000 queued
  lines and drops new ones beyond that, which happens when the collector is
  slow or the CPUs are saturated; say the `notice` lines repeat while it's
  overloaded; copy the notice text from a real run. Optionally leave a gap
  so the mode doesn't flap (for example `sync_mode_qlen: 1000`,
  `drop_mode_qlen: 2000`, which brings back sync mode between them, the
  trade `4084998` made on purpose), or accept the flapping and only fix
  the text.

## 3. Low: a `mount_path` with a space or non-ASCII character starts fine and then 404s every request

- **Files:** `image_pipe_server/lib/image_pipe_server/config.ex:430-437`
  (`mount_path!/1` checks only the leading `/`);
  `image_pipe_server/lib/image_pipe_server/router.ex:45,94-99,157-159`
  (the mount is split from the configured string and compared with the raw,
  still percent-encoded `path_info`)
- **Status:** reproduced.
- **Evidence:** With `mount_path = "/my images"` the server boots and
  reports ready. `GET /my%20images/w=40/src/pic.jpg` answers `404` and logs
  `GET /my%20images/w=40/src/REDACTED 404 2ms`; a client can't send the
  unencoded space at all. The same applies to `"/bilder/æ"` or any segment
  with `%`, `?`, or `#`. Nothing at boot hints that the mount can never
  match.
- **Suggested fix:** Either reject at boot a `mount_path` whose segments
  hold anything but unreserved characters and sub-delims (the error names
  the setting), or percent-encode the configured segments before comparing
  (and document that the setting is the decoded path). Rejecting is
  simpler and matches what operators use.

---

## Checked and found sound

- **`Stats.Disk`.** One `df` per root at a time, the last good sizes kept
  with their age, a failed or unreadable `df` keeps the old sizes, roots
  shared by both caches read once. A `DOWN` from an unknown process can't
  happen (only `start_df/2` monitors). `/stats` and `/metrics` answered with
  disk sizes and `disk_age_seconds` on both listeners.
- **`available: false`.** The unavailable cache keeps `hits`, `misses`, and
  `read_errors`, so the counter rendering in `prometheus/1` never hits a
  missing key.
- **Router request lines.** `401` at `warning` and `404` at `info`, with the
  request ID, in text and JSON; under a mount the path is cut only after
  the mount (a mount segment named `enc` isn't taken for a source); empty
  segments (`/img//w=40/...`) are handled the same as in the library.
  Health and stats requests log nothing.
- **Config conversion.** `max_blur_work` and `max_search_pixels` accept
  `"infinity"` from the file and the environment; `pool_size` passes
  through for HTTP and S3 sources; `0` for a `pos_integer` reaches the
  library's validator, which rejects it with the setting's name.
- **Log handler options** survive `runtime.exs` with every `log_format`
  (`log_handler_test.exs`), and the mode-change `notice` lines are written
  by the handler itself, so they appear at any `log_level` as the guide
  says.
- **Not reported, other areas:** the query of a path outside the mount is
  logged with only the library's credential parameter list redacted
  (`?token=abc` stays), which is the library's telemetry design; the
  remembered-originals memory (up to about 1 GB at the 1,000,000 cap) is
  documented in the library and server guides.
