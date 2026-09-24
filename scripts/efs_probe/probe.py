#!/usr/bin/env python3
"""Filesystem semantics probe, not a cache implementation or EFS certification."""

import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import shlex
import signal
import socket
import subprocess
import sys
import time
import uuid

MARKER = "imagepipe-efs-probe-v1"
BLOCK_SIZE = 4096


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def initialize(parent):
    root = Path(parent) / ("imagepipe-efs-probe-" + uuid.uuid4().hex)
    root.mkdir(mode=0o700)
    (root / "PROBE").write_text(MARKER)
    (root / "staging").mkdir()
    (root / "generations").mkdir()
    (root / "anchor").touch()
    return root


def profile(root):
    result = {"host": socket.gethostname(), "platform": platform.platform(),
              "python": platform.python_version(), "pid": os.getpid(), "root": str(root)}
    setting = Path("/sys/module/nfs/parameters/recover_lost_locks")
    result["recover_lost_locks"] = setting.read_text().strip() if setting.exists() else None
    if sys.platform == "linux":
        result["mount"] = subprocess.check_output(
            ["findmnt", "--json", "--target", str(root), "--output", "TARGET,SOURCE,FSTYPE,OPTIONS"],
            text=True, timeout=5).strip()
    return result


class Worker:
    def __init__(self, root):
        self.root = Path(root)
        if (self.root / "PROBE").read_text() != MARKER:
            raise ValueError("not a probe directory")
        self.fd = None
        self.stage = None

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def command(self, request):
        op = request["op"]
        if op == "lock":
            if self.fd is not None:
                raise ValueError("already holding a descriptor; do not reacquire after lock loss")
            fd = os.open(self.root / "anchor", os.O_RDWR | os.O_SYNC)
            try:
                fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                os.close(fd)
                if error.errno in (errno.EAGAIN, errno.EACCES):
                    return {"result": "busy"}
                raise
            self.fd = fd
            return {"result": "locked", "inode": os.fstat(fd).st_ino}
        if op == "release":
            self.close()
            return {"result": "released"}
        if op in ("write", "read"):
            if self.fd is None:
                raise ValueError("lock first")
            if op == "write":
                payload = json.dumps({"value": request["value"]}, sort_keys=True).encode()
                block = hashlib.sha256(payload).hexdigest().encode() + b"\n" + payload
                if len(block) > BLOCK_SIZE:
                    raise ValueError("record too large")
                count = os.pwrite(self.fd, block.ljust(BLOCK_SIZE, b"\0"), 0)
                if count != BLOCK_SIZE:
                    raise OSError(errno.EIO, "short anchor write")
                os.fsync(self.fd)
                return {"result": "written", "bytes": count}
            block = os.pread(self.fd, BLOCK_SIZE, 0)
            if not block:
                return {"result": "empty"}
            if len(block) != BLOCK_SIZE:
                raise ValueError("incomplete anchor")
            block = block.rstrip(b"\0")
            digest, payload = block.split(b"\n", 1)
            if hashlib.sha256(payload).hexdigest().encode() != digest:
                raise ValueError("invalid anchor checksum; must revalidate, never use an old copy")
            return {"result": "read", **json.loads(payload)}
        if op == "stage":
            token = uuid.uuid4().hex
            path = self.root / "staging" / token
            path.mkdir()
            body = request["value"].encode()
            metadata = json.dumps({"sha256": hashlib.sha256(body).hexdigest()}).encode()
            for name, data in (("body", body), ("meta", metadata)):
                with open(path / name, "xb") as file:
                    file.write(data)
                    file.flush()
                    os.fsync(file.fileno())
            self.stage = token
            return {"result": "staged", "token": token}
        if op in ("publish", "publish_crash"):
            if self.stage is None:
                raise ValueError("stage first")
            os.rename(self.root / "staging" / self.stage,
                      self.root / "generations" / self.stage)
            if op == "publish_crash":
                os.kill(os.getpid(), signal.SIGKILL)
            return {"result": "published", "token": self.stage}
        if op == "generation":
            token = uuid.UUID(hex=request["token"]).hex
            path = self.root / "generations" / token
            if not path.exists():
                return {"result": "missing"}
            body = (path / "body").read_bytes()
            metadata = json.loads((path / "meta").read_bytes())
            if hashlib.sha256(body).hexdigest() != metadata["sha256"]:
                raise ValueError("generation mismatch")
            return {"result": "generation", "value": body.decode()}
        if op == "rename_head":
            # Deliberately unsafe control: namespace mutation has no lock stateid.
            path = self.root / ("head-" + uuid.uuid4().hex)
            with open(path, "x") as file:
                file.write(request["value"])
                file.flush()
                os.fsync(file.fileno())
            os.replace(path, self.root / "unsafe-head")
            return {"result": "renamed"}
        if op == "read_head":
            return {"result": "head", "value": (self.root / "unsafe-head").read_text()}
        if op == "crash":
            os.kill(os.getpid(), signal.SIGKILL)
        raise ValueError("unknown operation")


def worker(root):
    instance = Worker(root)
    emit({"result": "ready", "profile": profile(instance.root)})
    try:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                result = instance.command(request)
            except (OSError, ValueError, KeyError) as error:
                result = {"result": "error", "error": str(error),
                          "errno": getattr(error, "errno", None)}
            emit(result)
    finally:
        instance.close()


class Peer:
    """A local process or SSH worker; controller deadlines do not cancel remote I/O."""

    def __init__(self, host, root, script, timeout=10):
        command = ["python3", "-u", script, "worker", root]
        if host != "local":
            command = ["ssh", "-T", "-oBatchMode=yes", "-oConnectTimeout=10",
                       host, shlex.join(command)]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.timeout = timeout
        self.host = host
        try:
            self.ready = self.receive()
        except BaseException:
            self.close()
            raise

    def receive(self):
        deadline = time.monotonic() + self.timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.selector.select(remaining):
                raise TimeoutError("worker reply timed out; remote operation may still be running")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("worker exited before replying")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        result = json.loads(line)
        emit({"host": self.host, "reply": result})
        return result

    def ask(self, op, **kwargs):
        request = {"op": op, **kwargs}
        emit({"host": self.host, "request": request})
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            emit({"result": "cleanup_pending", "pid": self.process.pid, "host": self.host})
        self.selector.close()
        self.process.stdin.close()
        self.process.stdout.close()


def expect(result, expected, **fields):
    if result.get("result") != expected or any(result.get(k) != v for k, v in fields.items()):
        raise AssertionError((result, expected, fields))


def smoke(root, host_a, host_b, script):
    peers = []
    try:
        a = Peer(host_a, root, script)
        peers.append(a)
        b = Peer(host_b, root, script)
        peers.append(b)
        expect(a.ready, "ready")
        expect(b.ready, "ready")
        expect(a.ask("lock"), "locked")
        expect(b.ask("lock"), "busy")
        expect(a.ask("write", value="A"), "written")
        staged = a.ask("stage", value="generation-A")
        expect(staged, "staged")
        token = staged["token"]
        expect(b.ask("generation", token=token), "missing")
        expect(a.ask("publish"), "published")
        expect(b.ask("generation", token=token), "generation", value="generation-A")
        expect(a.ask("release"), "released")
        expect(b.ask("lock"), "locked")
        expect(b.ask("read"), "read", value="A")
        expect(b.ask("write", value="B"), "written")
        expect(b.ask("rename_head", value="B"), "renamed")
        expect(a.ask("rename_head", value="stale-A"), "renamed")
        expect(b.ask("read_head"), "head", value="stale-A")
        # This demonstrates advisory-lock bypass, not genuine NFS lock revocation.
        b.process.stdin.write(b'{"op":"crash"}\n')
        b.process.stdin.flush()
        b.process.wait(timeout=10)
        expect(a.ask("lock"), "locked")
        expect(a.ask("read"), "read", value="B")
        emit({"result": "smoke_passed", "efs_qualified": False,
              "note": "normal operations only; partition and lost-reply experiments still required"})
    finally:
        for peer in peers:
            peer.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    init = sub.add_parser("init")
    init.add_argument("parent")
    run = sub.add_parser("worker")
    run.add_argument("root")
    test = sub.add_parser("smoke")
    test.add_argument("root")
    test.add_argument("--a", default="local", help="SSH alias or local")
    test.add_argument("--b", default="local", help="SSH alias or local")
    test.add_argument("--script", default=str(Path(__file__).resolve()))
    args = parser.parse_args()
    if args.mode == "init":
        print(initialize(args.parent))
    elif args.mode == "worker":
        worker(args.root)
    else:
        smoke(args.root, args.a, args.b, args.script)


if __name__ == "__main__":
    main()
