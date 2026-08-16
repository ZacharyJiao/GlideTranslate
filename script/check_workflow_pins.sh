#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
candidate_input="${1:-.}"
pin_root="$(mktemp -d)"
cleanup_pin_on_exit() {
  prior_status=$?; trap - EXIT INT TERM HUP; cleanup_status=0
  /bin/rm -rf "$pin_root" >/dev/null 2>&1 || cleanup_status=$?
  [ "$prior_status" -ne 0 ] && exit "$prior_status"
  if [ "$cleanup_status" -ne 0 ]; then printf '%s\n' WORKFLOW_CLEANUP_FAILED >&2; exit 2; fi
  exit 0
}
cleanup_pin_on_signal() { signal_status="$1"; trap - EXIT INT TERM HUP; /bin/rm -rf "$pin_root" >/dev/null 2>&1 || true; exit "$signal_status"; }
trap cleanup_pin_on_exit EXIT
trap 'cleanup_pin_on_signal 130' INT
trap 'cleanup_pin_on_signal 143' TERM
trap 'cleanup_pin_on_signal 129' HUP
if ! candidate_root="$(cd "$candidate_input" 2> "$pin_root/root.private" && pwd -P 2>> "$pin_root/root.private")"; then printf '%s\n' WORKFLOW_ROOT_INVALID >&2; exit 2; fi
workflow_root="$candidate_root/.github/workflows"
test -d "$workflow_root" || { printf '%s\n' WORKFLOW_DIRECTORY_MISSING >&2; exit 2; }
if [ -L "$candidate_root/.github" ] || [ -L "$workflow_root" ]; then printf '%s\n' WORKFLOW_PATH_INVALID >&2; exit 2; fi
report="$pin_root/report"
ruby_status=0
/usr/bin/ruby -rpsych -rfind - "$candidate_root" "$workflow_root" \
  > "$report" 2> "$pin_root/ruby.private" <<'RUBY' || ruby_status=$?
candidate_root = ARGV.fetch(0)
workflow_root = ARGV.fetch(1)
references = 0
finding = false

safe_relative = lambda do |path|
  prefix = candidate_root + File::SEPARATOR
  exit 4 unless path.start_with?(prefix)
  relative = path.delete_prefix(prefix)
  bytes = relative.b.bytes
  components = relative.split(File::SEPARATOR, -1)
  exit 4 if relative.empty? || relative.start_with?(File::SEPARATOR)
  exit 4 if components.any? { |component| component.empty? || component == "." || component == ".." }
  exit 4 if bytes.any? { |byte| byte < 32 || byte == 127 }
  relative
end

validate = lambda do |node|
  case node
  when Psych::Nodes::Alias
    exit 5
  when Psych::Nodes::Mapping
    exit 5 unless node.children.length.even?
    keys = []
    node.children.each_slice(2) do |key, value|
      exit 5 unless key.is_a?(Psych::Nodes::Scalar)
      exit 5 unless key.tag.nil? || key.tag.start_with?("tag:yaml.org,2002:")
      exit 5 if key.value == "<<"
      exit 5 if keys.include?(key.value)
      keys << key.value
      validate.call(value)
    end
  when Psych::Nodes::Sequence, Psych::Nodes::Document, Psych::Nodes::Stream
    node.children.each { |child| validate.call(child) }
  when Psych::Nodes::Scalar
    exit 5 unless node.tag.nil? || node.tag.start_with?("tag:yaml.org,2002:")
  end
end

mapping_entry = lambda do |mapping, name|
  return nil unless mapping.is_a?(Psych::Nodes::Mapping)
  mapping.children.each_slice(2).find { |key, _value| key.value == name }
end

check_reference = lambda do |key, value, relative|
  references += 1
  exit 5 unless value.is_a?(Psych::Nodes::Scalar)
  reference = value.value.strip
  immutable_repository = reference.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*@[0-9a-f]{40}\z/)
  immutable_container = reference.match?(/\Adocker:\/\/[^@\s]+@sha256:[0-9a-f]{64}\z/)
  unless immutable_repository || immutable_container
    puts "FLOATING_ACTION:#{relative}:#{key.start_line + 1}"
    finding = true
  end
end

inspect_workflow = lambda do |stream, relative|
  document = stream.children.fetch(0)
  root = document.children.fetch(0)
  return unless root.is_a?(Psych::Nodes::Mapping)
  jobs_entry = mapping_entry.call(root, "jobs")
  return if jobs_entry.nil?
  jobs = jobs_entry.fetch(1)
  return unless jobs.is_a?(Psych::Nodes::Mapping)
  jobs.children.each_slice(2) do |_job_id, job|
    next unless job.is_a?(Psych::Nodes::Mapping)
    reusable = mapping_entry.call(job, "uses")
    check_reference.call(reusable.fetch(0), reusable.fetch(1), relative) unless reusable.nil?
    steps_entry = mapping_entry.call(job, "steps")
    next if steps_entry.nil?
    steps = steps_entry.fetch(1)
    next unless steps.is_a?(Psych::Nodes::Sequence)
    steps.children.each do |step|
      next unless step.is_a?(Psych::Nodes::Mapping)
      action = mapping_entry.call(step, "uses")
      check_reference.call(action.fetch(0), action.fetch(1), relative) unless action.nil?
    end
  end
end

begin
  workflow_files = []
  Find.find(workflow_root) do |path|
    stat = File.lstat(path)
    relative = path == workflow_root ? ".github/workflows" : safe_relative.call(path)
    exit 4 if stat.symlink?
    next if stat.directory?
    exit 4 unless stat.file?
    extension = File.extname(path).downcase
    workflow_files << [path, relative] if extension == ".yml" || extension == ".yaml"
  end
  workflow_files.sort_by!(&:last)
  workflow_files.each do |path, relative|
    stream = Psych.parse_stream(File.binread(path), relative)
    exit 5 unless stream.children.length == 1
    validate.call(stream)
    inspect_workflow.call(stream, relative)
  end
rescue Psych::SyntaxError
  exit 5
rescue SystemCallError
  exit 6
rescue StandardError
  exit 6
end

exit 3 if references.zero?
exit(finding ? 1 : 0)
RUBY
case "$ruby_status" in
  0) ;;
  1) /bin/cat "$report" || { printf '%s\n' WORKFLOW_SCAN_FAILED >&2; exit 2; }; exit 1 ;;
  3) printf '%s\n' WORKFLOW_REFERENCE_MISSING >&2; exit 1 ;;
  4) printf '%s\n' WORKFLOW_PATH_INVALID >&2; exit 2 ;;
  5) printf '%s\n' WORKFLOW_PARSE_FAILED >&2; exit 2 ;;
  *) printf '%s\n' WORKFLOW_SCAN_FAILED >&2; exit 2 ;;
esac
exit 0
