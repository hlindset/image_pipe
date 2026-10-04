# Bug hunt: standalone server (image_pipe_server)

Scope: TOML/env config loading and validation, boot, S3 credentials and token files, observability, release and Docker setup. Checked at commit `84eeac2` (main).

**How these were confirmed:** by reading the server code against the library code it calls. The cloud environment's network policy blocks hex.pm and repo.hex.pm (and mise.run), so `mix deps.get` and `mise run precommit:server` could not run here. None of these has a failing test yet. Each entry says what to write to reproduce it.

## 1. High: Erlang distribution is on in the published image, and every container of a tag shares one cookie

- `image_pipe_server/Dockerfile:108-129` sets no `RELEASE_DISTRIBUTION` or `RELEASE_COOKIE`, and the project has no `rel/env.sh`.
- Mix releases default to `RELEASE_DISTRIBUTION=sname`, so `bin/image_pipe_server start` starts epmd on 0.0.0.0:4369 and a distribution listener on all interfaces.
- The cookie is generated once, when `mix release` runs in the build stage, and written to `/app/releases/COOKIE`. Every container from `ghcr.io/hlindset/image_pipe_server:<tag>` has the same cookie, and anyone can read it with `docker run --entrypoint cat … /app/releases/COOKIE`.
- Impact: in Kubernetes without a NetworkPolicy, or on a shared Docker network, another pod or container can reach epmd and the distribution port and connect with the public cookie. That gives remote code execution as uid 10001. `EXPOSE 8080` does not limit this.
- Repro: `docker run -d --name ips ghcr.io/…:0.1.0` and then `docker exec ips sh -c 'cat /proc/net/tcp'`, which should show :10F1 (4369) listening. Alternatively, from a second container on the same network, run `erl -sname x -setcookie $(cat COOKIE)` and `net_adm:ping('image_pipe_server@<container-hostname>')`.
- Fix options: set `ENV RELEASE_DISTRIBUTION=none` in the runtime stage. That breaks `bin/image_pipe_server remote`, which no doc uses. Alternatively, keep `remote` working by binding distribution to loopback (`ERL_EPMD_ADDRESS=127.0.0.1` plus `-kernel inet_dist_use_interface {127,0,0,1}` in `rel/vm.args.eex`) and generating the cookie at container start.

## 2. Medium: an empty signing-keys variable or secret file silently turns URL signing off

- `config/convert.ex:121-126`: a list read from the environment is split with `String.split(",", trim: true)`. `config/convert.ex:182-185`: `_FILE` contents are `trim_trailing`'d first.
- An empty `IPS_URL__KEYS`, `IPS_URL__KEYS=","`, or an `IPS_URL__KEYS_FILE` that points at an empty or whitespace-only file (for example a secret that wasn't populated) gives `keys: []`. The server then boots and serves **unsigned** URLs ("Without keys, URLs are unsigned", `image_pipe_url/lib/image_pipe/security.ex:16-19`).
- `server.auth_token` is the counterpart: an empty value is rejected (`config.ex` `auth_token_hash!("")`), so the handling is inconsistent, and here it fails open.
- Repro test: `Config.load!(%{"IPS_URL__KEYS_FILE" => empty_tmp_file}, "/nonexistent")` succeeds, and `ImagePipe.url_config(config.image_pipe)` has no keys.
- Suggested fix: reject a list setting from the environment or from a `_FILE` that parses to no entries, with "expected at least one entry". An explicit `keys = []` in TOML can stay valid.

## 3. Medium-low: `IPS_…__CREDENTIALS__AUTH_TOKEN_FILE` reads the rotating token once, at boot

- `config/tree.ex:74` maps `…AUTH_TOKEN_FILE` to the key `auth_token`. `config/convert.ex:167-176` only renames it to `auth_token_file` when the schema lacks `auth_token`, but `container_credentials` has both (`image_pipe/lib/image_pipe/source/s3/container_credentials.ex`).
- So the variable sets `auth_token` to the file's contents as read at boot. EKS Pod Identity rotates that file, and the provider is meant to re-read it on every refresh. After rotation, credential refreshes fail and S3 requests fail.
- This also contradicts `docs/server-configuration.md:75-77` ("Settings whose own name ends in `_file` … take the variable's value as the path").
- It also suppresses the `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` fallback, because a configured `auth_token` keeps the environment's values out (`config/sources.ex` `credentials_aws_environment`).
- Repro test: an env tree with `IPS_SOURCES__S3__CREDENTIALS__PROVIDER=container_credentials` and `IPS_SOURCES__S3__CREDENTIALS__AUTH_TOKEN_FILE=<tmp>` produces credentials options with `auth_token: <contents>` and no `auth_token_file`.
- Suggested fix: when both `name` and `name_file` exist in the schema, prefer `name_file` (path), or document and special-case it.

## 4. Low: the Docker HEALTHCHECK only follows `IPS_SERVER__PORT`

- `Dockerfile:126-127` curls `127.0.0.1:${IPS_SERVER__PORT:-8080}`. When the port is set as `[server] port = 9000` in the TOML file, or through `IPS_SERVER__PORT_FILE`, the check hits 8080 and the container stays `unhealthy`. Swarm, and anything else that acts on health, then restarts it in a loop.
- Suggested fix: add a small `bin/image_pipe_server` health command or `rpc` that reads the loaded port, or document that the port must be set through `IPS_SERVER__PORT` in the image.

## 5. Low: `server.port` has no upper bound

- `config.ex:79` uses `:non_neg_integer`, so `port = 70000` passes validation. Bandit then fails in the supervisor, and the node stops with a crash report instead of the one-line `invalid configuration: server.port: …` that `Application.config!/0` promises.
- Repro test: `Config.build!(server: [port: 70_000])` returns instead of raising `ConfigError`.
- Fix: `{:in, 0..65_535}`.

## 6. Low: the `Bearer` scheme is matched case-sensitively

- `router.ex:66` only accepts `"Bearer " <> token`. RFC 9110 §11.1 makes the auth scheme case-insensitive, so `Authorization: bearer <token>` (sent by some proxies and clients) gets 401.
- Repro test: a request with `authorization: bearer secret` against a router with an `auth_token_hash` answers 401.

## 7. Low: empty `OTEL_*` variables turn tracing on

- `tracing.ex:21-26` uses `Map.has_key?` and `exporter != nil`. The OTel spec says an empty value must be treated as unset.
- `OTEL_EXPORTER_OTLP_ENDPOINT=` (common in Compose files with `${VAR}` interpolation) enables OTLP export to the default localhost:4318, and the exporter then logs connection errors.
- `OTEL_TRACES_EXPORTER=` attaches the tracer with no exporter.
- `OTEL_TRACES_EXPORTER=NONE` (spec: case-insensitive) also enables it.
- Repro test: `Tracing.settings(%{"OTEL_EXPORTER_OTLP_ENDPOINT" => ""})` returns `enabled?: true`.

## Checked and found sound

- Error messages: the library's validators don't quote keys, credentials or `_FILE` contents.
- Credential warmup options match the mount's (same converted sources, and providers validate without rewriting opts).
- Bucket overrides merge onto defaults.
- Env/file merge conflicts are detected.
- `bind` accepts IPv6 (Erlang infers inet6 from an 8-tuple).
- The listener starts last and drains first.
