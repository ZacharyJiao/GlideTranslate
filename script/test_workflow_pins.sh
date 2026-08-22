#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap '/bin/rm -rf "$fixture_root"' EXIT
checker="$workspace_root/script/check_workflow_pins.sh"
test -x "$checker"

make_workflow() {
  candidate="$1"
  reference="$2"
  /bin/mkdir -p "$candidate/.github/workflows"
  printf '%s\n' \
    'jobs:' \
    '  test:' \
    '    steps:' \
    "      - uses: $reference" \
    > "$candidate/.github/workflows/ci.yml"
}

expect_failure() {
  expected_status="$1"
  expected_marker="$2"
  private_fragment="$3"
  shift 3
  public_output="$fixture_root/public-output"
  status=0
  "$@" > "$public_output" 2>&1 || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    printf 'WORKFLOW_FIXTURE_STATUS_UNEXPECTED:%s:%s\n' "$expected_marker" "$status" >&2
    exit 1
  fi
  if ! LC_ALL=C /usr/bin/grep -Fq "$expected_marker" "$public_output"; then
    printf 'WORKFLOW_FIXTURE_MARKER_MISSING:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if [ -n "$private_fragment" ] && LC_ALL=C /usr/bin/grep -Fq "$private_fragment" "$public_output"; then
    printf 'WORKFLOW_FIXTURE_PRIVATE_DIAGNOSTIC_LEAKED:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if LC_ALL=C /usr/bin/grep -Fq "$fixture_root" "$public_output"; then
    printf 'WORKFLOW_FIXTURE_ROOT_LEAKED:%s\n' "$expected_marker" >&2
    exit 1
  fi
}

floating_root="$fixture_root/floating"
make_workflow "$floating_root" actions/checkout@v7
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$floating_root"

accepted_root="$fixture_root/accepted"
make_workflow "$accepted_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
"$checker" "$accepted_root"

local_root="$fixture_root/local"
make_workflow "$local_root" ./local-action
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$local_root"

container_root="$fixture_root/container"
make_workflow "$container_root" docker://alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"$checker" "$container_root"

missing_root="$fixture_root/missing"
/bin/mkdir -p "$missing_root"
expect_failure 2 WORKFLOW_DIRECTORY_MISSING '' "$checker" "$missing_root"

empty_root="$fixture_root/empty"
/bin/mkdir -p "$empty_root/.github/workflows"
printf '%s\n' 'name: no-actions' > "$empty_root/.github/workflows/ci.yml"
expect_failure 1 WORKFLOW_REFERENCE_MISSING '' "$checker" "$empty_root"

parse_root="$fixture_root/parse-error"
make_workflow "$parse_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
/bin/mkdir -p "$parse_root/.github/workflows"
printf '%s\n' 'jobs: [' > "$parse_root/.github/workflows/ci.yml"
expect_failure 2 WORKFLOW_PARSE_FAILED '' "$checker" "$parse_root"

path_root="$fixture_root/path-error"
make_workflow "$path_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
/bin/ln -s /outside/private.yml "$path_root/.github/workflows/outside.yml"
expect_failure 2 WORKFLOW_PATH_INVALID /outside/private.yml "$checker" "$path_root"

parent_link_root="$fixture_root/parent-link"
external_workflow_root="$fixture_root/external-parent/workflows"
/bin/mkdir -p "$parent_link_root" "$external_workflow_root"
printf '%s\n' 'jobs:' '  test:' '    steps:' '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' > "$external_workflow_root/ci.yml"
/bin/ln -s "$fixture_root/external-parent" "$parent_link_root/.github"
expect_failure 2 WORKFLOW_PATH_INVALID "$external_workflow_root" "$checker" "$parent_link_root"

ignored_root="$fixture_root/ignored"
make_workflow "$ignored_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
printf '%s\n' 'ignored.yml' > "$ignored_root/.ignore"
printf '%s\n' 'jobs:' '  ignored:' '    uses: actions/setup-node@v4' > "$ignored_root/.github/workflows/ignored.yml"
expect_failure 1 FLOATING_ACTION:.github/workflows/ignored.yml:3 '' "$checker" "$ignored_root"

spaced_root="$fixture_root/spaced"
/bin/mkdir -p "$spaced_root/.github/workflows"
printf '%s\n' 'jobs:' '  test:' '    steps:' "      - uses : actions/setup-node@v4" > "$spaced_root/.github/workflows/ci.yml"
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$spaced_root"

quoted_root="$fixture_root/quoted"
/bin/mkdir -p "$quoted_root/.github/workflows"
printf '%s\n' 'jobs:' '  test:' '    steps:' "      - 'uses': actions/setup-node@v4" > "$quoted_root/.github/workflows/ci.yml"
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$quoted_root"

folded_root="$fixture_root/folded"
/bin/mkdir -p "$folded_root/.github/workflows"
printf '%s\n' 'jobs:' '  test:' '    steps:' '      - uses: >' '          actions/setup-node@v4' > "$folded_root/.github/workflows/ci.yml"
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$folded_root"

mutable_container_root="$fixture_root/mutable-container"
make_workflow "$mutable_container_root" docker://alpine:latest
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$mutable_container_root"

wrong_container_digest_root="$fixture_root/wrong-container-digest"
make_workflow "$wrong_container_digest_root" docker://alpine@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$wrong_container_digest_root"

escaping_local_root="$fixture_root/escaping-local"
make_workflow "$escaping_local_root" ./../outside-action
expect_failure 1 FLOATING_ACTION:.github/workflows/ci.yml:4 '' "$checker" "$escaping_local_root"

false_reference_root="$fixture_root/false-reference"
/bin/mkdir -p "$false_reference_root/.github/workflows"
printf '%s\n' \
  'jobs:' \
  '  test:' \
  '    steps:' \
  '      - run: |' \
  '          # uses: actions/setup-node@0123456789012345678901234567890123456789' \
  '          printf "%s\\n" "uses: actions/setup-node@0123456789012345678901234567890123456789"' \
  > "$false_reference_root/.github/workflows/ci.yml"
expect_failure 1 WORKFLOW_REFERENCE_MISSING '' "$checker" "$false_reference_root"

env_uses_root="$fixture_root/env-uses"
/bin/mkdir -p "$env_uses_root/.github/workflows"
printf '%s\n' \
  'on: push' \
  'env:' \
  '  uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' \
  'jobs:' \
  '  test:' \
  '    runs-on: macos-26' \
  '    env:' \
  '      uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' \
  '    steps:' \
  '      - env:' \
  '          uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' \
  '        run: echo safe' \
  > "$env_uses_root/.github/workflows/ci.yml"
actionlint "$env_uses_root/.github/workflows/ci.yml"
expect_failure 1 WORKFLOW_REFERENCE_MISSING '' "$checker" "$env_uses_root"

cleanup_root="$fixture_root/cleanup-error"
make_workflow "$cleanup_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
cleanup_checker="$fixture_root/check-workflow-pins-cleanup-fixture.sh"
/usr/bin/sed \
  's#/bin/rm -rf "$pin_root" >/dev/null 2>&1 || cleanup_status=$?#/usr/bin/false || cleanup_status=$?#' \
  "$checker" > "$cleanup_checker"
chmod +x "$cleanup_checker"
expect_failure 2 WORKFLOW_CLEANUP_FAILED '' "$cleanup_checker" "$cleanup_root"

signal_root="$fixture_root/signal"
make_workflow "$signal_root" actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
signal_checker="$fixture_root/check-workflow-pins-signal-fixture.sh"
/usr/bin/sed \
  '/^\/usr\/bin\/ruby -rpsych -rfind - /s#^#kill -TERM "$$"; #' \
  "$checker" > "$signal_checker"
chmod +x "$signal_checker"
signal_output="$fixture_root/signal-output"
signal_status=0
"$signal_checker" "$signal_root" > "$signal_output" 2>&1 || signal_status=$?
if [ "$signal_status" -ne 143 ]; then
  printf 'WORKFLOW_SIGNAL_STATUS_UNEXPECTED:%s\n' "$signal_status" >&2
  exit 1
fi
if [ -s "$signal_output" ]; then
  printf '%s\n' WORKFLOW_SIGNAL_DIAGNOSTIC_UNEXPECTED >&2
  exit 1
fi

current_workflow="$workspace_root/.github/workflows/ci.yml"
rg -Fq 'aggregate_log="$RUNNER_TEMP/glidetranslate-candidate-aggregate.private.log"' \
  "$current_workflow"
rg -Fq './script/test_all.sh > "$aggregate_log" 2>&1' "$current_workflow"
rg -Fq '/bin/rm -P "$aggregate_log"' "$current_workflow"
rg -Fq "printf '%s\\n' CANDIDATE_AGGREGATE_PASSED" "$current_workflow"
rg -Fq 'XCODE_UNIT_TESTS|XCODE_UI_TESTS' "$current_workflow"
! rg -Fq '|XCODE_TESTS|' "$current_workflow"
rg -Fq "printf 'CANDIDATE_AGGREGATE_FAILED:%s\\n' \"\$failed_stage\"" "$current_workflow"
! rg -Fq 'cat "$aggregate_log"' "$current_workflow"
test "$(rg -c 'shasum -a 256 -c - >[/]dev/null' "$current_workflow")" -eq 3
! rg -q '^[[:space:]]*run:[[:space:]]+[.]/script/test_all[.]sh[[:space:]]*$' \
  "$current_workflow"

printf '%s\n' WORKFLOW_PIN_TESTS_PASS
