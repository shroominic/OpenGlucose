#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
SCRIPT = File.join(__dir__, "cbio-gs1-private-capture.sh")

class String
  def shellescape
    "'#{gsub("'", %q('\\''))}'"
  end
end

HEAD = `git -C #{ROOT.shellescape} rev-parse HEAD`.strip

def assert(condition, message)
  raise message unless condition
end

def write_executable(path, body)
  File.write(path, body)
  File.chmod(0o755, path)
end

def run_capture(corrupt_pull: false, switch_after_ready: false, initial_user: "10")
  Dir.mktmpdir("cbio-private-capture-contract.") do |root|
    bin = File.join(root, "bin")
    device = File.join(root, "device")
    destination = File.join(root, "destination")
    audit = File.join(root, "audit.log")
    user_file = File.join(root, "current-user")
    context = File.join(root, "context.json")
    FileUtils.mkdir_p(bin)
    File.write(user_file, "#{initial_user}\n")
    values = {
      "CBIO_VENDOR_STREAM_KEY_HEX" => "00" * 16,
      "CBIO_VENDOR_AUTH_MATERIAL_HEX" => "11" * 16,
      "CBIO_VENDOR_AUTH_TRIGGER_HEX" => "22" * 5,
      "CBIO_CAPTURE_RUN_ID" => "0123456789abcdef0123456789abcdef",
      "CBIO_CAPTURE_START_NONCE" => "a" * 32,
      "CBIO_CAPTURE_ACK_NONCE" => "b" * 32,
      "CBIO_TARGET_DEVICE_ID" => "AA:BB:CC:DD:EE:FF",
      "CBIO_EXPECTED_SERIAL_HEX" => "ffeeddccbbaa",
      "CBIO_LABEL_SHA256" => "c" * 64,
      "CBIO_REPLAY_CONTEXT" => "V1.1.6A",
      "CBIO_RAW_START_INDEX" => "1",
      "CBIO_SOURCE_REVISION" => HEAD
    }
    File.write(context, JSON.generate(values))
    File.chmod(0o600, context)

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
          if [ "$1 $2" = "am get-current-user" ]; then
            cat "$FAKE_USER_FILE"
            exit 0
          fi
          if [ "$1 $2" = "pm grant" ]; then
            exit 0
          fi
          [ "${1:-}" = -T ] && shift
          if [ "$1" = run-as ]; then
            shift
            package=$1
            shift
            [ "$1" = --user ]
            [ "$2" = 10 ]
            shift 2
            if [ "$1" = tee ]; then
              relative=$2
              mkdir -p "$FAKE_DEVICE/${relative%/*}"
              cat >"$FAKE_DEVICE/$relative"
              exit 0
            fi
          fi
          ;;
        exec-out)
          shift
          [ "$1" = run-as ]
          shift
          package=$1
          shift
          [ "$1" = --user ]
          [ "$2" = 10 ]
          shift 2
          [ "$1" = cat ]
          relative=$2
          if [ "${FAKE_CORRUPT_PULL:-0}" = 1 ] &&
             [ "${relative##*/}" = full-records.json ]; then
            printf 'corrupt'
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
      printf 'flutter-launch %s\n' "$*" >>"$FAKE_AUDIT"
      sleep 1
      run=$FAKE_RUN_ID
      relative=files/gs1-private-capture/$run
      mkdir -p "$FAKE_DEVICE/$relative"
      printf 'flutter-armed\n' >>"$FAKE_AUDIT"
      printf 'CBIO-CAPTURE-ARMED run=%s start=start.json\n' "$run"
      until [ -f "$FAKE_DEVICE/$relative/start.json" ]; do sleep 0.05; done
      printf 'flutter-start-seen\n' >>"$FAKE_AUDIT"
      printf 'CBIO-CAPTURE-STARTED run=%s\n' "$run"
      printf '{"private":"full"}\n' >"$FAKE_DEVICE/$relative/full-records.json"
      full_bytes=$(wc -c <"$FAKE_DEVICE/$relative/full-records.json" | tr -d ' ')
      full_sha=$(LC_ALL=C shasum -a 256 "$FAKE_DEVICE/$relative/full-records.json" | awk '{print $1}')
      printf '{"schemaVersion":1,"runId":"%s","observed":false,"matchCount":0,"maskedBytesHex":null}' "$run" \
        >"$FAKE_DEVICE/$relative/auth-prompt-receipt.json"
      prompt_bytes=$(wc -c <"$FAKE_DEVICE/$relative/auth-prompt-receipt.json" | tr -d ' ')
      prompt_sha=$(LC_ALL=C shasum -a 256 "$FAKE_DEVICE/$relative/auth-prompt-receipt.json" | awk '{print $1}')
      ruby -rjson -e '
        File.write(ARGV[0], JSON.generate({
          "schemaVersion" => 1,
          "sourceRevision" => ARGV[3],
          "packageId" => "com.openglucose.app.debug",
          "runId" => ARGV[1],
          "replayContext" => "V1.1.6A",
          "labelSha256" => "c" * 64,
          "artifactSha256" => ARGV[2],
          "artifactBytes" => ARGV[4].to_i,
          "authPromptReceiptSha256" => ARGV[5],
          "authPromptObserved" => false,
          "authPromptMatchCount" => 0,
          "versionEvidence" => "declared_context_only",
          "driverStage" => "disconnected",
          "driverError" => nil,
          "identityMatched" => true,
          "topologyMatched" => true,
          "attemptedWriteCount" => 3,
          "successfulWriteCount" => 3,
          "commandSequenceComplete" => true,
          "state" => "pending",
          "bootstrap" => "fresh",
          "prefixValid" => false,
          "recordCount" => 0,
          "firstIndex" => nil,
          "lastIndex" => nil,
          "indexGapCount" => 0,
          "rawTimeBreakCount" => 0,
          "rawTimeSegmentCount" => 0,
          "anchorPresent" => false,
          "historyWindowClosed" => false,
          "captureCompleteness" => "authenticated_query_no_records",
          "retainedTailProof" => "unavailable_no_protocol_watermark"
        }))
      ' "$FAKE_DEVICE/$relative/manifest.json" "$run" "$full_sha" "$FAKE_SOURCE_REVISION" "$full_bytes" "$prompt_sha"
      manifest_bytes=$(wc -c <"$FAKE_DEVICE/$relative/manifest.json" | tr -d ' ')
      manifest_sha=$(LC_ALL=C shasum -a 256 "$FAKE_DEVICE/$relative/manifest.json" | awk '{print $1}')
      [ "${FAKE_SWITCH_AFTER_READY:-0}" != 1 ] || printf '0\n' >"$FAKE_USER_FILE"
      printf 'CBIO-CAPTURE-READY run=%s full=full-records.json full_bytes=%s full_sha=%s manifest=manifest.json manifest_bytes=%s manifest_sha=%s prompt=auth-prompt-receipt.json prompt_bytes=%s prompt_sha=%s outcome=authenticated_query_no_records ack=ack.json\n' \
        "$run" "$full_bytes" "$full_sha" "$manifest_bytes" "$manifest_sha" "$prompt_bytes" "$prompt_sha"
      until [ -f "$FAKE_DEVICE/$relative/ack.json" ]; do sleep 0.05; done
      printf 'flutter-ack-seen\n' >>"$FAKE_AUDIT"
    SH

    env = {
      "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
      "DEVICE_ID" => "FAKE-DEVICE",
      "ANDROID_USER_ID" => "10",
      "CBIO_DART_DEFINE_FROM_FILE" => context,
      "CAPTURE_DIR" => destination,
      "CBIO_BUILD_TIMEOUT_SECONDS" => "10",
      "FAKE_AUDIT" => audit,
      "FAKE_DEVICE" => device,
      "FAKE_USER_FILE" => user_file,
      "FAKE_RUN_ID" => values.fetch("CBIO_CAPTURE_RUN_ID"),
      "FAKE_SOURCE_REVISION" => HEAD,
      "FAKE_CORRUPT_PULL" => corrupt_pull ? "1" : "0",
      "FAKE_SWITCH_AFTER_READY" => switch_after_ready ? "1" : "0"
    }
    stdout, stderr, status = Open3.capture3(env, SCRIPT)
    yield({
      root: root,
      device: device,
      destination: destination,
      audit: audit,
      stdout: stdout,
      stderr: stderr,
      status: status
    })
  end
end

run_capture do |result|
  assert(result[:status].success?, "happy path failed: #{result[:stderr]}")
  assert(File.stat(result[:destination]).mode & 0o777 == 0o700, "destination mode")
  %w[full-records.json manifest.json auth-prompt-receipt.json].each do |name|
    path = File.join(result[:destination], name)
    assert(File.file?(path), "missing #{name}")
    assert(File.stat(path).mode & 0o777 == 0o600, "#{name} mode")
  end
  audit = File.read(result[:audit])
  run_as = audit.lines.grep(/run-as/)
  assert(!run_as.empty? && run_as.all? { |line| line.include?("--user 10") }, "user-bound run-as")
  assert(audit.lines.grep(/pm grant/).all? { |line| line.include?("--user 10") }, "user-bound grants")
  assert(audit.index("flutter-armed") < audit.index("flutter-start-seen"), "START after ARMED")
  assert(audit.index("flutter-start-seen") < audit.index("flutter-ack-seen"), "ACK after START")
end

run_capture(corrupt_pull: true) do |result|
  assert(!result[:status].success?, "corrupt pull unexpectedly succeeded")
  ack = File.join(result[:device], "files/gs1-private-capture/0123456789abcdef0123456789abcdef/ack.json")
  assert(!File.exist?(ack), "corrupt pull was ACKed")
end

run_capture(switch_after_ready: true) do |result|
  assert(!result[:status].success?, "Owner switch unexpectedly succeeded")
  ack = File.join(result[:device], "files/gs1-private-capture/0123456789abcdef0123456789abcdef/ack.json")
  assert(!File.exist?(ack), "Owner-0 switch was ACKed")
  assert(result[:stderr].include?("current Android user"), "missing user-switch failure")
end

run_capture(initial_user: "0") do |result|
  assert(!result[:status].success?, "Owner launch unexpectedly succeeded")
  audit = File.read(result[:audit])
  assert(!audit.include?("flutter-launch"), "Flutter launched before the user-10 check")
  assert(result[:stderr].include?("current Android user"), "missing initial-user failure")
end

puts "cbio-gs1-private-capture contract: PASS"
