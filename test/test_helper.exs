# Cross-process `assert_receive {:DOWN, ...}` liveness checks (e.g. the
# SourceSession.Producer tests) can exceed the default 100ms budget under CI
# scheduler load (oversubscribed cores plus libvips/NIF work on dirty
# schedulers), producing flaky timeouts. Give those waits more slack; it does
# not slow down the passing path, which delivers the message near-instantly.
# `:imgproxy_triage` quarantines recorded-but-unresolved imgproxy differential
# discrepancies (see the lane README + issues #194-#197); run them with
# `--include imgproxy_triage`.
# `:imgproxy_report` / `:twicpics_report` are the full-constellation HTML report
# renders (render every constellation + inline PNGs); they are integration/report
# jobs, not unit coverage, so they are opt-in via `--include imgproxy_report` /
# `--include twicpics_report` (or `mix imgproxy.gen_report` / `mix
# twicpics.gen_report`). Their rendering logic is unit-tested separately.
# `:aws_integration` runs the opt-in LocalStack STS round-trip
# (`--include aws_integration`); it is a protocol-fidelity smoke test, NOT a
# correctness gate (LocalStack does not strictly verify SigV4 — signing is
# already proven by the live S3 GET path).
# Disable libvips' global operation cache for the test run. The cache keys
# operations (notably `vips_autorot`) by their input image's pixel/argument
# hash and is BLIND to mutable EXIF `orientation` metadata. Tests synthesize
# multiple orientations from one base image via `Image.set_orientation!`,
# producing pixel-identical images that differ only in their orientation tag —
# which collide in the cache, so `autorot` can return a rotation computed for a
# different orientation. Under the async suite the shared global cache
# intermittently serves such a stale result, flaking any test that compares
# across synthesized orientations (the deferred-orientation / guided-crop focus
# tests). The library never calls `set_orientation` — production orientation
# comes from each source's own decoded EXIF, so real requests never produce
# pixel-identical images with differing orientation, and the cache stays correct
# (and enabled) in production. Disabling it here only removes a test-only
# aliasing artifact; correct code is cache-transparent.
Vix.Vips.cache_set_max(0)

ExUnit.start(
  capture_log: true,
  assert_receive_timeout: 2_000,
  exclude: [
    :image_vision,
    :imgproxy_triage,
    :imgproxy_report,
    :twicpics_triage,
    :twicpics_report,
    :aws_integration
  ]
)

{:ok, _} = Application.ensure_all_started(:req)

# The opt-in `:aws_integration` lane provisions Docker via `testcontainers`. Own
# the testcontainers manager from this long-lived test-runner process (only when
# the dep is present, i.e. `AWS_INTEGRATION`/`IMGPROXY_DIFF`) so it outlives the
# transient `setup_all` process and is still alive for suite-teardown `on_exit`
# container cleanup. Starting it from `setup_all` instead links the manager to a
# process that exits before `on_exit` runs, killing it mid-cleanup. No effect on
# the default lane: the dep is absent there, so this block is skipped.
if Code.ensure_loaded?(Testcontainers) do
  {:ok, _} = Application.ensure_all_started(:testcontainers)

  case Testcontainers.start_link() do
    {:ok, _pid} -> :ok
    {:error, {:already_started, _pid}} -> :ok
  end
end
