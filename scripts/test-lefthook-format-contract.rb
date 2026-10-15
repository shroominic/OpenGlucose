#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
hook = File.read(File.join(root, "lefthook.yml"))
workspace = File.read(File.join(root, "scripts/flutter-workspace.sh"))
tooling_check = File.read(File.join(root, "scripts/check-tooling.sh"))

def assert(condition, message)
  raise "Lefthook format contract failed: #{message}" unless condition
end

format_command = hook[/^    format:\n(?:(?:      .*|      #.*)\n)*/]
assert(format_command, "pre-commit format command must exist")
assert(
  format_command.include?("run: ./scripts/flutter-workspace.sh format-staged"),
  "format command must use the workspace formatter",
)
assert(!format_command.include?("glob:"), "format command must inspect every staged Dart path")
assert(!format_command.include?("dart format"), "format command must not format from the repository root")

assert(
  workspace.include?("git diff --cached --name-only --diff-filter=ACMR -- '*.dart'"),
  "staged additions, copies, modifications, and renames must be discovered",
)
assert(
  workspace.include?("staged Dart file is outside a configured project"),
  "an unknown staged Dart path must fail instead of being skipped",
)
assert(
  workspace.include?("check_dart_format \"$@\"") &&
    workspace.include?("format-staged)\n    format_staged_files"),
  "staged files must use the same formatter command as format-check",
)
assert(
  tooling_check.include?("test-lefthook-format-contract.rb"),
  "the hook contract must run with tooling checks",
)

puts "Lefthook staged-format contract passed."
