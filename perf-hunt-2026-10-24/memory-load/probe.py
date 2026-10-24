#!/usr/bin/env python3
# probe.py PID PATH... : peak RSS above pre-request RSS for each PATH, run one at a time (3 reps; a
# rep counter goes into the dpr to defeat the cache).
import sys, time, urllib.request, re
pid = sys.argv[1]
def st(k):
    return int(re.search(k + r":\s+(\d+)", open(f"/proc/{pid}/status").read()).group(1)) / 1024
for path in sys.argv[2:]:
    out = []
    for i in range(3):
        p = path.replace("/src/", f"/dpr={1 + (int(time.time()*1000) % 997) / 100000:.5f}/src/", 1)
        time.sleep(1.5)
        base = st("VmRSS")
        open(f"/proc/{pid}/clear_refs", "w").write("5")
        t = time.time()
        with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18181" + p, headers={"Accept": "*/*"}), timeout=300) as r:
            n = len(r.read()); s = r.status
        out.append((st("VmHWM") - base, time.time() - t))
    print(f"{path:60} peak+ {' '.join(f'{a:6.0f}' for a, _ in out)} MiB  {out[-1][1]*1000:6.0f} ms  {s} {n}B", flush=True)
