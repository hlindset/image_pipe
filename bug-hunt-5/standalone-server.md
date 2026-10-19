# Bug hunt 5: standalone server (image_pipe_server)

Date: 2026-10-19. Scope: `image_pipe_server/` on `main` at `8edf03b`
(0.3.0 plus Unreleased): the router, health and the new `/stats` and
`/metrics` endpoints, auth, config loading, logging setup, `rel/env.sh.eex`,
`rel/vm.args.eex`, the Dockerfile, and the server docs. Most of the new
surface since bug hunt 4 is the stats endpoints (`33c4456`), `log_colors`
(`caec08a`), and request logging on by default.

Deduped against `bug-hunt/`, `bug-hunt-2/`, `bug-hunt-3/`, and
`bug-hunt-4/standalone-server.md`, the memory hunt report, and the pushed
beads. All five bug hunt 4 server findings are fixed on main (beads
`image_plug-6lz0.3.1` to `.3.5`, all closed): one acceptor makes
`max_connections` exact (`72d88ba`), h2c is off (`57e1100`, checked: a
prior-knowledge HTTP/2 request is refused, an HTTP/2 upgrade gets HTTP/1.1),
the blank line before log lines is gone (`c0af3b4`), and `bearer_token` and
the container `auth_token` reject line breaks at boot (`8bef675`, checked).

How this was checked: the server ran locally with `mix run --no-halt` and a
TOML file per case (Bandit 1.13.1, ThousandIsland 1.6.0, OTP 29.1.1,
Elixir 1.20.4), with `curl` against it. Config cases went through
`ImagePipeServer.Config.load!/2`. disksup behavior was checked against
`os_mon-2.12/src/disksup.erl` and by calling `disksup:get_disk_info/1`
directly. No Docker image was built.

---

## 1. Medium-low: the stats endpoints report no disk space for a cache on a network or FUSE volume

- **File:** `image_pipe_server/lib/image_pipe_server/stats.ex:68-77`
  (`disk/1`, through `:disksup.get_disk_info/1`)
- **Status:** reproduced on a FUSE mount. The hang case is reasoned.
- **Evidence:** On Linux, disksup runs `df -lk -x squashfs <path>`
  (`disksup.erl:441-443`). `-l` limits `df` to local filesystems, and GNU
  `df` treats any filesystem whose source contains `:` as remote. That covers
  NFS and EFS (`host:/export`), and FUSE mounts such as rclone. For such a
  root `df` prints `df: no file systems processed`, disksup answers
  `[{Path, 0, 0, 0}]`, and `disk/1` reports `nil`:

  ```text
  $ df -lk -x squashfs /mnt/project-files/
  df: no file systems processed
  ```

  The deployment guide says the disk numbers are "for the filesystem that
  holds the cache's `root` directory, such as the volume mounted there", and
  `null` only "when the server can't read them"
  (`docs/server-deployment.md:285-287`). The same guide suggests EFS for
  sources (`:233`), so a network volume under the cache is plausible, and
  there the metrics are always missing, with no hint why.

  Reasoned, not reproduced: disksup is one process that runs each `df`
  through one shell, and `get_disk_info/1` calls it with an `infinity`
  timeout. A `df` that blocks on a hung NFS mount blocks every later `/stats`
  and `/metrics` request for good. Each one holds a connection, and the
  health listener has only 16 (`application.ex:166-182`), so a Prometheus
  scraper on the health port would fill it and then fail the liveness probe.
- **Open question for Håvard:** What do `/stats`' `disk_free_bytes` and
  `disk_total_bytes` show on Bunny Magic Containers? If Bunny's persistent
  volume shows up as a network or FUSE filesystem under gVisor, they'll be
  `null` there.
- **Suggested fix:** Read the space without disksup: run
  `System.cmd("df", ["-kP", "--", root])` (no `-l`, no shell) under a
  `Task` with a short timeout, and parse the last line. This also fixes
  finding 2, and lets `os_mon` go from `extra_applications` and the
  `:os_mon` config in `config/config.exs`. Add a test with a root whose
  path has a space.

## 2. Low: a cache root with a space gets no disk metrics, and one with shell syntax runs it

- **File:** `image_pipe_server/lib/image_pipe_server/stats.ex:69`;
  `disksup.erl:401` and `:443` (`my_cmd/2` and `run_df/3` splice the path
  into a shell command unquoted)
- **Status:** reproduced.
- **Evidence:** disksup builds `"df -lk -x squashfs " ++ Path` and sends it
  to `sh`. The server accepts any absolute path as a cache root
  (`config.ex:242-249`).
  - With `[cache.output] root = ".../cache dir"`, the server served images
    and `/stats` answered `"disk_free_bytes": null, "disk_total_bytes": null`.
    The same config with `.../c2` reported both.
  - `disksup:get_disk_info("/tmp;touch /tmp/pwned_by_df")` created
    `/tmp/pwned_by_df` and returned the disk of `/`.

  The root comes from the operator's own config, so this isn't a privilege
  boundary, but a root with a space or `$` (some mount tools name volumes
  that way) silently loses the metrics, and anything else after `;` runs on
  every scrape.
- **Suggested fix:** The fix in finding 1. Without it, reject cache roots
  that contain whitespace or shell metacharacters when `[stats]` is on, with
  an error that names the setting.

## 3. Low: `/stats` answers 500 with a crash log while the ImagePipe instance isn't running

- **File:** `image_pipe_server/lib/image_pipe_server/stats.ex:60-65`
  (`snapshot/1` calls `ImagePipe.cache_stats/1`, which raises through
  `ImagePipe.Config.fetch_instance!/2`, `image_pipe/lib/image_pipe/config.ex:672-675`)
- **Status:** reproduced at the plug. The boot and shutdown windows are
  reasoned from the child order.
- **Evidence:** The health listener starts before the ImagePipe instance and
  stops after it (`application.ex:113-129`), and it serves the stats when
  `health_port` is set. A stats request in between raises:

  ```text
  Health.call(conn(:get, "/stats") with the token, stats for an instance that isn't running)
  raised: ImagePipe instance NotRunning is not running
  ```

  Bandit turns that into a `500` and logs the exception with a stack trace
  at `error`. The windows are short at boot and after the listener drains on
  shutdown, and also open while the instance restarts after a crash
  (`one_for_one`). A scraper hitting them logs an error each time, which
  looks like a server fault. `ImagePipe.cache_stats/1` also calls the
  admission server with the default 5-second `GenServer.call` timeout
  (`image_pipe/lib/image_pipe/cache/file_system/admission.ex:152`), so a
  busy admission process gives the same 500.
- **Suggested fix:** In `Stats.respond/2`, answer `503` with an empty body
  when the instance isn't running, like `/health/ready` does while starting
  or draining, and let real crashes stay crashes. Add a test that calls the
  health plug's `/stats` with an instance name that isn't running.

## 4. Low (docs): the deployment guide names `IPS_STATS_TOKEN`, which stops the server from booting

- **File:** `image_pipe_server/docs/server-deployment.md:255` (also the
  `curl` example at `:263`)
- **Status:** reproduced.
- **Evidence:** The guide says "Set the token with `IPS_STATS_TOKEN` instead
  to keep it out of the file." Settings need `__` between levels
  (`config/tree.ex:10-12`), so `IPS_STATS_TOKEN` is read as a top-level
  `stats_token` setting:

  ```text
  IPS_STATS_TOKEN=tok IPS_STATS__ENABLED=true mix run ...
  invalid configuration: stats_token: unknown setting
  ```

  `IPS_STATS__TOKEN=tok` boots. The `curl` example's `$IPS_STATS_TOKEN` reads
  as the same variable, so a reader following the guide copies the wrong
  name.
- **Suggested fix:** Say `IPS_STATS__TOKEN`, or better
  `IPS_STATS__TOKEN_FILE=/run/secrets/stats_token` as the auth token section
  does (`:107`). Use a plain shell variable such as `$STATS_TOKEN` in the
  `curl` example.

## 5. Low (repeat of bug-hunt-4 finding 5, in part): static S3 credentials with a line break pass the boot check

- **File:** `image_pipe_server/lib/image_pipe_server/config/sources.ex:57-61`
  (`@static_credentials_schema`, plain `:string` types) and `:329-335`
  (`credentials/2`)
- **Status:** reproduced.
- **Evidence:** Bug hunt 4's fix covered `bearer_token` and the container
  provider's `auth_token`, not static credentials. `token` goes into the
  `x-amz-security-token` header and `access_key_id` into `Authorization`.
  With `credentials = { static = { access_key_id = "AKIDEXAMPLE",
  secret_access_key = "s", token = "SECRET\r\nX: y" } }` the server boots,
  and every request to that source fails:

  ```text
  [error] GET /w=4/src/s3://bucket/pic.png 502 62ms error=source reason="incomplete source response" source=s source_fetch=source_error
  ```

  The same config with a clean token reached the test endpoint (a `404`
  from it). The reason gives no hint at the credentials. A
  `..._TOKEN_FILE` secret only loses trailing whitespace, so a CRLF inside
  the file reproduces it. An `access_key_id` with `\n` also passes boot.
- **Suggested fix:** Check `access_key_id` and `token` in `credentials/2`
  the same way `bearer_token/2` does (`sources.ex:282-295`), with an error
  that names the setting and not the value. Or check it in
  `ImagePipe.Source.S3`'s static credentials validation, so library users get
  it too, as the container provider does.

## 6. Low: lines logged before the server applies `[telemetry]` ignore `log_format`, `log_colors`, and `log_level`

- **File:** `image_pipe_server/lib/image_pipe_server/application.ex:17-20`
  (the formatter and level are set in `start/2`); `config/config.exs:25-27`
- **Status:** reproduced for `log_format`; `log_colors` and `log_level` are
  reasoned from the same order.
- **Evidence:** Dependencies start before `image_pipe_server`, and
  `tls_certificate_check` logs while they do. With `log_format = "json"`,
  every boot begins with a plain-text line before the JSON lines:

  ```text
  2026-10-19 22:19:34.936 [info] Loading 122 CA(s) from :otp store
  {"message":"cache: claimed cache root ...","time":"2026-10-19T22:19:35.037Z",...}
  ```

  A JSON log pipeline (the `gcp`, `datadog`, and `elastic` formats exist for
  them) gets one unparseable line per boot. The same line is printed with
  `log_level = "warning"`, and colored on a terminal with
  `log_colors = false`, since `config.exs`'s default formatter doesn't set
  `colors`. Anything else a dependency logs at startup behaves the same.
- **Suggested fix:** Add `colors: [enabled: false]` to the default formatter
  in `config/config.exs`, so only `log_colors = true` turns colors on. For
  the format and level, either apply them in `config/runtime.exs` (read
  `[telemetry]` there with `Config.Tree.read!/2`, which needs no running
  apps), or start `tls_certificate_check` after the server configures the
  logger. Or document that one line per boot precedes the configured
  format.

## 7. Low (docs): `/stats` drops a cache another replica owns without saying so, and `entries` counts source records

- **Files:** `image_pipe/lib/image_pipe.ex:367-368` and
  `image_pipe/lib/image_pipe/cache.ex:124-132` (`drop_refused/1`), which
  `ImagePipe.cache_stats/1` goes through; `docs/server-deployment.md:240-288`
- **Status:** the entry count is reproduced. The refused cache is reasoned
  from the code.
- **Evidence:**
  - `cache_stats/1` reads the published configuration through
    `fetch_instance!/2`, which drops a cache whose root another node holds.
    A replica that refused a shared root leaves that cache out of `/stats`
    and its series out of `/metrics`. The guide says only "A cache that isn't
    configured isn't listed", so the operator sees a configured cache vanish
    and can't tell from the endpoint that it runs without it.
  - One request on an empty cache gave `"entries": 2` and `"bytes": 670` for
    a 285-byte image. The second entry is the source record
    (`content_type` `application/vnd.imagepipe.source`, 385 bytes). The
    guide describes `entries` as "the bytes and entries each cache holds",
    which reads as cached images.
- **Suggested fix:** List a refused cache with a `"refused": true` field, or
  a `image_pipe_cache_refused` gauge, and say in the guide what it means
  (see the shared-root section of the caching guide). Say that `entries` and
  `bytes` include the records of originals.

---

## Checked and found sound

- **Stats auth.** The stats token is separate from the image auth token and
  each opens only its own endpoints (also covered by `stats_test.exs`).
  Non-string tokens in TOML are rejected without quoting the value. Responses
  keep Plug's default `cache-control: max-age=0, private, must-revalidate`,
  so a CDN in front shouldn't store `/stats` or its `401`.
- **Prometheus text.** Every gauge and counter has `HELP` and `TYPE`, label
  values are fixed atoms, and gauges with no value (disk space unknown) emit
  no sample rather than a `NaN`.
- **JSON logs.** `logger_json` 7.0.4 with Elixir's `JSON` encoder logged the
  request summary for `200`, `400`, and `404` requests, with `request_id` and
  the `image_pipe` map as keys. Its `RedactorEncoder` turns tuples and
  structs into encodable values, so metadata can't crash the formatter.
- **Container credentials.** `auth_token` from TOML or from
  `AWS_CONTAINER_AUTHORIZATION_TOKEN` with a line break stops boot with a
  message that doesn't quote it.
- **h2c.** Off, as above. HTTP/1.1 over the upgrade path still works.
- **Release scripts and Dockerfile.** No changes since bug hunt 4 beyond
  those already checked there. The runtime image has `/bin/df` and `sh`,
  which disksup needs.
