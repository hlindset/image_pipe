# Bug hunt: standalone server

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:24Z

Bug hunt: standalone server

## Claude · 2026-10-04T11:37:06Z

I found 7 bugs in the standalone server; the full write-up is in [standalone-server.md](/mnt/project-files/bug-hunt/standalone-server.md). Two need your decision first.

None of them is proven by a test yet. This cloud environment's network policy blocks hex.pm, so I couldn't fetch dependencies or run `mise run precommit:server`. Each finding comes from reading the server and library code, and the file says which test would reproduce it. To change the policy, add `hex.pm` and `repo.hex.pm` under Allowed domains in the cloud environment's network access ([Project settings](#project-settings/environment); [steps](https://code.claude.com/docs/en/cloud-environments#network-access)). This project has no cloud environment selected, so it runs on a built-in one with no settings, and you'd need to add one first.

The two worth acting on:
1. **High:** the published Docker image starts Erlang distribution, the release default. Every container of a tag shares the cookie baked in at build time, and anyone can read it from the public image. So any pod or container that can reach it could run code inside it. The Dockerfile sets no `RELEASE_DISTRIBUTION` and there is no `rel/env.sh` (`Dockerfile:108-129`).
2. **Medium:** an empty `IPS_URL__KEYS`, or a `IPS_URL__KEYS_FILE` pointing at an empty secret file, gives `keys: []`. The server then boots and serves unsigned URLs instead of refusing to start (`config/convert.ex:124`, `:184`).

The other five:
- `…AUTH_TOKEN_FILE` for `container_credentials` reads the rotating token once at boot instead of on every refresh, which contradicts the docs.
- The Docker HEALTHCHECK ignores a port set in the TOML file.
- `server.port` accepts values above 65535.
- The `Bearer` scheme is matched case-sensitively.
- Empty `OTEL_*` variables turn tracing on.

Should I fix them? I'd do it on one branch with a test for each finding, and leave out the network change unless you make it.

## Håvard · 2026-10-04T11:41:03Z

I've configured the cloud environment, can we spawn the check/fix in a new session?

## Claude · 2026-10-04T11:41:07Z

I'll ask for a new session that checks each finding with a test and then fixes it.

## Claude · 2026-10-04T11:41:16Z

I've asked for a new session to take this over, and it will start in the project chat. It runs on your new environment, so it should be able to fetch from hex.pm this time. It will write a failing test for each of the 7 findings first, then fix them on one branch and open a draft PR.
