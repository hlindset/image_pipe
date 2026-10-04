# Bug hunt: image processing and output

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:18Z

Bug hunt: image processing and output

## Claude · 2026-10-04T11:42:24Z

I found 13 likely bugs, but none has been reproduced yet. This cloud environment blocks the Hex package host (`repo.hex.pm`), so I couldn't install mix or the dependencies, and all of this comes from reading the code. Your project runs on the built-in environment, which has no network settings. To allow tests, add a cloud environment in [Project settings](#project-settings/environment) with `repo.hex.pm` (or broader access) allowed.

The top five, all checked line by line:
- **Odd-sized `region` crops land 1px off.** `crop.ex:196-200` turns the origin into a centre and back with `round`, so `region=0,0,3,3` crops from (1,1).
- **Single-axis `fit=stretch` is blurry.** `w=500/fit=stretch` on a 4000×3000 JPEG loads at 500×375, then stretches it back up to 3000 rows (`executor.ex:747`, `decode_planner.ex:102`).
- **A failed watermark leaves a temp file behind.** The staged source is never released when a watermark fetch fails (`execution.ex:69-77`).
- **Detection finds the wrong spot with `orient=none`.** The bundled face and object detectors auto-rotate by EXIF, so on rotated photos the boxes come back in the wrong frame.
- **`info` can report the wrong size.** It reports dimensions before the output clamp: a 9000×3000 source shows as 9000×3000, but the image comes back at 8192×2731.

The full list with triggers and suggested fixes is in [image-processing-and-output.md](/mnt/project-files/bug-hunt/image-processing-and-output.md).

Should I fix these? If yes, I'd start with the top five as test-first fixes on one branch, and I'd need the Hex host allowed to run the tests.
