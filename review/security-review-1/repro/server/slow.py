import socket, sys, time, threading, urllib.request
port, n, dur = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
socks = []
for i in range(n):
    s = socket.create_connection(("127.0.0.1", port)); s.sendall(b"GET /x HTTP/1.1\r\nHost: a\r\n"); socks.append(s)
def trickle():
    end = time.time() + dur
    while time.time() < end:
        for s in socks:
            try: s.sendall(b"X-a: b\r\n")
            except Exception as e: print("trickle send failed", e); return
        time.sleep(1.0)
t = threading.Thread(target=trickle, daemon=True); t.start()
time.sleep(1.5)
for path in sys.argv[4:]:
    t0 = time.time()
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=8)
        print(path, r.status, round(time.time()-t0, 2))
    except Exception as e:
        print(path, "FAILED", repr(e), round(time.time()-t0, 2))
time.sleep(max(0, dur - (time.time())%1))
