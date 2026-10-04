# Bug hunt: sources and caching

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:15Z

Bug hunt: sources and caching

## Claude · 2026-10-04T11:42:02Z

I found five likely bugs, but none is confirmed by a test yet. This environment's network policy blocks repo.hex.pm, so dependencies won't install and I couldn't run anything. Every finding below comes from reading the code. Each one has file:line references and a description of a test that should fail in [sources-and-caching.md](/mnt/project-files/bug-hunt/sources-and-caching.md).

1. **Rotating S3 credentials invalidate the cache.** With role-based credentials, each token refresh (about hourly) changes the cache partition. Every cached original and output misses, and versioned objects get new ETags (`source/s3.ex:281`, `source.ex:199`).
2. **An empty S3 revision breaks the request.** A key ending in `%3F` sends `?versionId=`, and AWS rejects that with a 400 (`s3.ex:470`).
3. **Watermarks can loosen the main source's caching rules.** Watermarked responses can add `stale-while-revalidate` or drop `must-revalidate`, because only one source's state shapes the headers (`execution.ex:511`).
4. **Some revalidations download the full body every time.** No `If-None-Match` is sent when the origin varies on `Authorization` (set via `auth:`) or `User-Agent` (`req_stream.ex:98`).
5. **A timeout before response headers returns 502 instead of 504** (`req_stream.ex:146`).

The file also covers three plausible issues, including lost request dedup when a large output isn't stored, plus what checked out as sound.

To run tests in a future session, allow repo.hex.pm and builds.hex.pm. You change this under Network access in an environment's settings ([steps](https://code.claude.com/docs/en/cloud-environments#network-access)). This project runs on the built-in environment, which has no settings. To add one, open [Project settings](#project-settings/environment), open the Cloud environment menu and choose Add cloud environment.

Should I write the failing tests and fixes once tests can run? I'd start with 1 and 2.
