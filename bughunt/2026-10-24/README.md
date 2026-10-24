# Bug hunt artifacts, 2026-10-24

Repro scripts, harnesses and small inputs from the 2026-10-24 bug hunt, fuzz
hunt and docs audit, run against `main` at 7402ee5 (release 0.4.0) with
libvips 8.18.7. The findings themselves are beads:

- `image_plug-pbmw`: bug hunt
- `image_plug-imzd`: fuzz hunt
- `image_plug-mqpm`: docs accuracy audit

Each folder is one subagent's scratch directory, copied as it was. Files over
500 KB and Rust `target/` directories are left out.

The scripts hard-code their original location,
`/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/<area>/`.
To rerun one, copy its folder there or edit the paths, then run it from
`image_pipe/` with `MIX_ENV=test mix run <script>`. `transform/mk.exs` and then
`transform/mk2.exs` regenerate the sources the transform repros use, including
the profile-less CMYK JPEG behind `image_plug-pbmw.1`.

This branch is a record, not something to merge.
