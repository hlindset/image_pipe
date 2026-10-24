#!/usr/bin/env python3
"""Sum JIT code bytes per module/application from a BEAM +JPperf map file. usage: jitmods.py /tmp/perf-PID.map"""
import re
import sys
from collections import defaultdict

mods = defaultdict(int)
total = 0
for line in open(sys.argv[1]):
    a, s, name = line.rstrip("\n").split(" ", 2)
    size = int(s, 16)
    total += size
    m = re.match(r"^\$?'?([^':]+)'?:", name.lstrip("$"))
    mods[m.group(1) if m else name.split(":")[0]] += size
print(f"total JIT {total/1048576:.2f} MiB in {len(mods)} modules")
groups = defaultdict(int)
for m, s in mods.items():
    if m.startswith("Elixir."):
        key = ".".join(m.split(".")[:2])
    else:
        key = m.split("_")[0]
    groups[key] += s
for k, s in sorted(groups.items(), key=lambda kv: -kv[1])[:25]:
    print(f"{s/1048576:7.2f} MiB  {k}")
print("-- top modules")
for k, s in sorted(mods.items(), key=lambda kv: -kv[1])[:20]:
    print(f"{s/1048576:7.2f} MiB  {k}")
