# Bug hunt: request handling

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:11Z

Bug hunt: request handling

## Claude · 2026-10-04T11:39:30Z

I found 5 bugs in request handling. Should I fix them on one branch with a test for each? I've made no code changes yet.

1. **Preset text ending in a newline crashes the request.** A preset lookup that returns `"w=400\n"` raises an exception. It should return the documented "invalid preset definition" error. The cause is `^…$` regex anchors in `value.ex:13`, which let the trailing newline through. I reproduced this.
2. **Every signed URL has 4 valid signatures.** The last base64 character carries 2 unused bits that verification ignores (`signature.ex:73`). The impact is low: up to 4 URLs per signed image, which splits CDN caches. I reproduced this.
3. **A `wm-enc` preset crashes the request** on a mount without source encryption keys. Building the error message assumes `wm-enc` appears in the raw path, which isn't true when a preset supplies it (`request.ex:112`). I traced this through the code but couldn't run it.
4. **Processing errors drop the host's `Vary` header.** When a request fails after processing starts (415, 413, 422 or 500), the response overwrites any `Vary` an earlier plug set, such as `Origin`. The success path merges it correctly (`runner.ex:134`). Traced through the code, not run.
5. **`Accept: image/webp;q=0.` is read as q=1.** That spelling is a valid exclusion, but the server sends WebP anyway (`negotiation.ex:99`). Low impact.

I couldn't run `mise run precommit` because this cloud environment blocks Hex (repo.hex.pm). Instead I built Erlang/Elixir and compiled `image_pipe_url` against GitHub copies of its dependencies. To run the full suite here, add `repo.hex.pm` and `builds.hex.pm` to the allowed domains in [Project settings](#project-settings/environment); this project currently runs on a built-in environment with no settings. File paths, test sketches and a few unconfirmed suspicions are in [request-handling.md](/mnt/project-files/bug-hunt/request-handling.md).

## Håvard · 2026-10-04T11:42:13Z

I've configured the cloud environment, can we spawn the check/validation/fix in a new session?

## Claude · 2026-10-04T11:42:27Z

The new thread is running as "Fix request handling bugs" in the project chat. It works from [request-handling.md](/mnt/project-files/bug-hunt/request-handling.md): it reproduces each bug with a failing test, fixes it, and runs `mise run precommit`. It will commit locally and open a PR only when you ask, since your repo rules say to push only on request.
