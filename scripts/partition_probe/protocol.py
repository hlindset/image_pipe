"""Filesystem protocol spike. Private disposable roots only; no production API.

Each method is a scheduling boundary. Tests interleave writers, readers and
cleaners at these boundaries and inject already-resolved operations explicitly.
No locks, background threads, freshness decisions or admission policy live here.
"""

import hashlib
import json
import os
import shutil
import uuid


MAX_BODY = 1024 * 1024
MAX_META = 4096


def read_entry(path, key):
    """Acquire bytes before returning a hit; preserve evidence unchanged."""
    try:
        with (path / "meta").open("rb") as stream:
            meta = json.loads(stream.read(MAX_META + 1))
        with (path / "body").open("rb") as stream:
            body = stream.read(MAX_BODY + 1)
        if (meta["key"] == key and meta["generation"] == path.name
                and len(body) <= MAX_BODY and meta["size"] == len(body)
                and meta["digest"] == hashlib.sha256(body).hexdigest()):
            return body, meta["deadline"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


class Store:
    def __init__(self, root):
        self.active = root / "partitions"
        self.trash = root / "trash"
        self.active.mkdir()
        self.trash.mkdir()

    def writer(self):
        return Writer(self)

    def retire(self, identity):
        source = self.active / identity
        destination = self.trash / identity
        try:
            os.rename(source, destination)
        except FileNotFoundError:
            # Another cleaner may already have retired/reaped this exact ID.
            pass
        return destination

    def retire_generation(self, identity, key, generation):
        source = self.active / identity / "entries" / key / generation
        destination = self.trash / f"entry-{identity}-{generation}"
        try:
            os.rename(source, destination)
        except FileNotFoundError:
            pass
        return destination

    def reap(self, path):
        # Never recurse over a discoverable partition. Failed work is retryable.
        if path.parent != self.trash:
            raise ValueError("only retired paths may be reaped")
        try:
            shutil.rmtree(path)
        except FileNotFoundError:
            pass

    def discover(self, key):
        return sorted(self.active.glob(f"*/entries/{key}/*"))


class Writer:
    def __init__(self, store):
        self.identity = uuid.uuid4().hex
        self.path = store.active / self.identity
        # The sole creation of the incarnation root. Never mkdir -p beneath it.
        self.path.mkdir()
        (self.path / "staging").mkdir()
        (self.path / "entries").mkdir()
        self.heartbeat()

    def heartbeat(self):
        (self.path / "heartbeat").write_bytes(b"alive")

    def prepare(self, key, deadline):
        # Keys in this probe are test constants; production uses digested keys.
        parent = self.path / "entries" / key
        parent.mkdir(exist_ok=True)
        return Publication(self.path / "staging", parent, key, deadline)


class Publication:
    def __init__(self, staging, destination, key, deadline):
        self.generation = uuid.uuid4().hex
        self.stage = staging / self.generation
        self.stage.mkdir()
        self.destination = destination / self.generation
        self.key = key
        self.deadline = deadline

    def write_body(self, body):
        with (self.stage / "body").open("xb") as stream:
            stream.write(body)

    def adopt_body(self, source, copy=False):
        if copy:
            with (source / "body").open("rb") as reader:
                with (self.stage / "body").open("xb") as writer:
                    shutil.copyfileobj(reader, writer)
        else:
            os.link(source / "body", self.stage / "body")

    def write_meta(self, evidence=None):
        body = (self.stage / "body").read_bytes()
        meta = dict(evidence) if evidence is not None else {
            "key": self.key, "deadline": self.deadline,
            "size": len(body), "digest": hashlib.sha256(body).hexdigest(),
        }
        meta["generation"] = self.generation
        with (self.stage / "meta").open("x") as stream:
            json.dump(meta, stream)

    def publish(self):
        if not self.stage.exists():
            if read_entry(self.destination, self.key) is not None:
                return self.destination
            raise FileNotFoundError(self.stage)
        # Both files are closed; cleaners cannot unlink staging in an active tree.
        os.rename(self.stage, self.destination)
        return self.destination
