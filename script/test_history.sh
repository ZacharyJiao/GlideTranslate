#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap '/bin/rm -rf "$fixture_root"' EXIT

new_repo() {
  repo="$1"
  /bin/mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Synthetic Test Identity'
  git -C "$repo" config user.email '1+synthetic@users.noreply.github.com'
  printf '%s\n' public > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m 'Accepted synthetic source'
}

assert_history_rejected() {
  case_name="$1"; expected="$2"; creator="$3"
  repo="$fixture_root/$case_name"
  new_repo "$repo"
  "$creator" "$repo"
  history_status=0
  "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
  test "$history_status" -eq 1
  rg -q "^${expected}:[0-9a-f]{40}" "$repo.out"
  ! rg -q 'synthetic-private-value' "$repo.out"
}

commit_all() { git -C "$1" add -A; git -C "$1" commit -q -m "${2:-Synthetic rejected row}"; }
make_nested_env() { /bin/mkdir -p "$1/config"; printf '%s\n' private > "$1/config/.env"; commit_all "$1"; }
make_local_path() { /bin/mkdir -p "$1/.codex"; printf '%s\n' private > "$1/.codex/state"; commit_all "$1"; }
make_extension() { /bin/mkdir -p "$1/data"; printf '%s\n' private > "$1/data/history.sqlite"; commit_all "$1"; }
make_oversized() { /usr/sbin/mkfile 10485761 "$1/large.bin"; commit_all "$1"; }
make_symlink() { /bin/ln -s target "$1/link"; commit_all "$1"; }
make_bad_identity() { git -C "$1" config user.email 'synthetic@example.invalid'; printf '%s\n' change >> "$1/README.md"; commit_all "$1"; }
make_bad_message() { value='Reference /'"Users/synthetic-private-value/project"; printf '%s\n' change >> "$1/README.md"; commit_all "$1" "$value"; }
make_content() { value='/'"Users/synthetic-private-value/project"; printf '%s\n' "$value" > "$1/payload.txt"; commit_all "$1"; }
make_deleted_content() { make_content "$1"; /bin/rm "$1/payload.txt"; commit_all "$1" 'Delete rejected row from HEAD'; }

assert_history_rejected nested-env HISTORY_PROHIBITED_EXTENSION make_nested_env
assert_history_rejected local-path HISTORY_PROHIBITED_PATH make_local_path
assert_history_rejected extension HISTORY_PROHIBITED_EXTENSION make_extension
assert_history_rejected oversized HISTORY_OVERSIZED_BLOB make_oversized
assert_history_rejected symlink HISTORY_PROHIBITED_SYMLINK make_symlink
assert_history_rejected bad-identity UNSAFE_COMMIT_IDENTITY make_bad_identity
assert_history_rejected bad-message UNSAFE_COMMIT_MESSAGE make_bad_message
assert_history_rejected content HISTORY_PROHIBITED_CONTENT make_content
assert_history_rejected deleted-in-head HISTORY_PROHIBITED_CONTENT make_deleted_content

repo="$fixture_root/tag-only"
new_repo "$repo"
make_content "$repo"
bad_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" tag retained-prohibited "$bad_sha"
git -C "$repo" reset -q --hard HEAD~1
history_status=0
"$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
test "$history_status" -eq 1
rg -q "^HISTORY_PROHIBITED_CONTENT:${bad_sha}:" "$repo.out"

make_encoded_path() {
  repo="$1"; path=$'bad\npath.txt'; printf '%s\n' public > "$repo/$path"; commit_all "$repo"
}
repo="$fixture_root/encoded"
new_repo "$repo"; make_encoded_path "$repo"
history_status=0
"$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
test "$history_status" -eq 1
rg -q '^HISTORY_PROHIBITED_PATH_ENCODING:[0-9a-f]{40}$' "$repo.out"
! rg -q 'bad.path' "$repo.out"
repo="$fixture_root/tab-encoded"
new_repo "$repo"; path=$'bad\tpath.txt'; printf '%s\n' public > "$repo/$path"; commit_all "$repo"
history_status=0
"$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
test "$history_status" -eq 1
rg -q '^HISTORY_PROHIBITED_PATH_ENCODING:[0-9a-f]{40}$' "$repo.out"
! rg -q 'bad.path' "$repo.out"

repo="$fixture_root/escape-encoded"
new_repo "$repo"; path=$'bad\033dir/.env'; /bin/mkdir -p "$(dirname "$repo/$path")"; printf '%s\n' private > "$repo/$path"; commit_all "$repo"
history_status=0
"$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
test "$history_status" -eq 1
rg -q '^HISTORY_PROHIBITED_PATH_ENCODING:[0-9a-f]{40}$' "$repo.out"
if LC_ALL=C /usr/bin/grep -q $'\033' "$repo.out"; then exit 1; fi

assert_git_failure() {
  case_name="$1"; match="$2"; expected="$3"
  repo="$fixture_root/$case_name"; shim="$fixture_root/$case_name-shim"
  new_repo "$repo"; /bin/mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for arg in "$@"; do if [ "$arg" = '"'"$match"'"' ]; then printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9; fi; done' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  history_status=0
  PATH="$shim:$PATH" "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
  test "$history_status" -eq 2
  rg -q "^${expected}" "$repo.out"
  ! rg -q INJECTED_PRIVATE_DIAGNOSTIC "$repo.out"
}
assert_git_failure rev-list-failure rev-list HISTORY_ENUMERATION_FAILED
assert_git_failure ls-tree-failure ls-tree HISTORY_TREE_ENUMERATION_FAILED
assert_git_failure cat-file-failure cat-file HISTORY_OBJECT_READ_FAILED

assert_malformed_tree() {
  case_name="$1"; payload="$2"
  repo="$fixture_root/$case_name"; shim="$fixture_root/$case_name-shim"
  new_repo "$repo"; /bin/mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for arg in "$@"; do if [ "$arg" = ls-tree ]; then printf '"'"$payload"'"'; exit 0; fi; done' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  history_status=0
  PATH="$shim:$PATH" "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
  test "$history_status" -eq 2
  rg -q '^HISTORY_TREE_ENUMERATION_FAILED:' "$repo.out"
}
assert_malformed_tree malformed-tree '"malformed-tree-record\\0"'
assert_malformed_tree truncated-tree '"malformed-tree-record"'

assert_tree_tuple() {
  case_name="$1"; record="$2"; expected_status="$3"
  repo="$fixture_root/$case_name"; shim="$fixture_root/$case_name-shim"
  new_repo "$repo"; /bin/mkdir -p "$shim"
  sha="$(git -C "$repo" rev-parse HEAD)"
  printf '%s\n' '#!/usr/bin/env bash' \
    "sha='$sha'" \
    "record='$record'" \
    'for arg in "$@"; do if [ "$arg" = ls-tree ]; then printf "$record" "$sha"; exit 0; fi; done' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  history_status=0
  PATH="$shim:$PATH" "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
  test "$history_status" -eq "$expected_status"
  if [ "$expected_status" -eq 2 ]; then rg -q '^HISTORY_TREE_ENUMERATION_FAILED:' "$repo.out"; fi
}
assert_tree_tuple impossible-mode-type '100644 commit %s 1\tREADME.md\0' 2
assert_tree_tuple valid-gitlink '160000 commit %s -\tSubmodule\0' 0

repo="$fixture_root/rg-failure"; shim="$fixture_root/rg-failure-shim"
new_repo "$repo"; /bin/mkdir -p "$shim"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2' 'exit 9' > "$shim/rg"
chmod +x "$shim/rg"
history_status=0
PATH="$shim:$PATH" "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
test "$history_status" -eq 2
rg -q '^HISTORY_CONTENT_SCAN_FAILED:' "$repo.out"
! /usr/bin/grep -q INJECTED_PRIVATE_DIAGNOSTIC "$repo.out"

make_fake_gitleaks() {
  shim="$1"; mode="$2"; /bin/mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'report_path=' \
    'while [ "$#" -gt 0 ]; do if [ "$1" = --report-path ]; then report_path="$2"; shift 2; else shift; fi; done' \
    "mode='$mode'" \
    'case "$mode" in clean) printf "%s\n" "[]" > "$report_path" ;; finding) printf "%s\n" "[{\"Secret\":\"synthetic-private-value\"}]" > "$report_path" ;; malformed) printf "%s\n" bad > "$report_path" ;; failure) printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9 ;; esac' \
    > "$shim/gitleaks"
  chmod +x "$shim/gitleaks"
}
for mode in clean finding malformed failure; do
  repo="$fixture_root/history-gitleaks-$mode"; shim="$fixture_root/history-gitleaks-$mode-shim"
  new_repo "$repo"; make_fake_gitleaks "$shim" "$mode"
  history_status=0
  PATH="$shim:$PATH" "$workspace_root/script/check_history.sh" "$repo" > "$repo.out" 2>&1 || history_status=$?
  case "$mode" in
    clean) test "$history_status" -eq 0 ;;
    finding) test "$history_status" -eq 1; test "$(cat "$repo.out")" = HISTORY_GITLEAKS_FINDING ;;
    *) test "$history_status" -eq 2; test "$(cat "$repo.out")" = HISTORY_GITLEAKS_FAILED ;;
  esac
  ! /usr/bin/grep -q 'synthetic-private-value\|INJECTED_PRIVATE_DIAGNOSTIC' "$repo.out"
done

make_allowed_privacy_loopbacks() {
  repo="$1"
  printf -v accepted_loopback '%s.%s.%s.%s' 127 0 0 1
  accepted_paths=(
    Sources/PrivacyStorage/ProviderVault/Accepted.swift
    Tests/PrivacyStorageTests/OffDeviceAuthorizationTests.swift
    Tests/PrivacyStorageTests/PrivacyStorageFactoryTests.swift
    Tests/PrivacyStorageTests/ProviderMetadataRepositoryTests.swift
    Tests/PrivacyStorageTests/ProviderVaultHandleTests.swift
    Tests/PrivacyStorageTests/ProviderVaultStateMachineTests.swift
    script/check_local_ollama_preflight.sh
  )
  for accepted_path in "${accepted_paths[@]}"; do
    /bin/mkdir -p "$repo/$(dirname "$accepted_path")"
    printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
      > "$repo/$accepted_path"
  done
  commit_all "$repo" 'Add accepted privacy loopback defaults'
}
repo="$fixture_root/accepted-privacy-loopbacks"
new_repo "$repo"
make_allowed_privacy_loopbacks "$repo"
"$workspace_root/script/check_history.sh" "$repo"

repo="$fixture_root/accepted"; new_repo "$repo"
"$workspace_root/script/check_history.sh" "$repo"
printf '%s\n' HISTORY_TESTS_PASS
