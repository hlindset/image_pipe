# Performance: image processing

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:37Z

Performance: image processing

## Claude · 2026-10-04T11:46:02Z

I found five performance improvements in image processing and encoding, ranked in [image-processing.md](/mnt/project-files/perf-review/image-processing.md). I haven't changed any code. The Elixir toolchain can't be installed here (hex.pm is blocked), so I timed the same libvips operations from Python on libvips 8.15. Treat the ratios as the reliable part; your Vix build ships 8.18.

1. **AVIF encodes at libvips' default effort 4, and that dominates AVIF requests.** It takes about 700 ms at 1600 px, while effort 3 is about 4× faster for 12–15% more bytes at the same SSIMULACRA2 score. WebP effort 2 is about 2.5× faster than 4 for 4–6% more bytes. Auto-quality search pays the encode on every probe, so this multiplies. This is your call: which default effort do you want?
2. **Trim turns off shrink-on-load** (`decode_planner.ex:62`). Trim plus `w=600` on a 24 MP JPEG takes 1315 ms, against 103 ms at shrink 8. A two-pass plan (find the trim box on a cheap preview, then decode at the right shrink) would fix it, but it changes trim pixels slightly, so it needs a design note first.
3. **Crop-mode quality search rebuilds each tile's reference on every probe** (`crop_score.ex:104`). Building the 16 references once should save roughly 0.4–0.6 s per search on images over 6 MP, with identical output. I worked this out from your own `bench/autoquality.md` numbers rather than measuring it here.
4. **The face and object models run one after the other** (`composite.ex:84`). Running them concurrently would save about the face model's time. I couldn't measure this because the models can't be loaded here.
5. **Production keeps libvips' operation cache on, but every bench and test turns it off.** This mostly affects memory, and it means the benchmarks don't quite match production. I'd do a quick A/B before changing anything.

I also checked the copy to memory before encode, the sRGB→sRGB ICC transform on output, and the orientation flush. All three are within noise or already decided by your earlier fd8 study. One aside: every JPEG fixture is progressive, so shrink-on-load gains look much smaller in your benches than they are on baseline JPEGs.

#3 is the cheapest change with no output difference. Should I make it, test-first?
