#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

exec /usr/bin/python3 - "$@" <<'PY'
import argparse
import fcntl
import gzip
import hashlib
import json
import os
import posixpath
import shutil
import stat
import struct
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path

MAX_ENTRIES = 100_000
MAX_FILE = 2 * 1024 * 1024 * 1024
MAX_TOTAL = 10 * 1024 * 1024 * 1024
MAX_RATIO = 1_000
MAX_COMPONENTS = 32
MAX_LEVEL = 3
MAX_CENTRAL_DIRECTORY = 64 * 1024 * 1024
TAR_BLOCK = 512
TAR_EXTENSION_TYPES = {b"x", b"g", b"L", b"K"}
STATE_SAVE_CALLS = 0

class Reject(Exception):
    pass

def fail(category):
    print(category, file=sys.stderr)
    raise SystemExit(1)

def classify(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(512)
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            tail = b""
            if size >= 512:
                handle.seek(-512, os.SEEK_END)
                tail = handle.read(512)
    except OSError:
        fail("UNVERIFIABLE_CONTAINER_READ")
    if head.startswith(b"PK\x03\x04") or head.startswith(b"PK\x05\x06"):
        return "zip"
    if head.startswith(b"\x1f\x8b"):
        return "tar-gzip"
    if head.startswith(b"BZh") or head.startswith(b"\xfd7zXZ\x00"):
        return "unsupported"
    if len(head) >= 265 and head[257:262] == b"ustar":
        return "tar"
    if head.startswith(b"xar!") or tail.endswith(b"koly"):
        return "unsupported"
    return "none"

def precheck_zip(path):
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        tail_size = min(size, 65_557)
        handle.seek(size - tail_size)
        tail = handle.read(tail_size)
        offset = tail.rfind(b"PK\x05\x06")
        if offset < 0 or len(tail) - offset < 22:
            raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
        entries = struct.unpack_from("<H", tail, offset + 10)[0]
        central_size = struct.unpack_from("<I", tail, offset + 12)[0]
        if entries == 0xFFFF or central_size == 0xFFFFFFFF:
            locator = tail.rfind(b"PK\x06\x07", 0, offset)
            if locator < 0 or len(tail) - locator < 20:
                raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
            zip64_offset = struct.unpack_from("<Q", tail, locator + 8)[0]
            handle.seek(zip64_offset)
            record = handle.read(56)
            if len(record) < 56 or not record.startswith(b"PK\x06\x06"):
                raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
            entries = struct.unpack_from("<Q", record, 32)[0]
            central_size = struct.unpack_from("<Q", record, 40)[0]
    if entries > MAX_ENTRIES or central_size > MAX_CENTRAL_DIRECTORY:
        raise Reject("UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT")

def parse_tar_size(field):
    if not field or field[0] & 0x80:
        raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
    stripped = field.rstrip(b"\0 ").lstrip(b" ")
    if not stripped:
        return 0
    if any(byte < ord("0") or byte > ord("7") for byte in stripped):
        raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
    return int(stripped, 8)

def drain_tar_bytes(stream, count):
    remaining = count
    while remaining:
        block = stream.read(min(remaining, 1024 * 1024))
        if not block:
            raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
        remaining -= len(block)

def precheck_tar(path, kind, counters):
    opener = gzip.open if kind == "tar-gzip" else open
    compressed = max(os.path.getsize(path), 1)
    try:
        with opener(path, "rb") as stream:
            entries = 0
            declared_total = 0
            zero_blocks = 0
            while True:
                header = stream.read(TAR_BLOCK)
                if not header:
                    raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
                if len(header) != TAR_BLOCK:
                    raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
                if header == b"\0" * TAR_BLOCK:
                    zero_blocks += 1
                    if zero_blocks == 2:
                        return
                    continue
                zero_blocks = 0
                type_flag = header[156:157]
                if type_flag in TAR_EXTENSION_TYPES:
                    raise Reject("UNVERIFIABLE_ARCHIVE_EXTENDED_METADATA")
                if type_flag not in (b"\0", b"0", b"5"):
                    raise Reject("UNVERIFIABLE_ARCHIVE_SPECIAL_FILE")
                size = parse_tar_size(header[124:136])
                entries += 1
                if entries + counters[0] > MAX_ENTRIES:
                    raise Reject("UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT")
                if type_flag == b"5" and size != 0:
                    raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
                if type_flag != b"5":
                    if size > MAX_FILE:
                        raise Reject("UNVERIFIABLE_ARCHIVE_FILE_LIMIT")
                    declared_total += size
                    if declared_total + counters[1] > MAX_TOTAL:
                        raise Reject("UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT")
                    if declared_total > compressed * MAX_RATIO:
                        raise Reject("UNVERIFIABLE_ARCHIVE_RATIO")
                padded = ((size + TAR_BLOCK - 1) // TAR_BLOCK) * TAR_BLOCK
                drain_tar_bytes(stream, padded)
    except Reject:
        raise
    except (OSError, EOFError, gzip.BadGzipFile):
        raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")

def register_inventory_path(seen, name, is_dir):
    inserted = 0
    parts = name.split("/")
    for index in range(1, len(parts)):
        parent = "/".join(parts[:index])
        folded = parent.casefold()
        prior = seen.get(folded)
        if prior is None:
            seen[folded] = [parent, True, False]
            inserted += 1
        elif prior[0] != parent or not prior[1]:
            raise Reject("UNVERIFIABLE_ARCHIVE_COLLISION")
    folded = name.casefold()
    prior = seen.get(folded)
    if prior is None:
        seen[folded] = [name, is_dir, True]
        return inserted + 1
    if prior[0] != name or prior[1] != is_dir or prior[2]:
        raise Reject("UNVERIFIABLE_ARCHIVE_COLLISION")
    prior[2] = True
    return inserted

def normalize(name):
    if not name or "\\" in name or name.startswith("/"):
        raise Reject("UNVERIFIABLE_ARCHIVE_PATH")
    normalized = posixpath.normpath(name)
    if normalized in ("", "."):
        return None
    if normalized == ".." or normalized.startswith("../"):
        raise Reject("UNVERIFIABLE_ARCHIVE_PATH")
    parts = [part for part in normalized.split("/") if part]
    if len(parts) > MAX_COMPONENTS:
        raise Reject("UNVERIFIABLE_ARCHIVE_PATH_DEPTH")
    if any(part in (".", "..", "") for part in parts):
        raise Reject("UNVERIFIABLE_ARCHIVE_PATH")
    return "/".join(parts)

def inventory(path, counters):
    kind = classify(path)
    if kind == "unsupported" or kind == "none":
        raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
    rows = []
    seen = {}
    total = 0
    compressed = max(os.path.getsize(path), 1)
    if kind == "zip":
        precheck_zip(path)
        try:
            archive = zipfile.ZipFile(path)
        except (OSError, zipfile.BadZipFile):
            raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
        with archive:
            for member in archive.infolist():
                name = normalize(member.filename)
                if name is None:
                    continue
                mode = member.external_attr >> 16
                if member.flag_bits & 1:
                    raise Reject("UNVERIFIABLE_ARCHIVE_ENCRYPTED")
                file_type = stat.S_IFMT(mode)
                if stat.S_ISLNK(mode) or (file_type and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode))):
                    raise Reject("UNVERIFIABLE_ARCHIVE_SPECIAL_FILE")
                is_dir = member.is_dir()
                register_inventory_path(seen, name, is_dir)
                if len(seen) + counters[0] > MAX_ENTRIES:
                    raise Reject("UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT")
                size = 0 if is_dir else member.file_size
                ratio_base = max(member.compress_size, 1)
                if size > MAX_FILE:
                    raise Reject("UNVERIFIABLE_ARCHIVE_FILE_LIMIT")
                if size > ratio_base * MAX_RATIO:
                    raise Reject("UNVERIFIABLE_ARCHIVE_RATIO")
                total += size
                if total + counters[1] > MAX_TOTAL:
                    raise Reject("UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT")
                rows.append((name, is_dir, size, member.filename))
    else:
        precheck_tar(path, kind, counters)
        tar_mode = "r|gz" if kind == "tar-gzip" else "r|"
        try:
            archive = tarfile.open(path, tar_mode)
        except (OSError, tarfile.TarError):
            raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
        with archive:
            for member in archive:
                name = normalize(member.name)
                if name is None:
                    continue
                if getattr(member, "sparse", None):
                    raise Reject("UNVERIFIABLE_ARCHIVE_SPECIAL_FILE")
                if not (member.isdir() or member.isreg()):
                    raise Reject("UNVERIFIABLE_ARCHIVE_SPECIAL_FILE")
                register_inventory_path(seen, name, member.isdir())
                if len(seen) + counters[0] > MAX_ENTRIES:
                    raise Reject("UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT")
                size = 0 if member.isdir() else member.size
                if size > MAX_FILE:
                    raise Reject("UNVERIFIABLE_ARCHIVE_FILE_LIMIT")
                total += size
                if total + counters[1] > MAX_TOTAL:
                    raise Reject("UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT")
                rows.append((name, member.isdir(), size, member.name))
        if total > compressed * MAX_RATIO:
            raise Reject("UNVERIFIABLE_ARCHIVE_RATIO")
    counters[0] += len(seen)
    counters[1] += total
    return kind, rows, total, seen

def copy_archive(path, kind, rows, target):
    if kind == "zip":
        with zipfile.ZipFile(path) as archive:
            by_name = {member.filename: member for member in archive.infolist()}
            for name, is_dir, expected, member_name in rows:
                member = by_name.get(member_name)
                if member is None:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
                destination = target / name
                if is_dir:
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, open(destination, "xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                if destination.stat().st_size != expected:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
    else:
        tar_mode = "r|gz" if kind == "tar-gzip" else "r|"
        with tarfile.open(path, tar_mode) as archive:
            row_iterator = iter(rows)
            expected_row = next(row_iterator, None)
            for member in archive:
                member_name = normalize(member.name)
                if member_name is None:
                    continue
                if expected_row is None:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
                name, is_dir, expected, original_name = expected_row
                if member.name != original_name or member_name != name:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
                destination = target / name
                if is_dir:
                    destination.mkdir(parents=True, exist_ok=True)
                    expected_row = next(row_iterator, None)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
                with source, open(destination, "xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                if destination.stat().st_size != expected:
                    raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
                expected_row = next(row_iterator, None)
            if expected_row is not None:
                raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")

def validate_tree(target, rows, seen):
    expected = {name: (is_dir, size) for name, is_dir, size, _ in rows}
    for name, _, _, _ in rows:
        parts = name.split("/")[:-1]
        for index in range(1, len(parts) + 1):
            expected.setdefault("/".join(parts[:index]), (True, 0))
    if len(expected) != len(seen):
        raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
    actual = {}
    for root, directories, files in os.walk(target, followlinks=False):
        for name in directories + files:
            path = Path(root) / name
            if path.is_symlink():
                raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")
            relative = path.relative_to(target).as_posix()
            actual[relative] = (path.is_dir(), 0 if path.is_dir() else path.stat().st_size)
    if actual != expected:
        raise Reject("UNVERIFIABLE_EXTRACTION_MISMATCH")

def append_registry(registry, payload_root, target):
    registry.parent.mkdir(parents=True, exist_ok=True)
    if registry.is_symlink() or (registry.exists() and not registry.is_file()):
        raise Reject("UNVERIFIABLE_EXTRACTION_REGISTRY")
    old = registry.read_bytes() if registry.exists() else b""
    if old and not old.endswith(b"\0"):
        raise Reject("UNVERIFIABLE_EXTRACTION_REGISTRY")
    canonical = str(target.resolve()).encode()
    prefix = (str(payload_root.resolve()) + os.sep).encode()
    if not canonical.startswith(prefix) or b"\0" in canonical:
        raise Reject("UNVERIFIABLE_EXTRACTION_REGISTRY")
    fd, temporary = tempfile.mkstemp(prefix=registry.name + ".", dir=str(registry.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(old)
            handle.write(canonical + b"\0")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, registry)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise Reject("UNVERIFIABLE_EXTRACTION_REGISTRY")

def extract_recursive(asset, payload_root, registry, identifier, level, counters,
                      reserve_counters):
    if level > MAX_LEVEL:
        raise Reject("UNVERIFIABLE_ARCHIVE_DEPTH")
    kind, rows, _, seen = inventory(asset, counters)
    reserve_counters(counters)
    target = payload_root / identifier
    if target.exists():
        raise Reject("UNVERIFIABLE_EXTRACTION_DESTINATION")
    target.mkdir(mode=0o700)
    copy_archive(asset, kind, rows, target)
    validate_tree(target, rows, seen)
    append_registry(registry, payload_root, target)
    count = 1
    nested = []
    for root, _, files in os.walk(target):
        for name in files:
            candidate = Path(root) / name
            nested_kind = classify(candidate)
            if nested_kind in ("zip", "tar", "tar-gzip", "unsupported"):
                if nested_kind == "unsupported":
                    raise Reject("UNVERIFIABLE_CONTAINER_FORMAT")
                if level >= MAX_LEVEL:
                    raise Reject("UNVERIFIABLE_ARCHIVE_DEPTH")
                nested.append(candidate)
    for candidate in nested:
        digest_state = hashlib.sha256()
        with open(candidate, "rb") as nested_input:
            while True:
                block = nested_input.read(1024 * 1024)
                if not block:
                    break
                digest_state.update(block)
        digest = digest_state.hexdigest()[:24]
        count += extract_recursive(candidate, payload_root, registry,
                                   "nested-" + digest, level + 1, counters,
                                   reserve_counters)
    return count

def load_state(state):
    if state.is_symlink() or (state.exists() and not state.is_file()):
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    if not state.exists():
        return [0, 0]
    try:
        value = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    if (not isinstance(value, dict) or set(value) != {"entries", "bytes"}
            or isinstance(value["entries"], bool)
            or isinstance(value["bytes"], bool)
            or not isinstance(value["entries"], int)
            or not isinstance(value["bytes"], int)
            or not 0 <= value["entries"] <= MAX_ENTRIES
            or not 0 <= value["bytes"] <= MAX_TOTAL):
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    return [value["entries"], value["bytes"]]

def save_state(state, counters):
    global STATE_SAVE_CALLS
    STATE_SAVE_CALLS += 1
    fail_at = os.environ.get("GT_TEST_SAFE_EXTRACT_FAIL_STATE_WRITE_AT")
    if fail_at is not None:
        if not fail_at.isdigit() or int(fail_at) < 1:
            raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
        if STATE_SAVE_CALLS == int(fail_at):
            raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    state.parent.mkdir(parents=True, exist_ok=True)
    if state.is_symlink() or (state.exists() and not state.is_file()):
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    fd, temporary = tempfile.mkstemp(prefix=state.name + ".", dir=str(state.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({"entries": counters[0], "bytes": counters[1]},
                      handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, state)
        directory_fd = os.open(state.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")

def locked_state(state):
    state.parent.mkdir(parents=True, exist_ok=True)
    lock = Path(str(state) + ".lock")
    if lock.is_symlink() or (lock.exists() and not lock.is_file()):
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock, flags, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
    except OSError:
        raise Reject("UNVERIFIABLE_EXTRACTION_STATE")
    return descriptor

raw_arguments = sys.argv[1:]
if not raw_arguments or raw_arguments[0] not in ("--list", "--extract"):
    fail("UNVERIFIABLE_EXTRACTION_ARGUMENTS")
mode = raw_arguments.pop(0)
parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("asset")
parser.add_argument("--payload-root")
parser.add_argument("--registry")
parser.add_argument("--state")
parser.add_argument("--id")
parser.add_argument("--level", type=int, default=1)
args = parser.parse_args(raw_arguments)
asset = Path(args.asset)
if not asset.is_file() or asset.is_symlink():
    fail("UNVERIFIABLE_CONTAINER_FORMAT")
try:
    if mode == "--list":
        counters = [0, 0]
        kind, rows, total, _ = inventory(asset, counters)
        print(f"SAFE_ARCHIVE_LIST:{kind}:{len(rows)}:{total}")
    else:
        if not args.payload_root or not args.registry or not args.state or not args.id:
            fail("UNVERIFIABLE_EXTRACTION_ARGUMENTS")
        if (args.id in (".", "..") or not args.id
                or not all(character.isalnum() or character in "._-" for character in args.id)
                or not 1 <= args.level <= MAX_LEVEL):
            fail("UNVERIFIABLE_EXTRACTION_ARGUMENTS")
        payload_root = Path(args.payload_root)
        registry = Path(args.registry)
        state = Path(args.state)
        if not payload_root.is_dir() or payload_root.is_symlink():
            fail("UNVERIFIABLE_EXTRACTION_ARGUMENTS")
        lock_descriptor = locked_state(state)
        try:
            counters = load_state(state)
            def reserve_counters(current):
                save_state(state, current)
            count = extract_recursive(asset, payload_root, registry, args.id,
                                      args.level, counters, reserve_counters)
        finally:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            os.close(lock_descriptor)
        print(f"SAFE_EXTRACTION_REGISTERED:{count}")
except Reject as error:
    fail(str(error))
except (OSError, ValueError, zipfile.BadZipFile, tarfile.TarError):
    fail("UNVERIFIABLE_EXTRACTION_OPERATION")
PY
