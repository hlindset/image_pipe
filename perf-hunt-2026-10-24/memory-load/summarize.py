#!/usr/bin/env python3
# summarize.py OUT_DIR : per-phase peak/end RSS, BEAM, vips highwater
import sys, csv
d = sys.argv[1]
rows = list(csv.DictReader(open(f"{d}/samples.csv")))
for r in rows:
    r["t"] = float(r["t"])
marks = []
for line in open(f"{d}/phases.log"):
    p = line.split(" ", 1)
    try:
        marks.append((float(p[0]), p[1].strip()))
    except ValueError:
        print("   ", line.rstrip())
marks.append((rows[-1]["t"] + 1, "END"))
f = lambda r, k: float(r[k])
print(f"{'phase':28} {'rssMax':>7} {'rssEnd':>7} {'anonEnd':>7} {'erlMax':>7} {'erlEnd':>7} {'binMax':>7} {'procMax':>7} {'vipsMax':>7} {'vipsHW':>7} {'thr':>4} {'procs':>5}")
for (t0, name), (t1, _) in zip(marks, marks[1:]):
    seg = [r for r in rows if t0 <= r["t"] < t1]
    if not seg:
        continue
    e = seg[-1]
    print(f"{name[:28]:28} {max(f(r,'rss_mb') for r in seg):7.0f} {f(e,'rss_mb'):7.0f} {f(e,'rss_anon_mb'):7.0f} "
          f"{max(f(r,'erl_total') for r in seg):7.0f} {f(e,'erl_total'):7.0f} {max(f(r,'erl_bin') for r in seg):7.0f} "
          f"{max(f(r,'erl_proc') for r in seg):7.0f} {max(f(r,'vips_mem') for r in seg):7.0f} {f(e,'vips_hw'):7.0f} "
          f"{max(int(r['threads']) for r in seg):4} {max(int(r['procs']) for r in seg):5}")
print("last top:", rows[-1]["top"])
