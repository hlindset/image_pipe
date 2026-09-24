"""Deterministic local-filesystem schedules; not shared-mount qualification."""

import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from protocol import Store, read_entry


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(Path(self.temp.name))

    def publish(self, writer, body=b"image", deadline=1234):
        operation = writer.prepare("key", deadline)
        operation.write_body(body)
        operation.write_meta()
        return operation, operation.publish()

    def test_retirement_at_every_publication_boundary(self):
        for boundary in range(4):
            with self.subTest(boundary=boundary):
                writer = self.store.writer()
                op = writer.prepare("key", 1234)
                steps = [lambda: op.write_body(b"image"), op.write_meta, op.publish]
                for step in steps[:boundary]:
                    step()
                retired = self.store.retire(writer.identity)
                for step in steps[boundary:]:
                    with self.assertRaises(FileNotFoundError):
                        step()
                self.assertEqual(self.store.discover("key"), [])
                self.store.reap(retired)
                self.assertFalse(writer.path.exists())

    def test_crash_at_each_staging_step_never_exposes_partial_entry(self):
        for boundary in range(3):
            writer = self.store.writer()
            op = writer.prepare("key", 1234)
            steps = [lambda: op.write_body(b"image"), op.write_meta]
            for step in steps[:boundary]:
                step()
            self.assertEqual(self.store.discover("key"), [])
            self.store.reap(self.store.retire(writer.identity))

    def test_source_cleanup_at_each_adoption_boundary(self):
        for copy in (False, True):
            for boundary in range(4):
                with self.subTest(copy=copy, boundary=boundary):
                    source = self.store.writer()
                    _, path = self.publish(source)
                    target = self.store.writer()
                    op = target.prepare("key", 1234)
                    metadata = json.loads((path / "meta").read_text())
                    steps = [lambda: op.adopt_body(path, copy),
                             lambda: op.write_meta(metadata), op.publish]
                    for step in steps[:boundary]:
                        step()
                    self.store.reap(self.store.retire(source.identity))
                    if boundary == 0:
                        with self.assertRaises(FileNotFoundError):
                            steps[0]()
                    else:
                        for step in steps[boundary:]:
                            step()
                        self.assertEqual(read_entry(op.destination, "key"),
                                         (b"image", 1234))
                    self.store.reap(self.store.retire(target.identity))

    def test_target_retirement_at_each_adoption_boundary(self):
        for boundary in range(4):
            source = self.store.writer()
            _, path = self.publish(source)
            target = self.store.writer()
            op = target.prepare("key", 1234)
            meta = json.loads((path / "meta").read_text())
            steps = [lambda: op.adopt_body(path), lambda: op.write_meta(meta), op.publish]
            for step in steps[:boundary]:
                step()
            retired = self.store.retire(target.identity)
            for step in steps[boundary:]:
                with self.assertRaises(FileNotFoundError):
                    step()
            self.store.reap(retired)
            self.assertEqual(read_entry(path, "key"), (b"image", 1234))

    def test_reader_open_before_unlink_keeps_bytes(self):
        writer = self.store.writer()
        _, path = self.publish(writer)
        with (path / "body").open("rb") as reader:
            self.store.reap(self.store.retire(writer.identity))
            self.assertEqual(reader.read(), b"image")
        self.assertIsNone(read_entry(path, "key"))

    def test_delayed_copy_from_open_reader_keeps_original_evidence(self):
        writer = self.store.writer()
        _, path = self.publish(writer)
        meta = json.loads((path / "meta").read_text())
        target = self.store.writer()
        op = target.prepare("key", 1234)
        with (path / "body").open("rb") as reader:
            self.store.reap(self.store.retire(writer.identity))
            with (op.stage / "body").open("xb") as output:
                shutil.copyfileobj(reader, output)
        op.write_meta(meta)
        self.assertEqual(read_entry(op.publish(), "key"), (b"image", 1234))

    def test_resumed_writer_cannot_recreate_incarnation(self):
        writer = self.store.writer()
        self.store.reap(self.store.retire(writer.identity))
        with self.assertRaises(FileNotFoundError):
            writer.prepare("key", 1234)
        with self.assertRaises(FileNotFoundError):
            writer.heartbeat()
        replacement = self.store.writer()
        self.assertNotEqual(writer.identity, replacement.identity)
        _, path = self.publish(replacement)
        self.assertEqual(read_entry(path, "key"), (b"image", 1234))

    def test_delayed_resolved_publication_stays_in_retired_tree(self):
        writer = self.store.writer()
        op = writer.prepare("key", 1234)
        op.write_body(b"image")
        op.write_meta()
        # Model an operation already holding directory handles in the kernel.
        stage_fd = os.open(op.stage.parent, os.O_RDONLY)
        target_fd = os.open(op.destination.parent, os.O_RDONLY)
        try:
            retired = self.store.retire(writer.identity)
            os.rename(op.stage.name, op.destination.name,
                      src_dir_fd=stage_fd, dst_dir_fd=target_fd)
            self.assertEqual(self.store.discover("key"), [])
            self.store.reap(retired)
        finally:
            os.close(stage_fd)
            os.close(target_fd)

    def test_overlapping_sweepers_and_uncertain_retirement(self):
        writer = self.store.writer()
        self.publish(writer)
        retired = self.store.retire(writer.identity)
        self.assertEqual(self.store.retire(writer.identity), retired)
        self.store.reap(retired)
        self.store.reap(retired)
        self.assertFalse(writer.path.exists())

    def test_uncertain_publication_checks_exact_destination(self):
        writer = self.store.writer()
        op, path = self.publish(writer)
        self.assertEqual(op.publish(), path)
        self.assertEqual(read_entry(path, "key"), (b"image", 1234))

    def test_corrupt_or_partial_entry_is_never_a_hit(self):
        writer = self.store.writer()
        _, path = self.publish(writer)
        self.assertIsNone(read_entry(path, "other-key"))
        (path / "body").write_bytes(b"wrong")
        self.assertIsNone(read_entry(path, "key"))
        (path / "body").unlink()
        self.assertIsNone(read_entry(path, "key"))

    def test_hard_link_survives_source_reaping_without_copy(self):
        source = self.store.writer()
        _, path = self.publish(source)
        target = self.store.writer()
        op = target.prepare("key", 1234)
        op.adopt_body(path)
        self.assertEqual(os.stat(path / "body").st_ino,
                         os.stat(op.stage / "body").st_ino)
        op.write_meta(json.loads((path / "meta").read_text()))
        self.store.reap(self.store.retire(source.identity))
        self.assertEqual(read_entry(op.publish(), "key"), (b"image", 1234))

    def test_generation_eviction_cannot_delete_replacement(self):
        writer = self.store.writer()
        old, old_path = self.publish(writer, b"old")
        _, new_path = self.publish(writer, b"new")
        retired = self.store.retire_generation(writer.identity, "key", old.generation)
        self.store.reap(retired)
        self.store.reap(self.store.retire_generation(writer.identity, "key", old.generation))
        self.assertIsNone(read_entry(old_path, "key"))
        self.assertEqual(read_entry(new_path, "key"), (b"new", 1234))

    def test_stale_discovery_after_retirement_is_validated_before_hit(self):
        writer = self.store.writer()
        _, path = self.publish(writer)
        candidates = self.store.discover("key")
        self.store.reap(self.store.retire(writer.identity))
        self.assertEqual(candidates, [path])
        self.assertIsNone(read_entry(candidates[0], "key"))

    def test_heartbeat_already_open_does_not_restore_discovery(self):
        writer = self.store.writer()
        with (writer.path / "heartbeat").open("wb") as heartbeat:
            retired = self.store.retire(writer.identity)
            heartbeat.write(b"resumed")
            heartbeat.flush()
            self.assertFalse(writer.path.exists())
            self.store.reap(retired)

    def test_recursive_recreation_would_violate_retirement(self):
        # Negative control for the protocol's no-recreation rule.
        writer = self.store.writer()
        self.store.reap(self.store.retire(writer.identity))
        (writer.path / "staging").mkdir(parents=True)
        (writer.path / "entries").mkdir()
        _, path = self.publish(writer)
        self.assertEqual(self.store.discover("key"), [path])

    def test_failed_reaping_leaves_retryable_retired_tree(self):
        writer = self.store.writer()
        self.publish(writer)
        retired = self.store.retire(writer.identity)
        with patch("protocol.shutil.rmtree", side_effect=PermissionError("busy")):
            with self.assertRaises(PermissionError):
                self.store.reap(retired)
        self.assertTrue(retired.exists())
        self.assertEqual(self.store.discover("key"), [])
        self.store.reap(retired)
        self.assertFalse(retired.exists())

    def test_link_with_lost_reply_can_be_validated_in_staging(self):
        source = self.store.writer()
        _, path = self.publish(source)
        evidence = json.loads((path / "meta").read_text())
        target = self.store.writer()
        op = target.prepare("key", 1234)
        op.adopt_body(path)  # The server completes this but its reply is lost.
        self.store.reap(self.store.retire(source.identity))
        op.write_meta(evidence)
        self.assertEqual(read_entry(op.stage, "key"), (b"image", 1234))
        self.assertEqual(read_entry(op.publish(), "key"), (b"image", 1234))


if __name__ == "__main__":
    unittest.main()
