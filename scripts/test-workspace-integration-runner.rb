#!/usr/bin/env ruby

# Pins the `test-integration` runner contract in scripts/flutter-workspace.sh.
#
# The runner used to hand both test roots to one `flutter test` call, which
# Flutter rejects outright:
#
#   Integration tests and unit tests cannot be run in a single invocation.
#
# These checks drive the real script against a throwaway fixture repository
# with stubbed Flutter tooling, so they run on any host and fail if the roots
# are ever mixed again.

require "fileutils"
require "open3"
require "tmpdir"

SCRIPT_NAME = "flutter-workspace.sh"

FLUTTER_STUB = <<~'SH'
  #!/bin/sh
  printf '%s\n' "flutter $*" >> "$RUNNER_STUB_LOG"
  case "$*" in
    *--version*) printf '{"frameworkVersion":"3.41.6"}\n' ;;
  esac
  exit 0
SH

DART_STUB = <<~'SH'
  #!/bin/sh
  printf 'Dart SDK version: 3.11.4 (stable) on "macos"\n' >&2
  exit 0
SH

def assert(condition, message)
  raise "assertion failed: #{message}" unless condition
end

Result = Struct.new(:status, :output, :log) do
  def test_invocations
    log.lines.map(&:chomp).select { |line| line.start_with?("flutter test") }
  end
end

def fixture(host_tests: true, device_tests: false)
  Dir.mktmpdir("workspace-integration-runner") do |root|
    FileUtils.mkdir_p(File.join(root, "scripts"))
    FileUtils.mkdir_p(File.join(root, "bin"))
    FileUtils.cp(File.expand_path(SCRIPT_NAME, __dir__), File.join(root, "scripts", SCRIPT_NAME))

    { "flutter" => FLUTTER_STUB, "dart" => DART_STUB }.each do |name, contents|
      stub = File.join(root, "bin", name)
      File.write(stub, contents)
      FileUtils.chmod(0o755, stub)
    end

    app = File.join(root, "openhealth")
    FileUtils.mkdir_p(app)
    File.write(File.join(app, "pubspec.yaml"), "name: openhealth\nenvironment:\n  sdk: flutter\n")

    if host_tests
      FileUtils.mkdir_p(File.join(app, "test", "integration"))
      File.write(File.join(app, "test", "integration", "demo_test.dart"), "void main() {}\n")
    end

    if device_tests
      FileUtils.mkdir_p(File.join(app, "integration_test"))
      File.write(File.join(app, "integration_test", "device_test.dart"), "void main() {}\n")
    end

    yield root
  end
end

def run_runner(root, device_id: nil)
  log = File.join(root, "stub.log")
  File.write(log, "")
  env = {
    "PATH" => "#{File.join(root, 'bin')}:#{ENV['PATH']}",
    "RUNNER_STUB_LOG" => log,
    "FLUTTER_TEST_DEVICE_ID" => device_id,
  }
  output, status = Open3.capture2e(
    env,
    "sh",
    File.join(root, "scripts", SCRIPT_NAME),
    "test-integration",
    chdir: root
  )
  Result.new(status.exitstatus, output, File.read(log))
end

HOST_TEST = "test/integration/demo_test.dart"
DEVICE_TEST = "integration_test/device_test.dart"

# Both roots present, no device named: the host root runs, the device root is
# deferred with the exact knob that enables it, and nothing mixes the roots.
fixture(device_tests: true) do |root|
  result = run_runner(root)
  assert(result.status == 0, "expected exit 0, got #{result.status}:\n#{result.output}")

  host_runs = result.test_invocations.select { |line| line.include?(HOST_TEST) }
  device_runs = result.test_invocations.select { |line| line.include?(DEVICE_TEST) }
  assert(host_runs.length == 1, "expected one host-root run, got #{host_runs.inspect}")
  assert(device_runs.empty?, "device root must not run without FLUTTER_TEST_DEVICE_ID: #{device_runs.inspect}")

  result.test_invocations.each do |line|
    assert(
      !(line.include?("test/integration/") && line.include?("integration_test/")),
      "invocation mixed both test roots: #{line}"
    )
  end

  assert(
    result.output.include?("FLUTTER_TEST_DEVICE_ID"),
    "deferral notice must name the enabling variable:\n#{result.output}"
  )
  assert(
    result.output.include?("  #{DEVICE_TEST}\n"),
    "deferral notice must list the deferred files by repository-relative path:\n#{result.output}"
  )
end

# A named device routes the device-backed root to its own invocation.
fixture(device_tests: true) do |root|
  result = run_runner(root, device_id: "pixel-test-1")
  assert(result.status == 0, "expected exit 0, got #{result.status}:\n#{result.output}")

  device_runs = result.test_invocations.select { |line| line.include?(DEVICE_TEST) }
  assert(device_runs.length == 1, "expected one device-root run, got #{device_runs.inspect}")
  assert(
    device_runs.first.include?("--device-id pixel-test-1"),
    "device root must target the named device: #{device_runs.first}"
  )
end

# Host root only: unchanged behaviour, and no device lane is announced.
fixture do |root|
  result = run_runner(root)
  assert(result.status == 0, "expected exit 0, got #{result.status}:\n#{result.output}")
  assert(
    result.test_invocations == ["flutter test --no-pub #{HOST_TEST}"],
    "host-only tree must produce one host invocation, got #{result.test_invocations.inspect}"
  )
  assert(
    !result.output.include?("FLUTTER_TEST_DEVICE_ID"),
    "no device lane should be announced when the root is absent:\n#{result.output}"
  )
end

# No roots at all: the existing "nothing found" contract still fails closed.
fixture(host_tests: false) do |root|
  result = run_runner(root)
  assert(result.status != 0, "expected a non-zero exit when no tests are found:\n#{result.output}")
  assert(
    result.output.include?("no tagged or directory-based integration tests were found"),
    "expected the missing-tests diagnostic:\n#{result.output}"
  )
end

puts "Workspace integration runner checks passed."
