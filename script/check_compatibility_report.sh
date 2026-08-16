#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

report_input="${1:-docs/compatibility.md}"
compatibility_root="$(mktemp -d)"

cleanup_compatibility_on_exit() {
  prior_status=$?
  trap - EXIT INT TERM HUP
  cleanup_status=0
  /bin/rm -rf "$compatibility_root" >/dev/null 2>&1 || cleanup_status=$?
  if [ "$prior_status" -ne 0 ]; then exit "$prior_status"; fi
  if [ "$cleanup_status" -ne 0 ]; then
    printf '%s\n' COMPATIBILITY_CLEANUP_FAILED >&2
    exit 2
  fi
  exit 0
}

cleanup_compatibility_on_signal() {
  signal_status="$1"
  trap - EXIT INT TERM HUP
  /bin/rm -rf "$compatibility_root" >/dev/null 2>&1 || true
  exit "$signal_status"
}

trap cleanup_compatibility_on_exit EXIT
trap 'cleanup_compatibility_on_signal 130' INT
trap 'cleanup_compatibility_on_signal 143' TERM
trap 'cleanup_compatibility_on_signal 129' HUP

if [ ! -f "$report_input" ] || [ -L "$report_input" ]; then
  printf '%s\n' COMPATIBILITY_REPORT_INVALID >&2
  exit 2
fi
if ! report_path="$(cd "$(dirname "$report_input")" \
     2> "$compatibility_root/resolve.private" && \
     pwd 2>> "$compatibility_root/resolve.private")/$(basename "$report_input")"; then
  printf '%s\n' COMPATIBILITY_REPORT_INVALID >&2
  exit 2
fi
if [ ! -f "$report_path" ] || [ -L "$report_path" ]; then
  printf '%s\n' COMPATIBILITY_REPORT_INVALID >&2
  exit 2
fi

incomplete_matches="$compatibility_root/incomplete.private"
rg_status=0
LC_ALL=C rg -n -i --no-heading --regexp '(^|[^[:alnum:]_])(TBD|TODO|UNTESTED)([^[:alnum:]_]|$)' \
  -- "$report_path" > "$incomplete_matches" \
  2> "$compatibility_root/rg.private" || rg_status=$?
case "$rg_status" in
  0) printf '%s\n' COMPATIBILITY_ROW_INCOMPLETE >&2; exit 1 ;;
  1) ;;
  *) printf '%s\n' COMPATIBILITY_SCAN_FAILED >&2; exit 2 ;;
esac

parsed_rows="$compatibility_root/rows.private"
if ! /usr/bin/awk -F '|' '
  BEGIN {
    expected_header[1] = "Application"
    expected_header[2] = "Bundle ID"
    expected_header[3] = "Tested Version"
    expected_header[4] = "Mouse Automatic Disabled"
    expected_header[5] = "Mouse Allowed"
    expected_header[6] = "Optional Keyboard"
    expected_header[7] = "Shortcut Selection"
    expected_header[8] = "Shortcut Clipboard"
    expected_header[9] = "Manual Input"
    expected_header[10] = "Bounds"
    expected_header[11] = "Classification"
    expected_header[12] = "Limitation"
  }
  function trim(value) {
    sub(/^[[:space:]]+/, "", value)
    sub(/[[:space:]]+$/, "", value)
    return value
  }
  /^[[:space:]]*\|/ {
    if (NF != 14) {
      if (inside_table) printf "MALFORMED\t%s\n", trim($2)
      next
    }

    exact_header = 1
    exact_separator = 1
    for (column = 2; column <= 13; column += 1) {
      cell[column - 1] = trim($column)
      if (cell[column - 1] != expected_header[column - 1]) {
        exact_header = 0
      }
      if (cell[column - 1] !~ /^---+$/) exact_separator = 0
    }

    if (exact_header) {
      print "HEADER"
      inside_table = 1
      waiting_for_separator = 1
      next
    }
    if (cell[1] == "Application") {
      print "HEADER_INVALID"
      next
    }
    if (!inside_table) next

    if (waiting_for_separator) {
      if (exact_separator) {
        print "SEPARATOR"
        waiting_for_separator = 0
        next
      }
      print "SEPARATOR_INVALID"
      waiting_for_separator = 0
    } else if (exact_separator) {
      print "SEPARATOR"
      next
    }

    printf "ROW"
    for (column = 1; column <= 12; column += 1) {
      printf "\t%s", cell[column]
    }
    printf "\n"
    row_count += 1
    next
  }
  {
    if (inside_table) {
      inside_table = 0
      waiting_for_separator = 0
    }
  }
  END {
    if (row_count == 0) print "EMPTY"
  }
' "$report_path" > "$parsed_rows" \
  2> "$compatibility_root/awk.private"; then
  printf '%s\n' COMPATIBILITY_PARSE_FAILED >&2
  exit 2
fi

expected_applications=(
  Safari
  Chrome
  TextEdit
  Notes
  Xcode
  "Visual Studio Code"
  Terminal
  Preview
)

public_token() {
  token_input="$1"
  token_output="$(printf '%s' "$token_input" \
    | /usr/bin/tr -cs '[:alnum:]_-' '_' \
    | /usr/bin/cut -c 1-64)"
  if [ -z "$token_output" ]; then token_output=UNKNOWN; fi
  printf '%s' "$token_output"
}

is_expected_application() {
  candidate_application="$1"
  for expected_application in "${expected_applications[@]}"; do
    if [ "$candidate_application" = "$expected_application" ]; then return 0; fi
  done
  return 1
}

report_finding() {
  printf '%s\n' "$1" >&2
  finding_count=$((finding_count + 1))
}

finding_count=0
count_Safari=0
count_Chrome=0
count_TextEdit=0
count_Notes=0
count_Xcode=0
count_Visual_Studio_Code=0
count_Terminal=0
count_Preview=0
table_header_count=0
table_separator_count=0

while IFS=$'\t' read -r record_type application bundle_id tested_version \
  mouse_automatic_disabled mouse_allowed optional_keyboard shortcut_selection \
  shortcut_clipboard manual_input bounds classification limitation extra; do
  case "$record_type" in
    HEADER)
      table_header_count=$((table_header_count + 1))
      continue
      ;;
    HEADER_INVALID)
      report_finding COMPATIBILITY_TABLE_HEADER_INVALID
      continue
      ;;
    SEPARATOR)
      table_separator_count=$((table_separator_count + 1))
      continue
      ;;
    SEPARATOR_INVALID)
      report_finding COMPATIBILITY_TABLE_SEPARATOR_INVALID
      continue
      ;;
    EMPTY)
      continue
      ;;
    MALFORMED)
      report_finding \
        "COMPATIBILITY_ROW_MALFORMED:$(public_token "${application:-UNKNOWN}")"
      continue
      ;;
    ROW) ;;
    *)
      printf '%s\n' COMPATIBILITY_PARSE_FAILED >&2
      exit 2
      ;;
  esac

  if ! is_expected_application "$application"; then
    report_finding \
      "COMPATIBILITY_ROW_UNEXPECTED:$(public_token "$application")"
    continue
  fi

  application_token="$(public_token "$application")"
  case "$application" in
    Safari) count_Safari=$((count_Safari + 1)) ;;
    Chrome) count_Chrome=$((count_Chrome + 1)) ;;
    TextEdit) count_TextEdit=$((count_TextEdit + 1)) ;;
    Notes) count_Notes=$((count_Notes + 1)) ;;
    Xcode) count_Xcode=$((count_Xcode + 1)) ;;
    "Visual Studio Code")
      count_Visual_Studio_Code=$((count_Visual_Studio_Code + 1))
      ;;
    Terminal) count_Terminal=$((count_Terminal + 1)) ;;
    Preview) count_Preview=$((count_Preview + 1)) ;;
  esac

  row_values="$bundle_id|$tested_version|$mouse_automatic_disabled|$mouse_allowed|$optional_keyboard|$shortcut_selection|$shortcut_clipboard|$manual_input|$bounds|$classification|$limitation"
  if [ -n "${extra:-}" ] || [ -z "$bundle_id" ] || \
     [ -z "$tested_version" ] || [ -z "$mouse_automatic_disabled" ] || \
     [ -z "$mouse_allowed" ] || [ -z "$optional_keyboard" ] || \
     [ -z "$shortcut_selection" ] || [ -z "$shortcut_clipboard" ] || \
     [ -z "$manual_input" ] || [ -z "$bounds" ] || \
     [ -z "$classification" ] || [ -z "$limitation" ]; then
    report_finding "COMPATIBILITY_ROW_INCOMPLETE:$application_token"
    continue
  fi
  case "$(printf '%s' "$row_values" | /usr/bin/tr '[:lower:]' '[:upper:]')" in
    *TBD*|*TODO*|*UNTESTED*)
      report_finding "COMPATIBILITY_ROW_INCOMPLETE:$application_token"
      continue
      ;;
  esac

  case "$classification" in
    Full|Text-only|Manual-input|Shortcut-clipboard|Rejected|Blocked) ;;
    *)
      report_finding "COMPATIBILITY_CLASSIFICATION_INVALID:$application_token"
      continue
      ;;
  esac

  if [ "$classification" != Full ]; then
    case "$(printf '%s' "$limitation" \
      | /usr/bin/tr '[:lower:]' '[:upper:]')" in
      NONE|N/A|NA|NOT_APPLICABLE|TBD|TODO|UNTESTED)
        report_finding "COMPATIBILITY_LIMITATION_REQUIRED:$application_token"
        ;;
    esac
  fi
done < "$parsed_rows"

if [ "$table_header_count" -eq 0 ]; then
  report_finding COMPATIBILITY_TABLE_HEADER_MISSING
elif [ "$table_header_count" -ne 1 ]; then
  report_finding "COMPATIBILITY_TABLE_HEADER_COUNT:$table_header_count"
fi
if [ "$table_separator_count" -eq 0 ]; then
  report_finding COMPATIBILITY_TABLE_SEPARATOR_MISSING
elif [ "$table_separator_count" -ne 1 ]; then
  report_finding "COMPATIBILITY_TABLE_SEPARATOR_COUNT:$table_separator_count"
fi

for expected_application in "${expected_applications[@]}"; do
  expected_token="$(public_token "$expected_application")"
  case "$expected_application" in
    Safari) application_count="$count_Safari" ;;
    Chrome) application_count="$count_Chrome" ;;
    TextEdit) application_count="$count_TextEdit" ;;
    Notes) application_count="$count_Notes" ;;
    Xcode) application_count="$count_Xcode" ;;
    "Visual Studio Code") application_count="$count_Visual_Studio_Code" ;;
    Terminal) application_count="$count_Terminal" ;;
    Preview) application_count="$count_Preview" ;;
  esac
  if [ "$application_count" -eq 0 ]; then
    report_finding "COMPATIBILITY_ROW_MISSING:$expected_token"
  elif [ "$application_count" -ne 1 ]; then
    report_finding \
      "COMPATIBILITY_ROW_COUNT:$expected_token:$application_count"
  fi
done

if [ "$finding_count" -ne 0 ]; then exit 1; fi
