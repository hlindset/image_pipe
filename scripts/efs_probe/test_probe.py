"""Local harness checks. These do not qualify NFS, EFS, or lock recovery."""

from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import signal
import tempfile
import unittest

from probe import Peer, initialize, smoke


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = initialize(self.temp.name)
        self.script = str(Path(__file__).with_name("probe.py"))
        self.output = io.StringIO()
        capture = redirect_stdout(self.output)
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def peer(self, timeout=10):
        peer = Peer("local", str(self.root), self.script, timeout)
        self.addCleanup(peer.close)
        self.assertEqual(peer.ready["result"], "ready")
        return peer

    def test_smoke_uses_independent_processes(self):
        smoke(str(self.root), "local", "local", self.script)
        self.assertIn('"result": "smoke_passed"', self.output.getvalue())
        self.assertIn('"efs_qualified": false', self.output.getvalue())

    def test_publication_can_succeed_without_a_reply(self):
        owner = self.peer()
        token = owner.ask("stage", value="complete bytes")["token"]
        with self.assertRaises(RuntimeError):
            owner.ask("publish_crash")
        reader = self.peer()
        self.assertEqual(reader.ask("generation", token=token),
                         {"result": "generation", "value": "complete bytes"})

    def test_corrupt_anchor_does_not_return_old_evidence(self):
        peer = self.peer()
        self.assertEqual(peer.ask("lock")["result"], "locked")
        self.assertEqual(peer.ask("write", value="old")["result"], "written")
        self.assertEqual(peer.ask("release")["result"], "released")
        (self.root / "anchor").write_bytes(b"torn write")
        self.assertEqual(peer.ask("lock")["result"], "locked")
        self.assertEqual(peer.ask("read")["result"], "error")

    def test_controller_deadline_does_not_wait_for_stopped_worker(self):
        peer = self.peer()
        peer.timeout = 0.1
        os.kill(peer.process.pid, signal.SIGSTOP)
        with self.assertRaises(TimeoutError):
            peer.ask("lock")
        # Cleanup kills this local worker. This says nothing about remote NFS I/O cancellation.


if __name__ == "__main__":
    unittest.main()
