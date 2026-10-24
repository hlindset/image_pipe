What: the server release runs with the BEAM default process limit, 1,048,576 (`:erlang.system_info(:process_limit)`). The VM allocates and touches the process table (and its per-slot bookkeeping) for the full limit at boot, so every idle server pays for a million process slots. A server with the default `max_connections = 2048` and `max_queue = 1024` runs on the order of 10^3-10^4 processes at peak (one per connection plus pool/coalescing/fetch tasks); an idle one runs ~200.

Where: image_pipe_server/rel/vm.args.eex sets no `+P`.

Measured (local prod release of image_pipe_server 0.4.0, OTP 29.1.1 / Elixir 1.20.4, jemalloc preloaded as rel/env.sh does, interactive mode, minimal TOML: one file source, no cache, log_requests=false; 4-CPU box; three nodes started side by side, read 15 s after boot, repeated in two separate runs):

| +P | process_limit | VmRSS | RssAnon | erlang.memory processes | system | total |
|---|---|---|---|---|---|---|
| default | 1,048,576 | 114.2-119.1 MiB | 59.2-64.3 | 21.0 | 36.2 | 57.2 |
| 262144 | 262,144 | 102.8-106.6 | 47.7-50.5 | 9.2 | 33.1 | 42.4 |
| 65536 | 65,536 | 100.6-105.1 | 45.5-49.1 | 9.8 | 32.4 | 42.2 |

So the default costs ~14 MiB RSS (12-16 across runs), about 12% of an idle server. It's a fixed floor for the life of the node, not load-dependent.

Repro: start the release twice, once with `ELIXIR_ERL_OPTIONS="+P 65536"` (and another `IPS_SERVER__PORT`), then
`bin/image_pipe_server rpc 'IO.inspect({:erlang.system_info(:process_limit), :erlang.memory()})'` and `grep -E "VmRSS|RssAnon" /proc/<beam pid>/status`.

Proposed fix: add `+P 262144` to rel/vm.args.eex with a comment (saves ~11.5 MiB; leaves room for ~100k connections). A deployment that raises `max_connections` toward that can override via ELIXIR_ERL_OPTIONS, or env.sh could derive it from IPS_SERVER__MAX_CONNECTIONS when set. Size: one vm.args line + comment + server changelog entry. Risk: low; running out raises system_limit on spawn, so keep the limit well above max_connections + max_queue x processes per request. 65536 saves ~2 MiB more but leaves less headroom.
