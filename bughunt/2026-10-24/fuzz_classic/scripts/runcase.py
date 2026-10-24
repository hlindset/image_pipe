import sys, subprocess, resource, time, os, json
# usage: runcase.py ROOT FILE TIMEOUT pipeline...
root, f, to = sys.argv[1], sys.argv[2], int(sys.argv[3]); pipes = sys.argv[4:]
S = os.path.dirname(os.path.abspath(__file__))
t0 = time.time()
env = dict(os.environ, MIX_ENV="test", ERL_CRASH_DUMP="/dev/null")
try:
    p = subprocess.run(["mix", "run", os.path.join(S, "run.exs"), root, f] + pipes, cwd="/home/user/image_pipe/image_pipe", capture_output=True, text=True, timeout=to, env=env, errors="replace")
    rc, out, err = p.returncode, p.stdout, p.stderr
except subprocess.TimeoutExpired as e:
    rc, out, err = "TIMEOUT", (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""), ""
    subprocess.run(["pkill", "-f", f"run.exs {root} {f}"])
rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
dt = time.time() - t0
res = [l for l in out.splitlines() if l.startswith("RESULT")]
print(f"CASE\t{f}\trc={rc}\trssMB={rss}\t{dt:.1f}s\tn={len(res)}/{len(pipes)}")
for l in res: print("  " + l[7:][:300])
if rc != 0:
    tail = (out + err)[-1500:]
    print("  TAIL: " + tail.replace("\n", "\n        "))
