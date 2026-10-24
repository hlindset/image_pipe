#!/usr/bin/env python3
# solo.py PID [conc] : per-request peak RSS above the pre-request RSS (VmHWM reset via clear_refs=5).
# Run the server with MALLOC_CONF=background_thread:true,dirty_decay_ms:0,muzzy_decay_ms:0 so freed
# pages go back right away and each request's peak isn't hidden by pages kept from the last one.
import sys, time, urllib.request, re, concurrent.futures, random
pid = sys.argv[1]
conc = int(sys.argv[2]) if len(sys.argv) > 2 else 1
B = "http://127.0.0.1:18181"
def st(k):
    s = open(f"/proc/{pid}/status").read()
    return int(re.search(k + r":\s+(\d+)", s).group(1)) / 1024
def get(path, accept="*/*"):
    req = urllib.request.Request(B + path, headers={"Accept": accept})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.status, len(r.read()), r.headers.get("content-type")
cases = [
  ("jpeg 23MP -> w=800 jpeg", "/w=800/src/dog_2.jpg"),
  ("jpeg 19MP -> w=1600 webp", "/w=1600/format=webp/src/mountain.jpg"),
  ("jpeg 19MP -> w=1600 avif", "/w=1600/format=avif/src/mountain.jpg"),
  ("jpeg 19MP -> w=1600 png", "/w=1600/format=png/src/mountain.jpg"),
  ("png rgba 9.7MP -> w=800 jpeg", "/w=800/format=jpeg/src/cooking.png"),
  ("png rgba 6MP -> w=1200 webp", "/w=1200/format=webp/src/alpha.png"),
  ("webp 22MP -> w=1200 jpeg", "/w=1200/format=jpeg/src/para.webp"),
  ("jpeg 1.2MP -> w=400 jpeg", "/w=400/src/concert.jpeg"),
  ("cover 1200x1200 jpeg", "/w=1200/h=1200/fit=cover/src/beach.jpg"),
  ("autoq w=1200 jpeg", "/w=1200/autoquality/format=jpeg/src/mountain.jpg"),
  ("autoq w=1200 webp", "/w=1200/autoquality/format=webp/src/mountain.jpg"),
  ("autoq w=1200 avif", "/w=1200/autoquality/format=avif/src/mountain.jpg"),
  ("origin jpeg 23MP -> w=800", "/w=800/src/origin/dog_2.jpg"),
]
open(f"/proc/{pid}/clear_refs", "w").write("5")
for name, path in cases:
    peaks = []
    for i in range(3):
        p = path.replace("/src/", f"/q={70 + i + (conc and random.randint(0, 9))}/src/", 1) if "autoquality" not in path else path.replace("autoquality", f"autoquality={70 + i * 3 + random.randint(0, 2)}")
        time.sleep(1.5)
        base = st("VmRSS")
        open(f"/proc/{pid}/clear_refs", "w").write("5")
        t = time.time()
        with concurrent.futures.ThreadPoolExecutor(conc) as ex:
            res = list(ex.map(lambda j: get(p.replace("/src/", f"/dpr={1 + j * 0.01:.2f}/src/", 1) if conc > 1 else p), range(conc)))
        dt = time.time() - t
        peaks.append((st("VmHWM") - base, dt, res[0]))
    print(f"{name:32} c={conc} peak+ {' '.join(f'{p:6.0f}' for p, _, _ in peaks)} MiB  {peaks[-1][1]*1000:5.0f} ms  {peaks[-1][2]}", flush=True)
