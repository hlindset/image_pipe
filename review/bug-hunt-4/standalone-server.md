# Bug hunt 4: standalone server (image_pipe_server)

Date: 2026-10-13. Scope: `image_pipe_server/` on `main` at `db4fe3c` (0.2.0): the
listener and router, health and shutdown, config loading (TOML, `IPS_`
variables, `IPS_CONFIG_TOML`), `rel/env.sh.eex`, `rel/vm.args.eex`, the
Dockerfile, and the server docs.

Deduped against `bug-hunt/`, `bug-hunt-2/`, `bug-hunt-3/standalone-server.md`,
`perf-review*/standalone-server.md`, `memory-leak-hunt/report.md`, and the
pushed beads. The `/tmp`-is-RAM issue on gVisor is in the memory hunt
(finding 1) and isn't repeated here.

How this was checked:

- Reproductions ran against the real `ImagePipeServer.Application.http_child/2`
  and `Config.load!/2` (Bandit 1.12.5, ThousandIsland 1.5.0, OTP 29,
  Elixir 1.20.4). The scripts are summarized in each finding.
- A fuzz run of 4,000 malformed TOML files through `Tree.read!/2` found no
  crash and no leaked value. A run of 14 odd values through every
  `server`, `url`, `processing`, `pool`, `http`, and `telemetry` setting
  found no crash.
- Every `toml` block in the server and library docs loads, apart from
  intentional fragments and `…` placeholders.
- The getting-started guide's request and error examples match the router's
  responses.

No Docker image was built: the proxy blocks the Debian mirrors.

---

## 1. Medium: new connections are closed far below `max_connections`

- **File:** `image_pipe_server/lib/image_pipe_server/application.ex:130-154`
  (`http_child/2`)
- **Status:** reproduced.
- **Evidence:** The cap is split over up to 100 acceptors as
  `num_connections = ceil(max_connections / acceptors)` per acceptor.
  ThousandIsland accepts a socket first and only then checks its own
  acceptor's supervisor
  (`deps/thousand_island/lib/thousand_island/acceptor.ex:34-41`,
  `connection.ex:56-93`). If that acceptor is full, it sleeps 1 s, retries
  5 times, and then closes the socket, even when every other acceptor has
  room. Acceptors take turns on the listen socket, so a new connection lands
  on a full acceptor whenever the open connections aren't spread evenly.
  Long-lived keep-alive connections from a CDN or proxy make that the normal
  case.

  Sequential `connection: close` requests while some idle keep-alive
  connections stay open:

  | `max_connections` | Per acceptor | Idle connections held | New connections closed after 5 s |
  |---|---|---|---|
  | 4 | 1 | 1 (25% of cap) | 3 of 12 (every 4th) |
  | 200 | 2 | 110 (55%) | 0 of 12 |
  | 200 | 2 | 150 (75%) | 12 of 100 |

  At `max_connections = 4` with one idle connection, every fourth new
  connection waited 5,005 ms and then got `{:error, :closed}`. The
  deployment guide says new connections wait for room only "beyond"
  `max_connections` (`docs/server-deployment.md:102-103`). At the default of
  2048 (21 per acceptor) this needs an uneven spread before it shows. An
  operator who lowers `max_connections` to protect memory hits it early.
  Each hit also costs the client 5 s before the close.
- **Suggested fix:** Use one acceptor with `num_connections: max_connections`,
  as the health listener already does (`application.ex:121-127`). The cap is
  then exact, and the "rounds up to a multiple of 100" note in the reference
  (`dev/image_pipe_server/config/reference.ex:21`) and
  `docs/server-configuration.md:156` goes away. One acceptor easily keeps up
  with an image server's connection rate, but measure accept throughput under
  a connection burst before settling on it. Several acceptors each sized to
  the whole cap would let the real total exceed `max_connections`, so that
  isn't a fix. Add a test that holds a connection open and checks that a
  second connection is served at `max_connections: 2`.

## 2. Medium (h2c only): an HTTP/2 request slower than `read_timeout` loses its response

- **File:** `image_pipe_server/lib/image_pipe_server/application.ex:150`
  (`read_timeout` passed to ThousandIsland); behavior in
  `deps/bandit/lib/bandit/http2/handler.ex:62-69`
- **Status:** reproduced.
- **Evidence:** The listener accepts HTTP/2 with prior knowledge (h2c), as
  bug-hunt-3 finding 1 showed. Bandit's HTTP/2 handler closes the whole
  connection when the socket has been quiet for `read_timeout`, even while a
  stream is still being processed. A client that sent a request and waits for
  the response sends nothing in between, so a slow response trips the
  timeout. With `read_timeout = 1000` and a plug that sleeps:

  | Protocol | Handler time | Result |
  |---|---|---|
  | HTTP/1.1 | 500 ms | 200 |
  | HTTP/1.1 | 2,500 ms | 200 |
  | HTTP/2 (h2c) | 500 ms | 200 |
  | HTTP/2 (h2c) | 2,500 ms | connection closed, no response |

  The defaults make this reachable: `read_timeout` is 10 s, while a request
  may wait up to `queue_timeout` (10 s) in the pool and then process for up to
  `processing_timeout` (30 s). A queued request, a large AVIF encode, or
  detection on a throttled CPU can exceed 10 s. Every other stream on that
  connection is lost too. HTTP/1 isn't affected, because Bandit doesn't read
  from the socket while the plug runs.

  It matters when the proxy in front speaks h2c to the server. Examples are
  Envoy or Istio with `appProtocol: h2c`, Traefik `h2c://`, Caddy's `h2c`
  transport, and Cloud Run end-to-end HTTP/2.
- **Open question for Håvard:** Does anything in front of the server (Bunny's
  ingress included) speak h2c to it? If nothing should, turning HTTP/2 off is
  the simplest fix, and it also removes the HTTP/2 drain gap from bug-hunt-3
  finding 1.
- **Suggested fix:** Either:
  - Turn off h2c with `http_2_options: [enabled: false]` in `http_child/2`.
    The server speaks plain HTTP behind a TLS terminator, which normally talks
    HTTP/1.1 to it. Say so in the deployment guide's HTTP section.
  - Or keep h2c and report the Bandit behavior upstream (no read timeout while
    a stream is open). Until it's fixed, document that over HTTP/2,
    `read_timeout` must be longer than `queue_timeout + processing_timeout`.

  Either way, add a test that sends an h2c request slower than
  `read_timeout`, with Mint's `protocols: [:http2]` as in the repro.

## 3. Low (unverified on Bunny): under gVisor, the pool and libvips may size themselves from the host's CPUs

- **Files:** `image_pipe_server/lib/image_pipe_server/config.ex:433-436`
  (`max_concurrency` defaults to `System.schedulers_online()`),
  `image_pipe_server/rel/env.sh.eex:47-64` (`VIPS_CONCURRENCY` from
  `/sys/fs/cgroup/cpu.max` or the cgroup v1 files)
- **Status:** reasoned. Not checked on Bunny Magic Containers.
- **Evidence:** Both limits depend on the container seeing its CPU quota.
  The VM reads the cgroup quota from `/proc/self/cgroup` and the cgroup
  filesystem, and `env.sh` reads `cpu.max`. gVisor emulates both, and only
  when the sandbox mounts a cgroup filesystem. Without the quota files,
  `VIPS_CONCURRENCY` stays unset and libvips uses every CPU the sandbox
  reports. The VM then starts a scheduler per reported CPU, and
  `[pool] max_concurrency` follows it. If Bunny reports the host's cores
  while capping the container at one or two vCPUs, the server processes that
  many images at once. That multiplies peak memory (decoded images, ONNX
  arenas; see memory-hunt finding 2) and spreads the quota thin.
- **Open question for Håvard:** In a running Bunny container, what do these
  print?
  - `cat /sys/fs/cgroup/cpu.max; nproc`
  - `bin/image_pipe_server eval 'IO.inspect({System.schedulers_online(), :erlang.system_info(:logical_processors_available)})'`
  - The `VIPS_CONCURRENCY` in the server's environment. The `eval` command
    above runs `env.sh` too, so `bin/image_pipe_server eval 'IO.inspect(System.get_env("VIPS_CONCURRENCY"))'`
    shows what the server gets.

  If the numbers are the host's, set `[pool] max_concurrency` and
  `VIPS_CONCURRENCY` explicitly for Bunny.
- **Suggested fix:** If confirmed, have the deployment guide's processing
  capacity section say that sandboxed runtimes may not expose the CPU limit,
  and to set both values there. Consider logging the chosen
  `max_concurrency` and `VIPS_CONCURRENCY` once at boot, so a wrong value is
  visible without a shell.

## 4. Low: every log line is preceded by a blank line

- **File:** `image_pipe_server/config/config.exs:15` (sets only the
  formatter's metadata, so Elixir's default template applies)
- **Status:** reproduced.
- **Evidence:** Elixir's default console template starts with a newline
  (`"\n$time $metadata[$level] $message\n"`). The server's output alternates
  blank and real lines:

  ```text
  $
  17:48:37.057 [info] one$
  $
  17:48:37.060 [info] two$
  ```

  Docker's `json-file` driver and line-based collectors store each blank line
  as its own empty entry, doubling the entry count. The timestamp also has no
  date, so a log file read without the platform's own timestamps can't place
  lines across days.
- **Suggested fix:** Set a template in `config/config.exs`, for example
  `config :logger, :default_formatter, format: "$date $time $metadata[$level] $message\n", metadata: [:request_id]`.
  Check `docs/server-deployment.md`'s logging section for any example output
  that would change.

## 5. Low (repeat of bug-hunt-2 finding 5, in part): a `bearer_token` or container `auth_token` with a line break passes the boot check

- **Files:** `image_pipe_server/lib/image_pipe_server/config/sources.ex:282-287`
  (`bearer_token/2`), `sources.ex:328-334` (provider options, here
  `container_credentials` `auth_token`)
- **Status:** reproduced at boot. The failure at fetch time is reasoned.
- **Evidence:** The fix for bug-hunt-2 finding 5 made `request_headers` reject
  CR, LF, and NUL at boot (`sources.ex:261-280`). `bearer_token` only rejects
  an empty string. `IPS_SOURCES__O__BEARER_TOKEN="SECRET\r\nX: y"` loads
  without error, and so does a `container_credentials` `auth_token` with an
  embedded `\n`. Either value goes into a request header on every fetch,
  where Mint rejects it, so every request to that source fails. This is the
  same "fails on every fetch instead of at boot" case the comment at
  `sources.ex:261` describes. A `_FILE` secret only loses trailing
  whitespace, so a file with a stray CRLF in the middle can produce such a
  value.
- **Suggested fix:** Run `bearer_token` through the same value check as
  `request_headers` (`header_error/2`), with an error that names the setting
  and not the value. For the container provider's `auth_token`, add the check
  in `ImagePipe.Source.S3.ContainerCredentials.validate_options/1`, so library
  users get it too.

---

## Checked and found sound

- **TOML errors.** The fuzz above, including unclosed headers, `\u` at end of
  file, multi-line strings, and quoted secrets, gave clean `ConfigError`s with
  no value quoted. The bug-hunt-3 TOML findings (2, 3, 4) are fixed.
- **`IPS_CONFIG_TOML`.** Errors name the variable. Setting it together with
  `IPS_CONFIG` stops the server. `IPS_` variables override it.
- **Source settings that can hold secrets.** HTTP `base_url` and S3
  `endpoint` with credentials or a query, a container `full_uri` with
  credentials, and empty static keys were all rejected without quoting the
  value.
- **Router.** `/health/live` and `/health/ready` skip auth and the mount path,
  and nothing else does. The bearer scheme is case-insensitive, and the
  comparison is constant-time. `x-request-id` is generated unless trusted and
  well-formed.
- **Shutdown order.** The health listener starts first and stops last.
  `prep_stop/1` drains readiness before the listener stops, and the listener
  stops before the pool and instance. Detector model loading and the cache's
  startup scan run in the background, so neither holds up boot past the
  Docker health check's start period.
- **Release scripts.** Distribution stays off by default and binds to
  loopback when on. jemalloc falls back to glibc with `MALLOC_ARENA_MAX=2`.
  `VIPS_CONCURRENCY` rounds the quota up. Scheduler busy-waiting is off
  (`rel/vm.args.eex`).
- **Large values.** Very large timeouts and limits are accepted. A
  `read_timeout` of 5,000,000,000 ms still serves requests, and
  `Process.sleep/1` accepts a `shutdown_delay` that large.
- **Getting-started guide.** The `400` and `404` bodies and the AVIF
  negotiation match the router's responses.
