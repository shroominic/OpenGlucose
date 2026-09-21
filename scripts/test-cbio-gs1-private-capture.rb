#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

SOURCE_SCRIPT = File.join(__dir__, "cbio-gs1-private-capture.sh")
RUN_ID = "0123456789abcdef0123456789abcdef"
DEVICE_ID = "AA:BB:CC:DD:EE:FF"
TRIGGER = "22" * 5
FINAL_ARTIFACTS = %w[
  full-records.json manifest.json auth-prompt-receipt.json command-audit.json
].freeze

def assert(condition, message)
  raise message unless condition
end

def write_executable(path, body)
  File.write(path, body)
  File.chmod(0o755, path)
end

def git(repo, *args)
  stdout, stderr, status = Open3.capture3("git", "-C", repo, *args)
  raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

  stdout.strip
end

def run_capture(
  mutation: nil,
  hang: nil,
  corrupt_pull: false,
  switch_after_ready: false,
  initial_user: "10",
  source_change: nil,
  allow_expected_untracked: false,
  context_case: nil,
  destination_case: nil
)
  Dir.mktmpdir("cbio-private-capture-contract.") do |temporary|
    root = File.realpath(temporary)
    repo = File.join(root, "source")
    private_root = File.join(root, "private")
    bin = File.join(root, "bin")
    device = File.join(root, "device")
    audit = File.join(root, "audit.log")
    user_file = File.join(root, "current-user")
    context = File.join(private_root, "context.json")
    destination = File.join(private_root, "destination")
    mutation_file = File.join(private_root, "mutation.json")
    [File.join(repo, "scripts"), File.join(repo, "openhealth"), private_root, bin, device].each do |path|
      FileUtils.mkdir_p(path, mode: 0o700)
    end
    FileUtils.cp(SOURCE_SCRIPT, File.join(repo, "scripts", "cbio-gs1-private-capture.sh"))
    File.write(File.join(repo, "openhealth", ".fixture"), "fixture\n")
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "fixture@example.invalid")
    git(repo, "config", "user.name", "Capture Fixture")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "fixture")
    head = git(repo, "rev-parse", "HEAD")

    values = {
      "CBIO_VENDOR_STREAM_KEY_HEX" => "00" * 16,
      "CBIO_VENDOR_AUTH_MATERIAL_HEX" => "11" * 16,
      "CBIO_VENDOR_AUTH_TRIGGER_HEX" => TRIGGER,
      "CBIO_CAPTURE_RUN_ID" => RUN_ID,
      "CBIO_CAPTURE_START_NONCE" => "a" * 32,
      "CBIO_CAPTURE_ACK_NONCE" => "b" * 32,
      "CBIO_TARGET_DEVICE_ID" => DEVICE_ID,
      "CBIO_EXPECTED_SERIAL_HEX" => "ffeeddccbbaa",
      "CBIO_LABEL_SHA256" => "c" * 64,
      "CBIO_REPLAY_CONTEXT" => "V1.1.6A",
      "CBIO_RAW_START_INDEX" => "1",
      "CBIO_SOURCE_REVISION" => head
    }
    File.write(context, JSON.generate(values))
    File.chmod(0o600, context)
    if mutation
      File.write(mutation_file, JSON.generate(mutation))
      File.chmod(0o600, mutation_file)
    end
    File.write(user_file, "#{initial_user}\n")

    if allow_expected_untracked
      allowed = File.join(repo, "docs", "superpowers", "cbio-offset4-evidence-report.md")
      FileUtils.mkdir_p(File.dirname(allowed))
      File.write(allowed, "preserved fixture\n")
    end
    case source_change
    when :tracked
      File.write(File.join(repo, "openhealth", ".fixture"), "dirty\n")
    when :staged
      File.write(File.join(repo, "openhealth", ".fixture"), "staged\n")
      git(repo, "add", "openhealth/.fixture")
    when :untracked
      File.write(File.join(repo, "unexpected.txt"), "unexpected\n")
    end

    context_env = context
    case context_case
    when :relative
      context_env = "context.json"
    when :inside_repo
      context_env = File.join(repo, "context.json")
      FileUtils.cp(context, context_env)
    when :symlink
      context_env = File.join(private_root, "context-link.json")
      File.symlink(context, context_env)
    when :bad_mode
      File.chmod(0o640, context)
    when :unsafe_parent
      File.chmod(0o755, private_root)
    end

    destination_env = destination
    case destination_case
    when :relative
      destination_env = "destination"
    when :inside_repo
      destination_env = File.join(repo, "destination")
    when :symlink_parent
      real_parent = File.join(root, "destination-real")
      FileUtils.mkdir_p(real_parent, mode: 0o700)
      linked_parent = File.join(private_root, "destination-link")
      File.symlink(real_parent, linked_parent)
      destination_env = File.join(linked_parent, "capture")
    when :unsafe_parent
      unsafe = File.join(root, "unsafe")
      FileUtils.mkdir_p(unsafe, mode: 0o755)
      File.chmod(0o755, unsafe)
      destination_env = File.join(unsafe, "capture")
    when :existing
      FileUtils.mkdir_p(destination)
    end

    write_executable(File.join(bin, "adb"), <<~'SH')
      #!/bin/sh
      set -eu
      printf 'adb %s\n' "$*" >>"$FAKE_AUDIT"
      [ "$1" = -s ] && shift 2
      case "$1" in
        shell)
          shift
          [ "${1:-}" = -n ] && shift
          [ "${1:-}" = -T ] && shift
          if [ "$1 $2" = "am get-current-user" ]; then cat "$FAKE_USER_FILE"; exit 0; fi
          if [ "$1 $2" = "pm grant" ]; then exit 0; fi
          if [ "$1" = run-as ]; then
            shift
            [ "$1" = com.openglucose.app.debug ]; shift
            [ "$1" = --user ] && [ "$2" = 10 ]; shift 2
            [ "$1" = sh ] && [ "$2" = -c ] || exit 2
            pending=$5
            final=$6
            case "$FAKE_HANG:$final" in
              start:*start.json|ack:*ack.json) sleep 20 ;;
            esac
            mkdir -p "$FAKE_DEVICE/${pending%/*}"
            cat >"$FAKE_DEVICE/$pending"
            mv "$FAKE_DEVICE/$pending" "$FAKE_DEVICE/$final"
            printf 'publish %s -> %s\n' "$pending" "$final" >>"$FAKE_AUDIT"
            exit 0
          fi
          ;;
        exec-out)
          shift
          [ "$1" = run-as ]; shift
          [ "$1" = com.openglucose.app.debug ]; shift
          [ "$1" = --user ] && [ "$2" = 10 ]; shift 2
          [ "$1" = cat ]
          relative=$2
          [ "$FAKE_HANG" != pull ] || sleep 20
          if [ "$FAKE_CORRUPT_PULL" = 1 ] && [ "${relative##*/}" = full-records.json ]; then
            printf corrupt
          else
            cat "$FAKE_DEVICE/$relative"
          fi
          exit 0
          ;;
      esac
      exit 1
    SH

    write_executable(File.join(bin, "flutter"), <<~'SH')
      #!/bin/sh
      set -eu
      trap 'printf "flutter-stopped\n" >>"$FAKE_AUDIT"; exit 143' TERM INT
      printf 'flutter-launch %s\n' "$*" >>"$FAKE_AUDIT"
      run=$FAKE_RUN_ID
      relative=files/gs1-private-capture/$run
      mkdir -p "$FAKE_DEVICE/$relative"
      printf 'flutter-armed\n' >>"$FAKE_AUDIT"
      printf 'CBIO-CAPTURE-ARMED run=%s start=start.json\n' "$run"
      until [ -f "$FAKE_DEVICE/$relative/start.json" ]; do sleep 0.02; done
      printf 'flutter-start-seen\n' >>"$FAKE_AUDIT"
      printf 'CBIO-CAPTURE-STARTED run=%s\n' "$run"
      ruby -rjson -rdigest -e '
        root, run, revision, target, mutation_path = ARGV
        mutation = mutation_path.empty? ? nil : JSON.parse(File.read(mutation_path))
        apply = lambda do |name, value|
          next value unless mutation && mutation.fetch("artifact") == name
          cursor = value
          path = mutation.fetch("path")
          path[0...-1].each { |key| cursor = cursor.fetch(key) }
          mutation["delete"] ? cursor.delete(path.last) : cursor[path.last] = mutation["value"]
          value
        end
        full = apply.call("full", {
          "schemaVersion" => 1, "driverId" => "cbio", "profile" => "raw08-observed",
          "sensorKey" => target, "captureId" => run, "state" => "pending",
          "bootstrap" => {"kind" => "fresh"}, "records" => []
        })
        prompt = apply.call("prompt", {
          "schemaVersion" => 1, "runId" => run, "observed" => false,
          "matchCount" => 0, "maskedBytesHex" => nil
        })
        digests = ["0" * 64, "1" * 64, "2" * 64]
        audit = apply.call("audit", {
          "schemaVersion" => 1, "runId" => run,
          "attemptedFrameSha256" => digests.dup,
          "successfulFrameSha256" => digests.dup,
          "writeGateFailed" => false, "commandSequenceComplete" => true
        })
        full_json = JSON.generate(full)
        prompt_json = JSON.generate(prompt)
        audit_json = JSON.generate(audit)
        full_sha = Digest::SHA256.hexdigest(full_json)
        prompt_sha = Digest::SHA256.hexdigest(prompt_json)
        audit_sha = Digest::SHA256.hexdigest(audit_json)
        manifest = {
          "schemaVersion" => 1, "sourceRevision" => revision,
          "packageId" => "com.openglucose.app.debug", "runId" => run,
          "replayContext" => "V1.1.6A", "labelSha256" => "c" * 64,
          "artifactSha256" => full_sha, "artifactBytes" => full_json.bytesize,
          "authPromptReceiptSha256" => prompt_sha,
          "commandAuditSha256" => audit_sha, "commandAuditBytes" => audit_json.bytesize,
          "authPromptObserved" => prompt["observed"], "authPromptMatchCount" => prompt["matchCount"],
          "versionEvidence" => prompt["observed"] ? "incoming_auth_prompt_exact_match" : "declared_context_only",
          "driverStage" => "disconnected", "driverError" => nil,
          "identityMatched" => true, "topologyMatched" => true,
          "attemptedWriteCount" => 3, "successfulWriteCount" => 3,
          "commandSequenceComplete" => true, "state" => "pending", "bootstrap" => "fresh",
          "prefixValid" => false, "recordCount" => 0, "firstIndex" => nil,
          "lastIndex" => nil, "indexGapCount" => 0, "rawTimeBreakCount" => 0,
          "rawTimeSegmentCount" => 0, "anchorPresent" => false,
          "historyWindowClosed" => false,
          "retainedTailProof" => "unavailable_no_protocol_watermark",
          "captureCompleteness" => "authenticated_query_no_records"
        }
        manifest = apply.call("manifest", manifest)
        File.write(File.join(root, "full-records.json"), full_json)
        File.write(File.join(root, "auth-prompt-receipt.json"), prompt_json)
        File.write(File.join(root, "command-audit.json"), audit_json)
        File.write(File.join(root, "manifest.json"), JSON.generate(manifest))
      ' "$FAKE_DEVICE/$relative" "$run" "$FAKE_SOURCE_REVISION" "$FAKE_TARGET" "$FAKE_MUTATION_FILE"
      full_bytes=$(wc -c <"$FAKE_DEVICE/$relative/full-records.json" | tr -d ' ')
      full_sha=$(shasum -a 256 "$FAKE_DEVICE/$relative/full-records.json" | awk '{print $1}')
      manifest_bytes=$(wc -c <"$FAKE_DEVICE/$relative/manifest.json" | tr -d ' ')
      manifest_sha=$(shasum -a 256 "$FAKE_DEVICE/$relative/manifest.json" | awk '{print $1}')
      prompt_bytes=$(wc -c <"$FAKE_DEVICE/$relative/auth-prompt-receipt.json" | tr -d ' ')
      prompt_sha=$(shasum -a 256 "$FAKE_DEVICE/$relative/auth-prompt-receipt.json" | awk '{print $1}')
      audit_bytes=$(wc -c <"$FAKE_DEVICE/$relative/command-audit.json" | tr -d ' ')
      audit_sha=$(shasum -a 256 "$FAKE_DEVICE/$relative/command-audit.json" | awk '{print $1}')
      [ "$FAKE_SWITCH_AFTER_READY" != 1 ] || printf '0\n' >"$FAKE_USER_FILE"
      printf 'CBIO-CAPTURE-READY run=%s full=full-records.json full_bytes=%s full_sha=%s manifest=manifest.json manifest_bytes=%s manifest_sha=%s prompt=auth-prompt-receipt.json prompt_bytes=%s prompt_sha=%s outcome=authenticated_query_no_records audit=command-audit.json audit_bytes=%s audit_sha=%s ack=ack.json\n' \
        "$run" "$full_bytes" "$full_sha" "$manifest_bytes" "$manifest_sha" "$prompt_bytes" "$prompt_sha" "$audit_bytes" "$audit_sha"
      until [ -f "$FAKE_DEVICE/$relative/ack.json" ]; do sleep 0.02; done
      for name in full-records.json manifest.json auth-prompt-receipt.json command-audit.json; do
        [ ! -e "$FAKE_DESTINATION/$name" ] || exit 9
      done
      printf 'flutter-ack-seen\n' >>"$FAKE_AUDIT"
    SH

    actual_destination = destination_env.start_with?("/") ? destination_env : File.join(private_root, destination_env)
    env = {
      "LC_ALL" => "C", "LANG" => "C",
      "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
      "DEVICE_ID" => "FAKE-DEVICE", "ANDROID_USER_ID" => "10",
      "CBIO_DART_DEFINE_FROM_FILE" => context_env, "CAPTURE_DIR" => destination_env,
      "CBIO_BUILD_TIMEOUT_SECONDS" => "10",
      "CBIO_CAPTURE_TIMEOUT_SECONDS" => if hang == :ack
        "2"
      elsif hang
        "1"
      else
        "3"
      end,
      "FAKE_AUDIT" => audit, "FAKE_DEVICE" => device, "FAKE_USER_FILE" => user_file,
      "FAKE_RUN_ID" => RUN_ID, "FAKE_SOURCE_REVISION" => head, "FAKE_TARGET" => DEVICE_ID,
      "FAKE_MUTATION_FILE" => mutation ? mutation_file : "",
      "FAKE_CORRUPT_PULL" => corrupt_pull ? "1" : "0",
      "FAKE_SWITCH_AFTER_READY" => switch_after_ready ? "1" : "0",
      "FAKE_HANG" => hang.to_s, "FAKE_DESTINATION" => actual_destination
    }
    script = File.join(repo, "scripts", "cbio-gs1-private-capture.sh")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3(env, script, chdir: private_root)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    yield({
      root: root, repo: repo, device: device, destination: actual_destination,
      audit: audit, stdout: stdout, stderr: stderr, status: status, elapsed: elapsed,
      flutter_log: File.file?(File.join(actual_destination, "flutter.log")) ?
        File.read(File.join(actual_destination, "flutter.log")) : "",
      quarantine_sizes: Dir.glob(File.join(actual_destination, "quarantine", "*")).to_h do |path|
        [File.basename(path), File.file?(path) ? File.size(path) : nil]
      end
    })
  end
end

def ack_path(result)
  File.join(result[:device], "files", "gs1-private-capture", RUN_ID, "ack.json")
end

def assert_rejected(result, label, pulled: false)
  assert(!result[:status].success?, "#{label} unexpectedly succeeded")
  assert(!File.exist?(ack_path(result)), "#{label} was ACKed")
  FINAL_ARTIFACTS.each do |name|
    assert(!File.exist?(File.join(result[:destination], name)), "#{label} promoted #{name}")
  end
  return unless pulled

  quarantine = File.join(result[:destination], "quarantine")
  assert(File.directory?(quarantine), "#{label} missing quarantine")
  assert(File.stat(quarantine).mode & 0o777 == 0o700, "#{label} quarantine mode")
  assert(Dir.children(quarantine).any?, "#{label} quarantine is empty")
  Dir.children(quarantine).each do |name|
    path = File.join(quarantine, name)
    assert(File.stat(path).mode & 0o777 == 0o600, "#{label} quarantine file mode") if File.file?(path)
  end
end

run_capture do |result|
  assert(
    result[:status].success?,
    "happy path failed: #{result[:stderr]} log=#{result[:flutter_log]} quarantine=#{result[:quarantine_sizes]}"
  )
  assert(File.stat(result[:destination]).mode & 0o777 == 0o700, "destination mode")
  FINAL_ARTIFACTS.each do |name|
    path = File.join(result[:destination], name)
    assert(File.file?(path), "missing #{name}")
    assert(File.stat(path).mode & 0o777 == 0o600, "#{name} mode")
  end
  audit = File.read(result[:audit])
  run_as = audit.lines.grep(/run-as/)
  assert(!run_as.empty? && run_as.all? { |line| line.include?("--user 10") }, "user-bound run-as")
  assert(audit.lines.grep(/pm grant/).all? { |line| line.include?("--user 10") }, "user-bound grants")
  assert(audit.include?("start.json.pending -> files/gs1-private-capture/#{RUN_ID}/start.json"), "START was not atomic")
  assert(audit.include?("ack.json.pending -> files/gs1-private-capture/#{RUN_ID}/ack.json"), "ACK was not atomic")
  assert(audit.index("flutter-armed") < audit.index("flutter-start-seen"), "START after ARMED")
  assert(audit.index("flutter-start-seen") < audit.index("flutter-ack-seen"), "ACK after START")
end

run_capture(allow_expected_untracked: true) do |result|
  assert(result[:status].success?, "exact preserved untracked path was rejected: #{result[:stderr]}")
end

%i[tracked staged untracked].each do |change|
  run_capture(source_change: change) { |result| assert_rejected(result, "#{change} source") }
end

%i[relative inside_repo symlink bad_mode unsafe_parent].each do |variant|
  run_capture(context_case: variant) { |result| assert_rejected(result, "#{variant} context") }
end

%i[relative inside_repo symlink_parent unsafe_parent existing].each do |variant|
  run_capture(destination_case: variant) { |result| assert_rejected(result, "#{variant} destination") }
end

run_capture(corrupt_pull: true) { |result| assert_rejected(result, "corrupt pull", pulled: true) }

%i[start pull ack].each do |stage|
  run_capture(hang: stage) do |result|
    assert_rejected(result, "hung #{stage}", pulled: stage != :start)
    assert(result[:elapsed] < 5, "hung #{stage} exceeded watchdog: #{result[:elapsed]}")
    assert(File.read(result[:audit]).include?("flutter-stopped"), "hung #{stage} did not stop Flutter")
    expected_error = {
      start: "START publication exceeded",
      pull: "full-record pull exceeded",
      ack: "ACK publication exceeded"
    }.fetch(stage)
    assert(result[:stderr].include?(expected_error), "hung #{stage} masked its watchdog failure")
  end
end

manifest_mutations = {
  "schemaVersion" => 2, "sourceRevision" => "0" * 40, "packageId" => "invalid",
  "runId" => "f" * 32, "replayContext" => "invalid", "labelSha256" => "d" * 64,
  "artifactSha256" => "e" * 64, "artifactBytes" => 999,
  "authPromptReceiptSha256" => "f" * 64, "commandAuditSha256" => "a" * 64,
  "commandAuditBytes" => 999, "authPromptObserved" => "false",
  "authPromptMatchCount" => -1, "versionEvidence" => "invalid",
  "driverStage" => "invalid", "driverError" => 1, "identityMatched" => false,
  "topologyMatched" => false, "attemptedWriteCount" => 4,
  "successfulWriteCount" => 2, "commandSequenceComplete" => false,
  "state" => "observing", "bootstrap" => "legacy", "prefixValid" => true,
  "recordCount" => 1, "firstIndex" => 1, "lastIndex" => 1,
  "indexGapCount" => 1, "rawTimeBreakCount" => 1, "rawTimeSegmentCount" => 1,
  "anchorPresent" => true, "historyWindowClosed" => "false",
  "retainedTailProof" => "invalid", "captureCompleteness" => "no_authenticated_raw_query"
}
manifest_mutations.each do |field, value|
  mutation = {"artifact" => "manifest", "path" => [field], "value" => value}
  run_capture(mutation: mutation) { |result| assert_rejected(result, "manifest #{field}", pulled: true) }
end

[
  {"artifact" => "manifest", "path" => ["runId"], "delete" => true},
  {"artifact" => "prompt", "path" => ["runId"], "value" => "f" * 32},
  {"artifact" => "prompt", "path" => ["observed"], "value" => true},
  {"artifact" => "prompt", "path" => ["maskedBytesHex"], "value" => "33" * 5},
  {"artifact" => "audit", "path" => ["runId"], "value" => "f" * 32},
  {"artifact" => "audit", "path" => ["attemptedFrameSha256"], "value" => ["0" * 64, "1" * 64]},
  {"artifact" => "audit", "path" => ["successfulFrameSha256"], "value" => ["2" * 64, "1" * 64, "0" * 64]},
  {"artifact" => "audit", "path" => ["writeGateFailed"], "value" => true},
  {"artifact" => "audit", "path" => ["commandSequenceComplete"], "value" => false},
  {"artifact" => "full", "path" => ["captureId"], "value" => "f" * 32}
].each_with_index do |mutation, index|
  run_capture(mutation: mutation) { |result| assert_rejected(result, "cross-artifact mutation #{index}", pulled: true) }
end

run_capture(switch_after_ready: true) do |result|
  assert_rejected(result, "Owner switch")
  assert(result[:stderr].include?("current Android user"), "missing user-switch failure")
end

run_capture(initial_user: "0") do |result|
  assert_rejected(result, "Owner launch")
  assert(!File.read(result[:audit]).include?("flutter-launch"), "Flutter launched before the user-10 check")
end

puts "cbio-gs1-private-capture contract: PASS"
