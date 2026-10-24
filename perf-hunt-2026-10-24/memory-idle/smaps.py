#!/usr/bin/env python3
"""Group a process's RSS by mapping (library, anon, shmem, stack). usage: smaps.py PID"""
import re
import sys
from collections import defaultdict

pid = sys.argv[1]
groups = defaultdict(lambda: [0, 0, 0])  # rss, anon, count
cur = None
for line in open(f"/proc/{pid}/smaps"):
    m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$", line)
    if m:
        start, end, perms, path = m.groups()
        size = int(end, 16) - int(start, 16)
        if path == "":
            path = "[anon]"
        elif path.startswith("/memfd:") or "(deleted)" in path:
            path = "[memfd/shm] " + path.split("/")[-1][:40]
        else:
            path = path.split("/")[-1]
        cur = path
        groups[cur][2] += 1
        continue
    if line.startswith("Rss:"):
        groups[cur][0] += int(line.split()[1])
    elif line.startswith("Anonymous:"):
        groups[cur][1] += int(line.split()[1])
total = sum(v[0] for v in groups.values())
print(f"total rss {total/1024:.1f} MiB")
for k, v in sorted(groups.items(), key=lambda kv: -kv[1][0])[:30]:
    print(f"{v[0]/1024:8.2f} MiB rss {v[1]/1024:8.2f} anon  n={v[2]:4d}  {k}")
