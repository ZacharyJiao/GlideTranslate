#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
catalog="$project_root/App/GlideTranslate/Resources/Localizable.xcstrings"
audit="$project_root/App/GlideTranslate/Accessibility/AccessibilityAudit.swift"
product="$project_root/App/GlideTranslate"

for command_name in jq ruby; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 "LOCALIZATION_CHECK_MISSING_TOOL:$command_name"
    exit 2
  fi
done

jq -e '.version == "1.0" and .sourceLanguage == "en" and (.strings | type == "object")' \
  "$catalog" >/dev/null
jq -e '.strings.CFBundleDisplayName.localizations.en.stringUnit.value != "" and
       .strings.CFBundleDisplayName.localizations["zh-Hans"].stringUnit.value != ""' \
  "$project_root/App/GlideTranslate/Resources/InfoPlist.xcstrings" >/dev/null

localization_root="$(mktemp -d)"
if [[ -z "$localization_root" || "$localization_root" == "/" || ! -d "$localization_root" || ${#localization_root} -lt 12 ]]; then
  print -u2 "LOCALIZATION_CHECK_INVALID_TEMP_ROOT"
  exit 2
fi
trap '/bin/rm -rf "$localization_root"' EXIT

ruby - "$product" > "$localization_root/literal.txt" <<'RUBY'
product = ARGV.fetch(0)
pattern = /(?:Text|Button|Label|Section|Toggle|Picker|TextField|SecureField|ContentUnavailableView|confirmationDialog|LabeledContent|ProgressView|Window|Menu|accessibilityLabel|accessibilityHint)\(\s*"([A-Za-z][A-Za-z0-9_.-]*)"|(?:String\(\s*localized:|LocalizedStringKey\()\s*"([A-Za-z][A-Za-z0-9_.-]*)"/m
Dir[File.join(product, "**", "*.swift")].sort.each do |path|
  next if File.basename(path) == "AccessibilityAudit.swift"
  File.read(path).scan(pattern) { |captures| puts captures.compact }
end
RUBY

ruby - "$audit" > "$localization_root/dynamic.txt" <<'RUBY'
source = File.read(ARGV.fetch(0))
block = source[/static let dynamicKeys: \[String\] = \[(.*?)\n    \]/m, 1]
abort "LOCALIZATION_DYNAMIC_INVENTORY_MISSING" unless block
block.scan(/"([A-Za-z][A-Za-z0-9_.-]*)"/) { |key| puts key }
RUBY

LC_ALL=C sort -u "$localization_root/literal.txt" "$localization_root/dynamic.txt" \
  > "$localization_root/used.txt"
jq -r '.strings | keys[]' "$catalog" | LC_ALL=C sort -u \
  > "$localization_root/catalog.txt"

if ! diff -u "$localization_root/used.txt" "$localization_root/catalog.txt"; then
  print -u2 "LOCALIZATION_KEY_SET_MISMATCH"
  exit 1
fi

ruby -rjson - "$catalog" <<'RUBY'
catalog = JSON.parse(File.read(ARGV.fetch(0))).fetch("strings")
markers = [["T", "ODO"].join, ["T", "BD"].join]
specifier = /%(?:[0-9]+\$)?[-+#0 ']*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXoOfeEgGcCsSpaAF]/
catalog.each do |key, entry|
  values = %w[en zh-Hans].to_h do |locale|
    value = entry.dig("localizations", locale, "stringUnit", "value")
    abort "LOCALIZATION_EMPTY:#{key}:#{locale}" unless value.is_a?(String) && !value.strip.empty?
    abort "LOCALIZATION_UNFINISHED:#{key}:#{locale}" if markers.any? { |marker| value.include?(marker) }
    [locale, value]
  end
  abort "LOCALIZATION_FORMAT_MISMATCH:#{key}" unless values["en"].scan(specifier) == values["zh-Hans"].scan(specifier)
end
categories = catalog.keys.map { |key| key.split(".").first }.uniq.sort
puts "LOCALIZATION_CHECK_PASS keys=#{catalog.length} categories=#{categories.join(',')}"
RUBY
