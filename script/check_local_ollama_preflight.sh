#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if ! command -v ollama >/dev/null 2>&1; then
  printf '%s\n' BLOCKED_OLLAMA_EXECUTABLE_MISSING >&2
  exit 1
fi

e2e_root="$(mktemp -d)"
e2e_cleanup=0

cleanup_e2e() {
  if [ "$e2e_cleanup" -eq 1 ]; then
    /bin/rm -rf "$e2e_root" >/dev/null 2>&1 || {
      printf '%s\n' E2E_CLEANUP_FAILED >&2
      return 1
    }
  else
    printf '%s\n' E2E_EVIDENCE_RETAINED_LOCALLY >&2
  fi
}

cleanup_e2e_on_exit() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  cleanup_e2e || cleanup_status=$?
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  exit "$cleanup_status"
}

cleanup_e2e_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  cleanup_e2e || true
  exit "$signal_status"
}

trap cleanup_e2e_on_exit EXIT
trap 'cleanup_e2e_on_signal 130' INT
trap 'cleanup_e2e_on_signal 143' TERM
trap 'cleanup_e2e_on_signal 129' HUP

if ! ollama --version > "$e2e_root/version.private" \
     2> "$e2e_root/version-error.private"; then
  printf '%s\n' BLOCKED_OLLAMA_EXECUTABLE_FAILED >&2
  exit 1
fi
if [ ! -s "$e2e_root/version.private" ]; then
  printf '%s\n' BLOCKED_OLLAMA_EXECUTABLE_FAILED >&2
  exit 1
fi

curl_status=0
http_code="$(/usr/bin/curl --silent --show-error --noproxy '*' \
  --connect-timeout 2 --max-time 10 --max-filesize 1048576 \
  --output "$e2e_root/tags.json" --write-out '%{http_code}' \
  'http://127.0.0.1:11434/api/tags' \
  2> "$e2e_root/curl.private")" || curl_status=$?
case "$curl_status" in
  0) ;;
  28) printf '%s\n' BLOCKED_OLLAMA_TIMEOUT >&2; exit 1 ;;
  63) printf '%s\n' BLOCKED_OLLAMA_RESPONSE_LIMIT >&2; exit 1 ;;
  *) printf '%s\n' BLOCKED_OLLAMA_UNAVAILABLE >&2; exit 1 ;;
esac
if [ "$http_code" != 200 ]; then
  printf '%s\n' BLOCKED_OLLAMA_HTTP_STATUS >&2
  exit 1
fi

if ! jq -e '.models | type == "array"' "$e2e_root/tags.json" \
     > /dev/null 2> "$e2e_root/jq.private"; then
  printf '%s\n' BLOCKED_OLLAMA_INVALID_RESPONSE >&2
  exit 1
fi
if ! model_count="$(jq -r '.models | length' "$e2e_root/tags.json" \
     2>> "$e2e_root/jq.private")"; then
  printf '%s\n' BLOCKED_OLLAMA_INVALID_RESPONSE >&2
  exit 1
fi
case "$model_count" in
  ''|*[!0-9]*) printf '%s\n' BLOCKED_OLLAMA_INVALID_RESPONSE >&2; exit 1 ;;
esac
if ! jq -e 'all(.models[]; (.name | type == "string" and length > 0))' \
     "$e2e_root/tags.json" > /dev/null \
     2>> "$e2e_root/jq.private"; then
  printf '%s\n' BLOCKED_OLLAMA_INVALID_RESPONSE >&2
  exit 1
fi
if [ "$model_count" -eq 0 ]; then
  printf '%s\n' BLOCKED_MODEL_UNAVAILABLE >&2
  exit 1
fi

e2e_cleanup=1
trap - EXIT INT TERM HUP
cleanup_e2e
