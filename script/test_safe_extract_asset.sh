#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
extractor="$workspace_root/script/safe_extract_asset.sh"
fixture_root="$(mktemp -d)"
cleanup() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  /bin/rm -rf "$fixture_root" >/dev/null 2>&1 || true
  exit "$prior_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

test -x "$extractor"

/usr/bin/python3 - "$fixture_root" <<'PY'
import gzip, io, os, stat, struct, sys, tarfile, warnings, zipfile
root = sys.argv[1]
warnings.filterwarnings("ignore", message="Duplicate name:.*", category=UserWarning)
def zip_rows(name, rows):
    with zipfile.ZipFile(os.path.join(root, name), "w", zipfile.ZIP_DEFLATED) as archive:
        for path, value in rows:
            archive.writestr(path, value)
zip_rows("safe.zip", [("folder/value.txt", b"public")])
with tarfile.open(os.path.join(root, "safe.tar"), "w") as archive:
    value = b"public tar"
    info = tarfile.TarInfo("folder/value.txt")
    info.size = len(value)
    archive.addfile(info, io.BytesIO(value))
with tarfile.open(os.path.join(root, "safe.tar.gz"), "w:gz") as archive:
    value = b"public gzip"
    info = tarfile.TarInfo("folder/value.txt")
    info.size = len(value)
    archive.addfile(info, io.BytesIO(value))
def forged_gzip_tar(name, declared_size):
    header = bytearray(open(os.path.join(root, "safe.tar"), "rb").read(512))
    header[124:136] = ("%011o\0" % declared_size).encode("ascii")
    header[148:156] = b"        "
    header[148:156] = ("%06o\0 " % sum(header)).encode("ascii")
    with gzip.open(os.path.join(root, name), "wb") as output:
        output.write(header)
forged_gzip_tar("ratio-before-drain.tar.gz", 1_000_000)
forged_gzip_tar("total-before-drain.tar.gz", 11)
with tarfile.open(os.path.join(root, "unsupported.tar.bz2"), "w:bz2") as archive:
    value = b"bzip"
    info = tarfile.TarInfo("value.txt")
    info.size = len(value)
    archive.addfile(info, io.BytesIO(value))
with tarfile.open(os.path.join(root, "unsupported.tar.xz"), "w:xz") as archive:
    value = b"xz"
    info = tarfile.TarInfo("value.txt")
    info.size = len(value)
    archive.addfile(info, io.BytesIO(value))
zip_rows("traversal.zip", [("../escape.txt", b"bad")])
zip_rows("absolute.zip", [("/escape.txt", b"bad")])
zip_rows("backslash.zip", [("folder\\escape.txt", b"bad")])
zip_rows("duplicate.zip", [("same.txt", b"a"), ("same.txt", b"b")])
zip_rows("collision.zip", [("A.txt", b"a"), ("a.txt", b"b")])
zip_rows("deep.zip", [("/".join(["x"] * 33) + "/value.txt", b"bad")])
zip_rows("bomb.zip", [("large.txt", b"A" * 2_000_000)])
zip_rows("encrypted.zip", [("value.txt", b"value")])
encrypted_path = os.path.join(root, "encrypted.zip")
encrypted = bytearray(open(encrypted_path, "rb").read())
central = encrypted.index(b"PK\x01\x02")
flags = struct.unpack_from("<H", encrypted, central + 8)[0]
struct.pack_into("<H", encrypted, central + 8, flags | 1)
open(encrypted_path, "wb").write(encrypted)
zip_rows("file-limit.zip", [("large.bin", b"x")])
file_limit_path = os.path.join(root, "file-limit.zip")
file_limit = bytearray(open(file_limit_path, "rb").read())
central = file_limit.index(b"PK\x01\x02")
struct.pack_into("<I", file_limit, central + 20, 2_147_483_649)
struct.pack_into("<I", file_limit, central + 24, 2_147_483_649)
open(file_limit_path, "wb").write(file_limit)
zip_rows("total-limit.zip", [(f"file-{index}.bin", b"x") for index in range(6)])
total_limit_path = os.path.join(root, "total-limit.zip")
total_limit = bytearray(open(total_limit_path, "rb").read())
position = 0
while True:
    try:
        central = total_limit.index(b"PK\x01\x02", position)
    except ValueError:
        break
    struct.pack_into("<I", total_limit, central + 20, 2_147_483_648)
    struct.pack_into("<I", total_limit, central + 24, 2_147_483_648)
    position = central + 4
open(total_limit_path, "wb").write(total_limit)
with zipfile.ZipFile(os.path.join(root, "entry-limit.zip"), "w", zipfile.ZIP_STORED) as archive:
    for index in range(100_001):
        archive.writestr(f"entry-{index}", b"")
with zipfile.ZipFile(os.path.join(root, "implicit-entry-limit.zip"), "w", zipfile.ZIP_STORED) as archive:
    for index in range(50_001):
        archive.writestr(f"directory-{index}/value", b"")
with zipfile.ZipFile(os.path.join(root, "symlink.zip"), "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, "target")
with tarfile.open(os.path.join(root, "hardlink.tar"), "w") as archive:
    info = tarfile.TarInfo("link")
    info.type = tarfile.LNKTYPE
    info.linkname = "target"
    archive.addfile(info)
with tarfile.open(os.path.join(root, "device.tar"), "w") as archive:
    info = tarfile.TarInfo("device")
    info.type = tarfile.CHRTYPE
    archive.addfile(info)
with tarfile.open(os.path.join(root, "fifo.tar"), "w") as archive:
    info = tarfile.TarInfo("fifo")
    info.type = tarfile.FIFOTYPE
    archive.addfile(info)
with tarfile.open(os.path.join(root, "socket.tar"), "w") as archive:
    info = tarfile.TarInfo("socket")
    info.type = b"s"
    archive.addfile(info)
with tarfile.open(os.path.join(root, "sparse.tar"), "w") as archive:
    info = tarfile.TarInfo("sparse")
    info.type = tarfile.GNUTYPE_SPARSE
    archive.addfile(info)
with tarfile.open(os.path.join(root, "pax.tar"), "w", format=tarfile.PAX_FORMAT) as archive:
    value = b"pax"
    info = tarfile.TarInfo("long-" + "x" * 120)
    info.size = len(value)
    archive.addfile(info, io.BytesIO(value))
pax_path = os.path.join(root, "pax.tar")
pax_huge = bytearray(open(pax_path, "rb").read())
assert pax_huge[156:157] == tarfile.XHDTYPE
pax_huge[124:136] = ("%011o\0" % 2_147_483_649).encode("ascii")
pax_huge[148:156] = b"        "
pax_huge[148:156] = ("%06o\0 " % sum(pax_huge[:512])).encode("ascii")
open(os.path.join(root, "pax-huge.tar"), "wb").write(pax_huge)
zip_rows("nested-4.zip", [("value.txt", b"level4")])
with open(os.path.join(root, "nested-4.zip"), "rb") as handle:
    level4 = handle.read()
zip_rows("nested-3.zip", [("nested.zip", level4)])
with open(os.path.join(root, "nested-3.zip"), "rb") as handle:
    level3 = handle.read()
zip_rows("nested-2.zip", [("nested.zip", level3)])
with open(os.path.join(root, "nested-2.zip"), "rb") as handle:
    level2 = handle.read()
zip_rows("nested-1.zip", [("nested.zip", level2)])
zip_rows("nested-unsupported.zip", [("unsupported.pkg", b"xar!synthetic")])
with zipfile.ZipFile(os.path.join(root, "state-save-failure.zip"), "w", zipfile.ZIP_STORED) as archive:
    archive.writestr("nested.zip", open(os.path.join(root, "safe.zip"), "rb").read())
with open(os.path.join(root, "unsupported.pkg"), "wb") as handle:
    handle.write(b"xar!synthetic")
with open(os.path.join(root, "unsupported.dmg"), "wb") as handle:
    handle.write(b"synthetic" + b"\0" * 504 + b"koly")
PY

"$extractor" --list "$fixture_root/safe.zip" | rg -q '^SAFE_ARCHIVE_LIST:zip:'
"$extractor" --list "$fixture_root/safe.tar" | rg -q '^SAFE_ARCHIVE_LIST:tar:'
"$extractor" --list "$fixture_root/safe.tar.gz" | rg -q '^SAFE_ARCHIVE_LIST:tar-gzip:'

payload="$fixture_root/payload"
registry="$fixture_root/registry.nul"
state="$fixture_root/state.json"
/bin/mkdir -p "$payload"
: > "$registry"
"$extractor" --extract "$fixture_root/safe.zip" \
  --payload-root "$payload" --registry "$registry" --state "$state" --id safe \
  | rg -q '^SAFE_EXTRACTION_REGISTERED:1$'
test "$(/bin/cat "$payload/safe/folder/value.txt")" = public
"$extractor" --extract "$fixture_root/safe.tar" \
  --payload-root "$payload" --registry "$registry" --state "$state" --id safe-tar \
  | rg -q '^SAFE_EXTRACTION_REGISTERED:1$'
test "$(/bin/cat "$payload/safe-tar/folder/value.txt")" = 'public tar'
"$extractor" --extract "$fixture_root/safe.tar.gz" \
  --payload-root "$payload" --registry "$registry" --state "$state" --id safe-gzip \
  | rg -q '^SAFE_EXTRACTION_REGISTERED:1$'
test "$(/bin/cat "$payload/safe-gzip/folder/value.txt")" = 'public gzip'
test "$(/usr/bin/tr -cd '\000' < "$registry" | wc -c | /usr/bin/xargs)" -eq 3
/usr/bin/python3 - "$state" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state == {"entries": 6, "bytes": 27}, state
PY
/usr/bin/python3 - "$registry" "$payload" <<'PY'
import os, sys
registry, payload = sys.argv[1:]
rows = open(registry, "rb").read().split(b"\0")
assert rows[-1] == b""
actual = [os.fsdecode(row) for row in rows[:-1]]
expected = [os.path.realpath(os.path.join(payload, name)) for name in ("safe", "safe-tar", "safe-gzip")]
assert actual == expected, (actual, expected)
PY

assert_rejected() {
  name="$1"
  expected="$2"
  shift 2
  probe_status=0
  "$extractor" "$@" > "$fixture_root/$name.stdout" \
    2> "$fixture_root/$name.stderr" || probe_status=$?
  test "$probe_status" -ne 0
  test "$(/bin/cat "$fixture_root/$name.stderr")" = "$expected"
  test ! -s "$fixture_root/$name.stdout"
}

assert_rejected traversal UNVERIFIABLE_ARCHIVE_PATH \
  --list "$fixture_root/traversal.zip"
assert_rejected absolute UNVERIFIABLE_ARCHIVE_PATH \
  --list "$fixture_root/absolute.zip"
assert_rejected backslash UNVERIFIABLE_ARCHIVE_PATH \
  --list "$fixture_root/backslash.zip"
assert_rejected duplicate UNVERIFIABLE_ARCHIVE_COLLISION \
  --list "$fixture_root/duplicate.zip"
assert_rejected collision UNVERIFIABLE_ARCHIVE_COLLISION \
  --list "$fixture_root/collision.zip"
assert_rejected depth UNVERIFIABLE_ARCHIVE_PATH_DEPTH \
  --list "$fixture_root/deep.zip"
assert_rejected ratio UNVERIFIABLE_ARCHIVE_RATIO \
  --list "$fixture_root/bomb.zip"
assert_rejected gzip-ratio-before-drain UNVERIFIABLE_ARCHIVE_RATIO \
  --list "$fixture_root/ratio-before-drain.tar.gz"
assert_rejected encrypted UNVERIFIABLE_ARCHIVE_ENCRYPTED \
  --list "$fixture_root/encrypted.zip"
assert_rejected file-limit UNVERIFIABLE_ARCHIVE_FILE_LIMIT \
  --list "$fixture_root/file-limit.zip"
assert_rejected total-limit UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT \
  --list "$fixture_root/total-limit.zip"
assert_rejected entry-limit UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT \
  --list "$fixture_root/entry-limit.zip"
assert_rejected implicit-entry-limit UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT \
  --list "$fixture_root/implicit-entry-limit.zip"
assert_rejected symlink UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/symlink.zip"
assert_rejected hardlink UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/hardlink.tar"
assert_rejected device UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/device.tar"
assert_rejected fifo UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/fifo.tar"
assert_rejected socket UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/socket.tar"
assert_rejected sparse UNVERIFIABLE_ARCHIVE_SPECIAL_FILE \
  --list "$fixture_root/sparse.tar"
assert_rejected pax UNVERIFIABLE_ARCHIVE_EXTENDED_METADATA \
  --list "$fixture_root/pax.tar"
assert_rejected pax-huge UNVERIFIABLE_ARCHIVE_EXTENDED_METADATA \
  --list "$fixture_root/pax-huge.tar"
assert_rejected unsupported UNVERIFIABLE_CONTAINER_FORMAT \
  --list "$fixture_root/unsupported.pkg"
assert_rejected unsupported-dmg UNVERIFIABLE_CONTAINER_FORMAT \
  --list "$fixture_root/unsupported.dmg"
assert_rejected unsupported-bzip2 UNVERIFIABLE_CONTAINER_FORMAT \
  --list "$fixture_root/unsupported.tar.bz2"
assert_rejected unsupported-xz UNVERIFIABLE_CONTAINER_FORMAT \
  --list "$fixture_root/unsupported.tar.xz"

limit_payload="$fixture_root/limit-payload"
limit_registry="$fixture_root/limit-registry.nul"
/bin/mkdir -p "$limit_payload"
: > "$limit_registry"
printf '%s\n' '{"entries":100000,"bytes":0}' > "$fixture_root/entry-state.json"
assert_rejected cumulative-entry-limit UNVERIFIABLE_ARCHIVE_ENTRY_LIMIT \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$limit_registry" --state "$fixture_root/entry-state.json" --id entries
printf '%s\n' '{"entries":0,"bytes":10737418240}' > "$fixture_root/byte-state.json"
assert_rejected cumulative-byte-limit UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$limit_registry" --state "$fixture_root/byte-state.json" --id bytes
printf '%s\n' '{"entries":0,"bytes":10737418230}' > "$fixture_root/tar-byte-state.json"
assert_rejected gzip-total-before-drain UNVERIFIABLE_ARCHIVE_TOTAL_LIMIT \
  --extract "$fixture_root/total-before-drain.tar.gz" \
  --payload-root "$limit_payload" --registry "$limit_registry" \
  --state "$fixture_root/tar-byte-state.json" --id tar-bytes
printf '%s\n' '{"entries":false,"bytes":0}' > "$fixture_root/bad-state.json"
assert_rejected malformed-state UNVERIFIABLE_EXTRACTION_STATE \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$limit_registry" --state "$fixture_root/bad-state.json" --id bad-state
/bin/ln -s "$fixture_root/state.json" "$fixture_root/link-state.json"
assert_rejected symlink-state UNVERIFIABLE_EXTRACTION_STATE \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$limit_registry" --state "$fixture_root/link-state.json" --id link-state
/bin/ln -s "$registry" "$fixture_root/link-registry.nul"
assert_rejected symlink-registry UNVERIFIABLE_EXTRACTION_REGISTRY \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$fixture_root/link-registry.nul" --state "$fixture_root/registry-state.json" \
  --id link-registry
printf '%s' malformed > "$fixture_root/malformed-registry.nul"
assert_rejected malformed-registry UNVERIFIABLE_EXTRACTION_REGISTRY \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$fixture_root/malformed-registry.nul" \
  --state "$fixture_root/malformed-registry-state.json" --id malformed-registry
assert_rejected invalid-id UNVERIFIABLE_EXTRACTION_ARGUMENTS \
  --extract "$fixture_root/safe.zip" --payload-root "$limit_payload" \
  --registry "$limit_registry" --state "$fixture_root/id-state.json" --id ..

nested_payload="$fixture_root/nested-payload"
nested_registry="$fixture_root/nested-registry.nul"
/bin/mkdir -p "$nested_payload"
: > "$nested_registry"
assert_rejected fourth-level UNVERIFIABLE_ARCHIVE_DEPTH \
  --extract "$fixture_root/nested-1.zip" --payload-root "$nested_payload" \
  --registry "$nested_registry" --state "$fixture_root/nested-state.json" --id top

failed_payload="$fixture_root/failed-payload"
failed_registry="$fixture_root/failed-registry.nul"
failed_state="$fixture_root/failed-state.json"
/bin/mkdir -p "$failed_payload"
: > "$failed_registry"
assert_rejected nested-unsupported UNVERIFIABLE_CONTAINER_FORMAT \
  --extract "$fixture_root/nested-unsupported.zip" --payload-root "$failed_payload" \
  --registry "$failed_registry" --state "$failed_state" --id retained
test "$(/usr/bin/tr -cd '\000' < "$failed_registry" | wc -c | /usr/bin/xargs)" -eq 1
/usr/bin/python3 - "$failed_state" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state == {"entries": 1, "bytes": 13}, state
PY
"$extractor" --extract "$fixture_root/safe.zip" --payload-root "$failed_payload" \
  --registry "$failed_registry" --state "$failed_state" --id after-failure \
  | rg -q '^SAFE_EXTRACTION_REGISTERED:1$'
/usr/bin/python3 - "$failed_state" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle)
assert state == {"entries": 3, "bytes": 19}, state
PY

state_failure_payload="$fixture_root/state-failure-payload"
state_failure_registry="$fixture_root/state-failure-registry.nul"
state_failure_parent="$fixture_root/state-failure-parent"
state_failure_state="$state_failure_parent/state.json"
/bin/mkdir -p "$state_failure_payload" "$state_failure_parent"
: > "$state_failure_registry"
GT_TEST_SAFE_EXTRACT_FAIL_STATE_WRITE_AT=2 \
  assert_rejected state-save-failure UNVERIFIABLE_EXTRACTION_STATE \
  --extract "$fixture_root/state-save-failure.zip" \
  --payload-root "$state_failure_payload" --registry "$state_failure_registry" \
  --state "$state_failure_state" --id retained-before-state-failure
test "$(/usr/bin/tr -cd '\000' < "$state_failure_registry" | wc -c | /usr/bin/xargs)" -eq 1
/usr/bin/python3 - "$state_failure_state" "$fixture_root/state-save-failure.zip" <<'PY'
import json, sys, zipfile
state_path, archive_path = sys.argv[1:]
with open(state_path, encoding="utf-8") as handle:
    state = json.load(handle)
with zipfile.ZipFile(archive_path) as archive:
    expected_bytes = sum(item.file_size for item in archive.infolist())
assert state == {"entries": 1, "bytes": expected_bytes}, state
PY

printf '%s\n' SAFE_EXTRACT_ASSET_TESTS_PASSED
