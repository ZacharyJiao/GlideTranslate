#!/usr/bin/env bash
set -euo pipefail

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$workspace_root/script/check_public_tree.sh"
fixture_root="$(mktemp -d)"
trap '/bin/rm -rf "$fixture_root"' EXIT

accepted="$fixture_root/accepted"
/bin/mkdir -p "$accepted/Sources"
printf '%s\n' 'public synthetic documentation' > "$accepted/README.md"
printf '%s\n' 'let endpoint = "https://example.invalid/v1"' \
  > "$accepted/Sources/Fixture.swift"

assert_rejected() {
  case_name="$1"
  expected_category="$2"
  case_root="$fixture_root/$case_name"
  shift 2
  /bin/mkdir -p "$case_root"
  "$@" "$case_root"
  status=0
  "$checker" "$case_root" > "$case_root.out" 2>&1 || status=$?
  test "$status" -eq 1
  rg -q "^${expected_category}:" "$case_root.out"
  ! rg -q 'synthetic-private-value' "$case_root.out"
}

make_file_at() {
  relative_path="$1"
  case_root="$2"
  /bin/mkdir -p "$(dirname "$case_root/$relative_path")"
  printf '%s\n' 'synthetic-private-value' > "$case_root/$relative_path"
}

make_local_plan() { make_file_at docs/superpowers/plan.md "$1"; }
make_agent_cache() { make_file_at .codex/state.json "$1"; }
make_local_env() { make_file_at .env "$1"; }
make_user_state() { make_file_at App.xcodeproj/xcuserdata/u.xcuserdatad/x "$1"; }
make_history_db() { make_file_at data/history.sqlite "$1"; }
make_diagnostic_log() { make_file_at output/session.log "$1"; }
make_private_key_file() { make_file_at signing/distribution.p12 "$1"; }
make_provisioning() { make_file_at signing/profile.provisionprofile "$1"; }
make_model_weights() { make_file_at models/weights.gguf "$1"; }
make_archive() { make_file_at output/App.xcarchive/payload "$1"; }

make_absolute_symlink() {
  case_root="$1"
  /bin/ln -s /tmp "$case_root/link"
}
make_escape_symlink() {
  case_root="$1"
  /bin/ln -s ../outside "$case_root/link"
}
make_benign_symlink() {
  case_root="$1"
  printf '%s\n' public > "$case_root/target.txt"
  /bin/ln -s target.txt "$case_root/link"
}

make_content() {
  content="$1"
  case_root="$2"
  printf '%s\n' "$content" > "$case_root/payload.txt"
}
make_absolute_user_path() {
  value='/'"Users/synthetic-private-value/project"
  make_content "$value" "$1"
}
make_home_path() {
  value='/'"home/synthetic-private-value/project"
  make_content "$value" "$1"
}
make_credential_url() {
  scheme='https'
  value="$scheme://name:secret@example.invalid"
  make_content "$value" "$1"
}
make_private_ipv4() {
  case_root="$1"
  printf -v synthetic_private_ip '%s.%s.%s.%s' 192 168 7 8
  make_content "http://$synthetic_private_ip:11434" "$case_root"
}
make_key_marker() {
  value='-----BEGIN '"PRIVATE KEY-----"
  make_content "$value" "$1"
}
make_bearer_marker() {
  value='Authorization:'" Bearer synthetic-private-value"
  make_content "$value" "$1"
}
make_oversized_file() {
  /usr/sbin/mkfile 10485761 "$1/payload.txt"
}
make_ignored_content() {
  case_root="$1"
  printf '%s\n' payload.txt > "$case_root/.ignore"
  make_absolute_user_path "$case_root"
}
make_gitignored_content() {
  case_root="$1"
  /bin/mkdir -p "$case_root/.git"
  printf '%s\n' payload.txt > "$case_root/.gitignore"
  make_absolute_user_path "$case_root"
}
make_git_symlink() {
  case_root="$1"
  /bin/ln -s /tmp "$case_root/.git"
}
make_loopback() {
  case_root="$1"
  printf -v synthetic_loopback '%s.%s.%s.%s' 127 0 0 1
  make_content "http://$synthetic_loopback:11434" "$case_root"
}
make_loopback_script_sibling() {
  case_root="$1"
  /bin/mkdir -p "$case_root/script"
  printf -v synthetic_loopback '%s.%s.%s.%s' 127 0 0 1
  printf 'endpoint="http://%s:11434"\n' "$synthetic_loopback" \
    > "$case_root/script/not_the_preflight.sh"
}

assert_rejected agent-plan PROHIBITED_PATH make_local_plan
assert_rejected agent-cache PROHIBITED_PATH make_agent_cache
assert_rejected local-env PROHIBITED_EXTENSION make_local_env
assert_rejected user-state PROHIBITED_PATH make_user_state
assert_rejected history-db PROHIBITED_EXTENSION make_history_db
assert_rejected diagnostic-log PROHIBITED_EXTENSION make_diagnostic_log
assert_rejected private-key PROHIBITED_EXTENSION make_private_key_file
assert_rejected provisioning PROHIBITED_EXTENSION make_provisioning
assert_rejected model-weights PROHIBITED_EXTENSION make_model_weights
assert_rejected archive PROHIBITED_PATH make_archive
assert_rejected absolute-symlink PROHIBITED_SYMLINK make_absolute_symlink
assert_rejected escape-symlink PROHIBITED_SYMLINK make_escape_symlink
assert_rejected benign-symlink PROHIBITED_SYMLINK make_benign_symlink
assert_rejected absolute-user-path PROHIBITED_CONTENT make_absolute_user_path
assert_rejected home-path PROHIBITED_CONTENT make_home_path
assert_rejected credential-url PROHIBITED_CONTENT make_credential_url
assert_rejected private-ipv4 PROHIBITED_CONTENT make_private_ipv4
assert_rejected key-marker PROHIBITED_CONTENT make_key_marker
assert_rejected bearer-marker PROHIBITED_CONTENT make_bearer_marker
assert_rejected oversized-file OVERSIZED_FILE make_oversized_file
assert_rejected ignore-bypass PROHIBITED_CONTENT make_ignored_content
assert_rejected gitignore-bypass PROHIBITED_CONTENT make_gitignored_content
assert_rejected git-symlink PROHIBITED_SYMLINK make_git_symlink
assert_rejected loopback-outside-allowlist PROHIBITED_CONTENT make_loopback
assert_rejected loopback-script-sibling PROHIBITED_CONTENT \
  make_loopback_script_sibling

assert_encoding_rejected() {
  case_name="$1"
  kind="$2"
  case_root="$fixture_root/$case_name"
  /bin/mkdir -p "$case_root"
  if [ "$kind" = directory ]; then
    /bin/mkdir -p "$case_root/"$'bad\ndirectory'
  else
    printf '%s\n' public > "$case_root/"$'bad\nfile'
  fi
  status=0
  "$checker" "$case_root" > "$case_root.out" 2>&1 || status=$?
  test "$status" -eq 1
  test "$(cat "$case_root.out")" = PROHIBITED_PATH_ENCODING
}
assert_encoding_rejected control-directory directory
assert_encoding_rejected control-file file

assert_tool_failure() {
  case_name="$1"
  expected_category="$2"
  rewritten_tool="$3"
  tool_body="$4"
  case_root="$fixture_root/$case_name"
  shim_root="$fixture_root/$case_name-shim"
  checker_copy="$fixture_root/$case_name-checker.sh"
  /bin/mkdir -p "$case_root" "$shim_root"
  printf '%s\n' public > "$case_root/public.txt"
  printf '%s\n' '#!/usr/bin/env bash' "$tool_body" > "$shim_root/$rewritten_tool"
  chmod +x "$shim_root/$rewritten_tool"
  case "$rewritten_tool" in
    find|stat|tail|od|tr|sort|comm)
      /usr/bin/sed "s#/usr/bin/$rewritten_tool#$shim_root/$rewritten_tool#g" \
        "$checker" > "$checker_copy"
      ;;
    rg)
      /bin/cp "$checker" "$checker_copy"
      ;;
  esac
  chmod +x "$checker_copy"
  status=0
  PATH="$shim_root:$PATH" "$checker_copy" "$case_root" \
      > "$case_root.out" 2>&1 || status=$?
  test "$status" -eq 2
  test "$(cat "$case_root.out")" = "$expected_category"
  ! rg -q 'INJECTED_PRIVATE_DIAGNOSTIC' "$case_root.out"
  ! rg -Fq "$case_root" "$case_root.out"
}
assert_tool_failure find-failure POLICY_ENUMERATION_FAILED find \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'
assert_tool_failure stat-failure POLICY_METADATA_FAILED stat \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'
assert_tool_failure stat-malformed POLICY_METADATA_FAILED stat \
  'printf "%s\n" malformed'
assert_tool_failure rg-failure POLICY_SCAN_FAILED rg \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'
assert_tool_failure find-malformed POLICY_ENUMERATION_FAILED find \
  'printf "%s" malformed-without-nul'
assert_tool_failure rg-malformed POLICY_SCAN_FAILED rg \
  'printf "%s" malformed-output; exit 0'
assert_tool_failure tail-failure POLICY_ENUMERATION_FAILED tail \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'
assert_tool_failure sort-failure POLICY_ENUMERATION_FAILED sort \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'
assert_tool_failure comm-failure POLICY_ENUMERATION_FAILED comm \
  'printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9'

assert_out_of_root_find_rejected() {
  case_root="$fixture_root/find-out-of-root"
  shim_root="$fixture_root/find-out-of-root-shim"
  checker_copy="$fixture_root/find-out-of-root-checker.sh"
  /bin/mkdir -p "$case_root" "$shim_root"
  printf '%s\n' public > "$case_root/public.txt"
  printf '%s\n' '#!/usr/bin/env bash' \
    'outside='"'"'/'"'"'"Users/synthetic-private-value/outside"' \
    'printf "%s\0" "$outside"' \
    > "$shim_root/find"
  chmod +x "$shim_root/find"
  /usr/bin/sed "s#/usr/bin/find#$shim_root/find#g" "$checker" > "$checker_copy"
  chmod +x "$checker_copy"
  status=0
  "$checker_copy" "$case_root" > "$case_root.out" 2>&1 || status=$?
  test "$status" -eq 2
  test "$(cat "$case_root.out")" = POLICY_ENUMERATION_FAILED
  ! rg -q 'synthetic-private-value' "$case_root.out"
  ! rg -Fq "$case_root" "$case_root.out"
}
assert_out_of_root_find_rejected

assert_dotdot_find_rejected() {
  case_root="$fixture_root/find-dotdot/candidate"
  outside_file="$fixture_root/find-dotdot/outside.txt"
  shim_root="$fixture_root/find-dotdot-shim"
  checker_copy="$fixture_root/find-dotdot-checker.sh"
  /bin/mkdir -p "$case_root" "$shim_root"
  printf '%s\n' public > "$outside_file"
  printf '%s\n' '#!/usr/bin/env bash' \
    'candidate_root="$1"' \
    'printf "%s\0" "$candidate_root/../outside.txt"' \
    > "$shim_root/find"
  chmod +x "$shim_root/find"
  /usr/bin/sed "s#/usr/bin/find#$shim_root/find#g" "$checker" > "$checker_copy"
  chmod +x "$checker_copy"
  status=0
  "$checker_copy" "$case_root" > "$case_root.out" 2>&1 || status=$?
  test "$status" -eq 2
  test "$(cat "$case_root.out")" = POLICY_ENUMERATION_FAILED
  ! rg -Fq "$outside_file" "$case_root.out"
}
assert_dotdot_find_rejected

make_fake_gitleaks() {
  shim_root="$1"
  mode="$2"
  /bin/mkdir -p "$shim_root"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'report_path=' \
    'while [ "$#" -gt 0 ]; do' \
    '  if [ "$1" = --report-path ]; then report_path="$2"; shift 2; else shift; fi' \
    'done' \
    "mode='$mode'" \
    'case "$mode" in' \
    '  clean) printf "%s\n" "[]" > "$report_path" ;;' \
    '  finding) printf "%s\n" "[{\"Secret\":\"synthetic-private-value\"}]" > "$report_path" ;;' \
    '  malformed) printf "%s\n" "not-json" > "$report_path" ;;' \
    '  multidoc) printf "%s\n%s\n" "[{\"Secret\":\"synthetic-private-value\"}]" "[]" > "$report_path" ;;' \
    '  missing) : ;;' \
    '  failure) printf "%s\n" INJECTED_PRIVATE_DIAGNOSTIC >&2; exit 9 ;;' \
    'esac' > "$shim_root/gitleaks"
  chmod +x "$shim_root/gitleaks"
}

assert_gitleaks_mode() {
  mode="$1"
  expected="$2"
  case_root="$fixture_root/gitleaks-$mode"
  shim_root="$fixture_root/gitleaks-$mode-shim"
  /bin/mkdir -p "$case_root"
  printf '%s\n' public > "$case_root/public.txt"
  make_fake_gitleaks "$shim_root" "$mode"
  status=0
  PATH="$shim_root:$PATH" "$checker" "$case_root" \
    > "$case_root.out" 2>&1 || status=$?
  if [ "$expected" = PASS ]; then
    test "$status" -eq 0
    test ! -s "$case_root.out"
  else
    case "$expected" in
      GITLEAKS_FINDING:*) test "$status" -eq 1 ;;
      *) test "$status" -eq 2 ;;
    esac
    test "$(cat "$case_root.out")" = "$expected"
  fi
  ! rg -q 'synthetic-private-value|INJECTED_PRIVATE_DIAGNOSTIC' "$case_root.out"
  ! rg -Fq "$case_root" "$case_root.out"
}
assert_gitleaks_mode clean PASS
assert_gitleaks_mode finding GITLEAKS_FINDING:candidate-tree
assert_gitleaks_mode missing GITLEAKS_SCAN_FAILED
assert_gitleaks_mode malformed GITLEAKS_SCAN_FAILED
assert_gitleaks_mode multidoc GITLEAKS_SCAN_FAILED
assert_gitleaks_mode failure GITLEAKS_SCAN_FAILED

/bin/cp "$checker" "$accepted/check_public_tree.sh"
printf -v accepted_loopback '%s.%s.%s.%s' 127 0 0 1
/bin/mkdir -p "$accepted/Sources/ModelProviders" \
  "$accepted/Sources/SharedSupport/Domain" \
  "$accepted/Tests/ModelProvidersTests" \
  "$accepted/App/GlideTranslate/Onboarding" \
  "$accepted/App/GlideTranslate/Settings" \
  "$accepted/script"
printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/Sources/ModelProviders/Allowed.swift"
printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/Sources/SharedSupport/Domain/ProviderTypes.swift"
printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/Tests/ModelProvidersTests/Allowed.swift"
printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/App/GlideTranslate/Onboarding/Allowed.swift"
printf 'let endpoint = "http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/App/GlideTranslate/Settings/Allowed.swift"
printf 'endpoint="http://%s:11434"\n' "$accepted_loopback" \
  > "$accepted/script/check_local_ollama_preflight.sh"
"$checker" "$accepted"
printf '%s\n' PUBLIC_TREE_TESTS_PASS
