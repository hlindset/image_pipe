# Bug hunt: URL builder

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:21Z

Bug hunt: URL builder

## Claude · 2026-10-04T11:49:13Z

I stopped after the builder-to-parser round-trip check, before preset expansion and encrypted watermarks. Nothing was pushed. The notes are in [url-builder.md](/mnt/project-files/bug-hunt/url-builder.md).

What I found:

- **Signatures can be written four ways.** The server ignores the last two bits of the signature's final character, so four different URLs verify for the same image. This is in `signature.ex`.
- **Equivalent URLs can get separate cache entries.** For example, `crop=10` and `crop=10.0` count as different requests, and so do a gradient angle just below 0 and `0`. The output image is the same, so the only cost is duplicate cache entries.

Every URL the builder generated parsed correctly. These checks ran on Elixir 1.18 / OTP 25 because hex.pm is blocked here, not the repo's OTP 29.
