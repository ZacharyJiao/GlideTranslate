#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d)"
server_pids=()

cleanup_fixture() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  for server_pid in "${server_pids[@]:-}"; do
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  done
  /usr/bin/chflags -R nouchg "$fixture_root" 2>/dev/null || true
  /bin/rm -rf "$fixture_root" >/dev/null 2>&1 || true
  exit "$prior_status"
}
trap cleanup_fixture EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

checker="$workspace_root/script/check_local_ollama_preflight.sh"
test -x "$checker"

fake_bin="$fixture_root/bin"
probe_tmp="$fixture_root/probe-tmp"
/bin/mkdir -p "$fake_bin" "$probe_tmp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "ollama version 0.0.synthetic"' \
  > "$fake_bin/ollama"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ "$#" -eq 1 ] && [ "$1" = -d ]; then' \
  '  exec /usr/bin/mktemp -d "${GT_OLLAMA_PROBE_TMP:?}/e2e.XXXXXX"' \
  'fi' \
  'exec /usr/bin/mktemp "$@"' \
  > "$fake_bin/mktemp"
/bin/chmod 755 "$fake_bin/ollama" "$fake_bin/mktemp"

server_script="$fixture_root/server.py"
printf '%s\n' \
  'from http.server import BaseHTTPRequestHandler, HTTPServer' \
  'import os' \
  'import time' \
  'mode = os.environ["GT_SERVER_MODE"]' \
  'port_file = os.environ["GT_SERVER_PORT_FILE"]' \
  'class Handler(BaseHTTPRequestHandler):' \
  '    def log_message(self, format, *args):' \
  '        pass' \
  '    def do_GET(self):' \
  '        if mode == "hang":' \
  '            time.sleep(2)' \
  '            body = b"{\"models\":[]}"' \
  '            status = 200' \
  '        elif mode == "oversized":' \
  '            body = b"x" * 1048577' \
  '            status = 200' \
  '        elif mode == "non200":' \
  '            body = b"{}"' \
  '            status = 503' \
  '        elif mode == "malformed":' \
  '            body = b"{"' \
  '            status = 200' \
  '        elif mode == "empty":' \
  '            body = b"{\"models\":[]}"' \
  '            status = 200' \
  '        elif mode == "invalid-name":' \
  '            body = b"{\"models\":[{\"name\":\"\"}]}"' \
  '            status = 200' \
  '        else:' \
  '            body = b"{\"models\":[{\"name\":\"synthetic\"}]}"' \
  '            status = 200' \
  '        self.send_response(status)' \
  '        self.send_header("Content-Type", "application/json")' \
  '        self.send_header("Content-Length", str(len(body)))' \
  '        self.end_headers()' \
  '        try:' \
  '            self.wfile.write(body)' \
  '        except BrokenPipeError:' \
  '            pass' \
  'server = HTTPServer(("127.0.0.1", 0), Handler)' \
  'with open(port_file, "w", encoding="ascii") as stream:' \
  '    stream.write(str(server.server_port))' \
  'server.handle_request()' \
  > "$server_script"

expect_failure() {
  expected_status="$1"
  expected_marker="$2"
  shift 2
  stdout_path="$fixture_root/expected.stdout"
  stderr_path="$fixture_root/expected.stderr"
  status=0
  "$@" > "$stdout_path" 2> "$stderr_path" || status=$?
  if [ "$status" -ne "$expected_status" ]; then
    printf 'OLLAMA_FIXTURE_STATUS_UNEXPECTED:%s:%s\n' \
      "$expected_marker" "$status" >&2
    exit 1
  fi
  if ! /usr/bin/grep -Fq "$expected_marker" "$stderr_path"; then
    printf 'OLLAMA_FIXTURE_MARKER_MISSING:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if [ -s "$stdout_path" ]; then
    printf 'OLLAMA_FIXTURE_STDOUT_UNEXPECTED:%s\n' "$expected_marker" >&2
    exit 1
  fi
  if /usr/bin/grep -Fq "$fixture_root" "$stderr_path"; then
    printf 'OLLAMA_FIXTURE_ROOT_LEAKED:%s\n' "$expected_marker" >&2
    exit 1
  fi
}

reset_probe_tmp() {
  /usr/bin/chflags -R nouchg "$probe_tmp" 2>/dev/null || true
  /usr/bin/find "$probe_tmp" -mindepth 1 -depth -delete
}

make_checker_for_port() {
  port="$1"
  destination="$2"
  /usr/bin/sed \
    -e "s#127[.]0[.]0[.]1:11434#127.0.0.1:$port#g" \
    -e 's/--max-time 10/--max-time 1/' \
    "$checker" > "$destination"
  /bin/chmod 755 "$destination"
}

start_server() {
  mode="$1"
  name="$2"
  port_file="$fixture_root/$name.port"
  GT_SERVER_MODE="$mode" GT_SERVER_PORT_FILE="$port_file" \
    /usr/bin/python3 "$server_script" \
    > "$fixture_root/$name.server.stdout" \
    2> "$fixture_root/$name.server.stderr" &
  server_pid=$!
  server_pids+=("$server_pid")
  for ((attempt = 0; attempt < 200; attempt += 1)); do
    if [ -s "$port_file" ]; then break; fi
    /bin/sleep 0.01
  done
  test -s "$port_file"
  server_port="$(/bin/cat "$port_file")"
  case "$server_port" in ''|*[!0-9]*) exit 1 ;; esac
  server_checker="$fixture_root/$name.checker.sh"
  make_checker_for_port "$server_port" "$server_checker"
}

run_checker() {
  selected_checker="$1"
  env \
    PATH="$fake_bin:$PATH" \
    GT_OLLAMA_PROBE_TMP="$probe_tmp" \
    GT_OLLAMA_SIGNAL_SENTINEL="${GT_OLLAMA_SIGNAL_SENTINEL:-}" \
    "$selected_checker"
}

start_server valid valid
run_checker "$server_checker"
wait "$server_pid"
test -z "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"

for failure_row in \
  'hang:BLOCKED_OLLAMA_TIMEOUT' \
  'oversized:BLOCKED_OLLAMA_RESPONSE_LIMIT' \
  'non200:BLOCKED_OLLAMA_HTTP_STATUS' \
  'malformed:BLOCKED_OLLAMA_INVALID_RESPONSE' \
  'empty:BLOCKED_MODEL_UNAVAILABLE' \
  'invalid-name:BLOCKED_OLLAMA_INVALID_RESPONSE'; do
  mode="${failure_row%%:*}"
  marker="${failure_row##*:}"
  start_server "$mode" "$mode"
  expect_failure 1 "$marker" run_checker "$server_checker"
  wait "$server_pid" >/dev/null 2>&1 || true
  test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
  reset_probe_tmp
done

unavailable_checker="$fixture_root/unavailable.checker.sh"
make_checker_for_port 1 "$unavailable_checker"
expect_failure 1 BLOCKED_OLLAMA_UNAVAILABLE run_checker "$unavailable_checker"
test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
reset_probe_tmp

start_server valid cleanup-failure
cleanup_checker="$fixture_root/cleanup-injected.checker.sh"
/usr/bin/sed \
  's#/bin/rm -rf "$e2e_root" >/dev/null 2>&1#/usr/bin/false#' \
  "$server_checker" > "$cleanup_checker"
/bin/chmod 755 "$cleanup_checker"
expect_failure 1 E2E_CLEANUP_FAILED run_checker "$cleanup_checker"
wait "$server_pid"
test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
reset_probe_tmp

for signal_row in INT:130 TERM:143 HUP:129; do
  signal_name="${signal_row%%:*}"
  expected_status="${signal_row##*:}"
  start_server valid "signal-$signal_name"
  signal_checker="$fixture_root/signal-$signal_name-injected.checker.sh"
  signal_sentinel="$fixture_root/signal-$signal_name.reached"
  /usr/bin/awk -v signal_name="$signal_name" '
    /^curl_status=0$/ {
      print "kill -" signal_name " \"$$\""
      print ": > \"${GT_OLLAMA_SIGNAL_SENTINEL:?}\""
    }
    { print }
  ' "$server_checker" > "$signal_checker"
  /bin/chmod 755 "$signal_checker"
  GT_OLLAMA_SIGNAL_SENTINEL="$signal_sentinel" \
    expect_failure "$expected_status" E2E_EVIDENCE_RETAINED_LOCALLY \
    run_checker "$signal_checker"
  test ! -e "$signal_sentinel"
  if ! kill -0 "$server_pid" >/dev/null 2>&1; then
    printf 'OLLAMA_SIGNAL_REQUEST_REACHED:%s\n' "$signal_name" >&2
    exit 1
  fi
  kill "$server_pid" >/dev/null 2>&1 || true
  wait "$server_pid" >/dev/null 2>&1 || true
  test -n "$(/usr/bin/find "$probe_tmp" -mindepth 1 -print -quit)"
  reset_probe_tmp
done

printf '%s\n' LOCAL_OLLAMA_PREFLIGHT_TESTS_PASS
