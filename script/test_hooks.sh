#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap '/bin/rm -rf "$fixture_root"' EXIT
repository="$fixture_root/repository"
/bin/mkdir -p "$repository"
git -C "$repository" init -q
git -C "$repository" config user.name 'Synthetic Test Identity'
git -C "$repository" config user.email '1+synthetic@users.noreply.github.com'
 /bin/mkdir -p "$repository/script"
/bin/cp "$workspace_root/script/check_public_tree.sh" "$repository/script/"
/bin/cp "$workspace_root/script/check_history.sh" "$repository/script/"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'exit 0' > "$repository/script/test_all.sh"
chmod +x "$repository/script/"*.sh
"$workspace_root/script/install_hooks.sh" "$repository" "$workspace_root"
"$workspace_root/script/verify_hooks.sh" "$repository" "$workspace_root"

printf '%s\n' 'synthetic public source' > "$repository/README.md"
git -C "$repository" add README.md
git -C "$repository" commit -q -m 'Add synthetic source'

/bin/mkdir -p "$repository/docs/superpowers"
printf '%s\n' 'synthetic local plan' > "$repository/docs/superpowers/plan.md"
git -C "$repository" add docs/superpowers/plan.md
if git -C "$repository" commit -q -m 'Reject synthetic plan'; then
  printf '%s\n' 'HOOK_UNEXPECTED_PASS:pre-commit' >&2
  exit 1
fi
git -C "$repository" reset -q HEAD docs/superpowers/plan.md
/bin/rm -rf "$repository/docs"

head_sha="$(git -C "$repository" rev-parse HEAD)"
printf 'refs/heads/main %s refs/heads/main %040d\n' "$head_sha" 0 |
  (cd "$repository" && .git/hooks/pre-push synthetic "$fixture_root/unused-remote")

GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com \
  git -C "$repository" commit -q --allow-empty \
    -m 'Synthetic accepted remote merge'
remote_base="$(git -C "$repository" rev-parse HEAD)"
git -C "$repository" update-ref refs/remotes/origin/main "$remote_base"
git -C "$repository" commit -q --allow-empty \
  -m 'Synthetic new branch commit'
new_branch_head="$(git -C "$repository" rev-parse HEAD)"
printf 'refs/heads/feature %s refs/heads/feature %040d\n' \
  "$new_branch_head" 0 |
  (cd "$repository" && .git/hooks/pre-push synthetic \
    "$fixture_root/unused-remote")

assert_staged_rejected() {
  case_name="$1"; expected="$2"; mode="$3"
  repo="$fixture_root/$case_name"
  /bin/mkdir -p "$repo/script"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Synthetic Test Identity'
  git -C "$repo" config user.email '1+synthetic@users.noreply.github.com'
  /bin/cp "$workspace_root/script/check_public_tree.sh" "$repo/script/"
  /bin/cp "$workspace_root/script/check_history.sh" "$repo/script/"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/script/test_all.sh"
  chmod +x "$repo/script/"*.sh
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  case "$mode" in
    tab) path=$'bad\tpath.txt'; printf '%s\n' public > "$repo/$path"; git -C "$repo" add "$path" ;;
    newline) path=$'bad\npath.txt'; printf '%s\n' public > "$repo/$path"; git -C "$repo" add "$path" ;;
    symlink) /bin/ln -s target "$repo/link"; git -C "$repo" add link ;;
  esac
  hook_status=0
  git -C "$repo" commit -q -m reject > "$repo.out" 2>&1 || hook_status=$?
  test "$hook_status" -ne 0
  rg -q "^${expected}" "$repo.out"
  ! rg -q 'bad.path' "$repo.out"
}
assert_staged_rejected staged-tab PROHIBITED_STAGED_PATH_ENCODING tab
assert_staged_rejected staged-newline PROHIBITED_STAGED_PATH_ENCODING newline
assert_staged_rejected staged-symlink PROHIBITED_STAGED_FILE_MODE symlink

assert_enumerator_failure() {
  case_name="$1"; match="$2"; expected="$3"
  repo="$fixture_root/$case_name"
  shim="$fixture_root/$case_name-shim"
  /bin/mkdir -p "$repo/script" "$shim"
  git -C "$repo" init -q
  git -C "$repo" config user.name 'Synthetic Test Identity'
  git -C "$repo" config user.email '1+synthetic@users.noreply.github.com'
  /bin/cp "$workspace_root/script/check_public_tree.sh" "$repo/script/"
  /bin/cp "$workspace_root/script/check_history.sh" "$repo/script/"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/script/test_all.sh"
  chmod +x "$repo/script/"*.sh
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  printf '%s\n' '#!/usr/bin/env bash' \
    "match='$match'" \
    'if [ "$match" = tracked ] && [ "$1" = ls-files ] && [ "${2:-}" = -z ]; then printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9; fi' \
    'for arg in "$@"; do if [ "$arg" = "$match" ]; then printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9; fi; done' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  printf '%s\n' public > "$repo/public.txt"
  git -C "$repo" add public.txt
  hook_status=0
  (cd "$repo" && PATH="$shim:$PATH" .git/hooks/pre-commit) \
    > "$repo.out" 2>&1 || hook_status=$?
  test "$hook_status" -eq 2
  rg -q "^${expected}$" "$repo.out"
  ! rg -q INJECTED_PRIVATE_DIAGNOSTIC "$repo.out"
}
assert_enumerator_failure fail-ls-stage --stage STAGED_ENUMERATION_FAILED
assert_enumerator_failure fail-ls-tracked tracked STAGED_ENUMERATION_FAILED
assert_enumerator_failure fail-diff diff STAGED_ENUMERATION_FAILED

assert_malformed_index() {
  case_name="$1"; mode="$2"
  repo="$fixture_root/$case_name"; shim="$fixture_root/$case_name-shim"
  /bin/mkdir -p "$repo/script" "$shim"
  git -C "$repo" init -q
  /bin/cp "$workspace_root/script/check_public_tree.sh" "$repo/script/"
  printf '%s\n' '#!/usr/bin/env bash' \
    "mode='$mode'" \
    'if [ "$1" = ls-files ] && [ "${2:-}" = --stage ]; then' \
    '  if [ "$mode" = nul ]; then printf "100644 malformed-stream\0"; else printf "%s" "100644 malformed-stream"; fi' \
    '  exit 0' \
    'fi' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  hook_status=0
  (cd "$repo" && PATH="$shim:$PATH" .git/hooks/pre-commit) > "$repo.out" 2>&1 || hook_status=$?
  test "$hook_status" -eq 2
  rg -q '^STAGED_ENUMERATION_FAILED$' "$repo.out"
}
assert_malformed_index malformed-index nul
assert_malformed_index truncated-index truncated

assert_verify_rejected() {
  mode="$1"; repo="$fixture_root/verify-$mode"
  /bin/mkdir -p "$repo"; git -C "$repo" init -q
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  hook="$repo/.git/hooks/pre-commit"
  case "$mode" in
    missing) /bin/rm "$hook" ;;
    nonexec) chmod 0644 "$hook" ;;
    tampered) printf '%s\n' '# tampered' >> "$hook" ;;
    symlink) /bin/rm "$hook"; /bin/ln -s "$workspace_root/script/hooks/pre-commit" "$hook" ;;
  esac
  verify_status=0
  "$workspace_root/script/verify_hooks.sh" "$repo" "$workspace_root" || verify_status=$?
  test "$verify_status" -ne 0
}
assert_verify_rejected missing
assert_verify_rejected nonexec
assert_verify_rejected tampered
assert_verify_rejected symlink

assert_hook_startup_failure() {
  hook_name="$1"; expected="$2"; repo="$fixture_root/startup-$hook_name"
  /bin/mkdir -p "$repo"; git -C "$repo" init -q
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  shim="$fixture_root/startup-$hook_name-shim"; /bin/mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1" = rev-parse ]; then printf "%s\n" SYNTHETIC_PRIVATE_REVPARSE_DIAGNOSTIC >&2; exit 9; fi' \
    'exec /usr/bin/git "$@"' > "$shim/git"
  chmod +x "$shim/git"
  hook_status=0
  (cd "$repo" && PATH="$shim:$PATH" ".git/hooks/$hook_name" synthetic unused) > "$repo.out" 2>&1 || hook_status=$?
  test "$hook_status" -eq 2
  test "$(cat "$repo.out")" = "$expected"
  ! /usr/bin/grep -q SYNTHETIC_PRIVATE_REVPARSE_DIAGNOSTIC "$repo.out"
}
assert_hook_startup_failure pre-commit STAGED_REPOSITORY_RESOLUTION_FAILED
assert_hook_startup_failure pre-push PUSH_REPOSITORY_RESOLUTION_FAILED

make_fake_staged_gitleaks() {
  shim="$1"; mode="$2"; /bin/mkdir -p "$shim"
  printf '%s\n' '#!/usr/bin/env bash' \
    'command_name="${1:-}"' \
    'report_path=' \
    'while [ "$#" -gt 0 ]; do if [ "$1" = --report-path ]; then report_path="$2"; shift 2; else shift; fi; done' \
    "mode='$mode'" \
    'if [ "$command_name" = dir ]; then printf "%s\n" "[]" > "$report_path"; exit 0; fi' \
    'case "$mode" in clean) printf "%s\n" "[]" > "$report_path" ;; finding) printf "%s\n" "[{\"Secret\":\"synthetic-private-value\"}]" > "$report_path" ;; malformed) printf "%s\n" bad > "$report_path" ;; failure) printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9 ;; esac' \
    > "$shim/gitleaks"
  chmod +x "$shim/gitleaks"
}
for mode in clean finding malformed failure; do
  repo="$fixture_root/staged-gitleaks-$mode"; shim="$fixture_root/staged-gitleaks-$mode-shim"
  /bin/mkdir -p "$repo/script"; git -C "$repo" init -q
  /bin/cp "$workspace_root/script/check_public_tree.sh" "$repo/script/"
  "$workspace_root/script/install_hooks.sh" "$repo" "$workspace_root"
  printf '%s\n' public > "$repo/public.txt"; git -C "$repo" add public.txt
  make_fake_staged_gitleaks "$shim" "$mode"
  hook_status=0
  (cd "$repo" && PATH="$shim:$PATH" .git/hooks/pre-commit) > "$repo.out" 2>&1 || hook_status=$?
  case "$mode" in
    clean) test "$hook_status" -eq 0 ;;
    finding) test "$hook_status" -eq 1; test "$(cat "$repo.out")" = STAGED_GITLEAKS_FINDING ;;
    *) test "$hook_status" -eq 2; test "$(cat "$repo.out")" = STAGED_GITLEAKS_FAILED ;;
  esac
  ! /usr/bin/grep -q 'synthetic-private-value\|INJECTED_PRIVATE_DIAGNOSTIC' "$repo.out"
done

printf '%s\n' HOOK_TESTS_PASS
