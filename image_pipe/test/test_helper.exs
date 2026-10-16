# Cross-process `assert_receive {:DOWN, ...}` liveness checks (e.g. the
# ImagePipe.Delivery producer tests) can exceed the default 100ms budget under CI
# scheduler load (oversubscribed cores plus libvips/NIF work on dirty
# schedulers), producing flaky timeouts. Give those waits more slack; it does
# not slow down the passing path, which delivers the message near-instantly.

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

# Some tests depend on the machine more than the code. Tests tagged
# `:file_permissions` revoke access with `chmod`, which root (as in a Claude Code
# cloud session) ignores. Tests tagged `:ipv6` listen on `::1`, which a host
# without IPv6 can't bind. Each tag is excluded where its precondition fails.
file_permissions? = fn ->
  path =
    Path.join(System.tmp_dir!(), "image_pipe_permissions_#{System.unique_integer([:positive])}")

  File.write!(path, "")
  File.chmod!(path, 0o000)

  try do
    match?({:error, :eacces}, File.read(path))
  after
    File.rm(path)
  end
end

ipv6? = fn ->
  case :gen_tcp.listen(0, [:inet6, ip: {0, 0, 0, 0, 0, 0, 0, 1}]) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    {:error, _reason} ->
      false
  end
end

ExUnit.start(
  capture_log: true,
  assert_receive_timeout: 2_000,
  exclude:
    [:image_vision] ++
      if(file_permissions?.(), do: [], else: [:file_permissions]) ++
      if(ipv6?.(), do: [], else: [:ipv6])
)

{:ok, _} = Application.ensure_all_started(:req)
