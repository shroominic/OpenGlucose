#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

SCRIPT = File.expand_path("../openhealth/scripts/testflight-ledger.sh", __dir__)

# Git exports repository-local variables while running hooks. Keep fixture Git
# commands isolated from the caller; the hostile-environment case below passes
# these variables back explicitly to exercise the production sanitizer.
%w[
  GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_ASKPASS
  GIT_COMMON_DIR
  GIT_CONFIG
  GIT_CONFIG_COUNT
  GIT_CONFIG_GLOBAL
  GIT_CONFIG_NOSYSTEM
  GIT_CONFIG_PARAMETERS
  GIT_CONFIG_SYSTEM
  GIT_DEFAULT_HASH
  GIT_DIR
  GIT_GRAFT_FILE
  GIT_IMPLICIT_WORK_TREE
  GIT_INDEX_FILE
  GIT_NAMESPACE
  GIT_NO_REPLACE_OBJECTS
  GIT_OBJECT_DIRECTORY
  GIT_PREFIX
  GIT_QUARANTINE_PATH
  GIT_REDIRECT_STDERR
  GIT_REPLACE_REF_BASE
  GIT_SHALLOW_FILE
  GIT_SSH
  GIT_SSH_COMMAND
  GIT_SSH_VARIANT
  GIT_TEMPLATE_DIR
  GIT_TERMINAL_PROMPT
  GIT_TRACE
  GIT_TRACE2
  GIT_TRACE2_EVENT
  GIT_TRACE_CURL
  GIT_TRACE_CURL_NO_DATA
  GIT_TRACE_PACKET
  GIT_TRACE_PERFORMANCE
  GIT_TRACE_SETUP
  GIT_TRACE_SHALLOW
  GIT_WORK_TREE
].each { |variable| ENV.delete(variable) }
ENV.keys.grep(/\AGIT_CONFIG_(?:KEY|VALUE)_\d+\z/).each { |variable| ENV.delete(variable) }

def assert(condition, message)
  raise "assertion failed: #{message}" unless condition
end

def tree_manifest(root)
  entries = []
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
    basename = File.basename(path)
    next if basename == "." || basename == ".."

    relative = path.delete_prefix("#{root}/")
    stat = File.lstat(path)
    if stat.symlink?
      entries << [relative, "symlink", stat.mode & 0o777, File.readlink(path)]
    elsif stat.directory?
      entries << [relative, "directory", stat.mode & 0o777]
    else
      entries << [relative, "file", stat.mode & 0o777, stat.size, Digest::SHA256.file(path).hexdigest]
    end
  end
  entries.sort
end

def run_command(*command, env: {}, stdin_data: nil)
  options = {}
  options[:stdin_data] = stdin_data unless stdin_data.nil?
  Open3.capture3(env, *command, **options)
end

def require_success(result, label)
  stdout, stderr, status = result
  return stdout if status.success?

  raise "#{label} failed (#{status.exitstatus}): #{stderr}"
end

def require_failure(result, fragment, label)
  stdout, stderr, status = result
  assert(!status.success?, "#{label} must fail")
  assert(stdout.empty?, "#{label} must not write success output")
  assert(stderr.include?(fragment), "#{label} returned an unexpected error: #{stderr}")
  stderr
end

def write_record(directory, name, payload, mode)
  path = File.join(directory, name)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write("#{JSON.generate(payload)}\n")
    file.flush
    file.fsync
  end
  File.chmod(mode, path)
  path
end

def ledger_env(remote)
  {
    "TESTFLIGHT_LEDGER_TEST_MODE" => "local",
    "TESTFLIGHT_LEDGER_REPOSITORY_URL" => remote,
    "TESTFLIGHT_LEDGER_BUNDLE_ID" => "com.shroominic.openglucose",
    "TESTFLIGHT_LEDGER_PLATFORM" => "ios",
    "TESTFLIGHT_LEDGER_VERSION" => "0.1.0",
    "TESTFLIGHT_LEDGER_BUILD_NUMBER" => "18",
    "TESTFLIGHT_LEDGER_SENTINEL_SECRET" => "must-never-be-printed"
  }
end

def run_ledger(env, *arguments)
  run_command(SCRIPT, *arguments, env: env)
end

def ref_for(kind)
  components = {
    "b" => "com.shroominic.openglucose",
    "p" => "ios",
    "v" => "0.1.0"
  }.map { |prefix, value| "#{prefix}#{value.unpack1("H*")}" }.join("-")
  "refs/tags/testflight-ledger-v1/#{components}-n18-#{kind}"
end

def git_output(remote, *arguments)
  require_success(
    run_command("git", "--git-dir", remote, *arguments),
    "git #{arguments.join(" ")}"
  ).strip
end

def remote_record(remote, kind)
  git_output(remote, "show", "#{ref_for(kind)}:record.json") + "\n"
end

def assert_direct_parent(remote, kind, expected_parent_kind)
  commit = git_output(remote, "rev-parse", ref_for(kind))
  headers = git_output(remote, "cat-file", "-p", commit).split("\n\n", 2).fetch(0)
  parents = headers.lines.grep(/^parent /).map { |line| line.split.fetch(1) }
  expected = if expected_parent_kind
               [git_output(remote, "rev-parse", ref_for(expected_parent_kind))]
             else
               []
             end
  assert(parents == expected, "#{kind} must have exactly the expected direct parent")
end

script_source = File.read(SCRIPT)
assert(!script_source.include?("stat -f"), "ledger mode checks must not use platform-ambiguous stat flags")
assert(!script_source.include?("update-ref"), "ledger client must not expose ref updates")
assert(!script_source.match?(/git[^\n]*\s--(?:delete|force)\b/), "ledger client must not force or delete refs")
assert(!script_source.match?(/push[^\n]*\s\+[^\n]*:/), "ledger client must not use a forced refspec")
host_key = script_source[/^readonly GITHUB_ED25519_HOST_KEY='([^']+)'$/, 1]
host_fingerprint = script_source[/^readonly GITHUB_ED25519_FINGERPRINT='([^']+)'$/, 1]
assert(host_key&.start_with?("github.com ssh-ed25519 "), "GitHub ED25519 host key must be pinned")
assert(
  host_fingerprint == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
  "GitHub ED25519 fingerprint must match GitHub's published fingerprint"
)

Dir.mktmpdir("openglucose-ledger-host-key") do |directory|
  known_hosts = File.join(directory, "known_hosts")
  File.write(known_hosts, "#{host_key}\n", mode: "wb", perm: 0o600)
  fingerprint = require_success(
    run_command("ssh-keygen", "-lf", known_hosts, "-E", "sha256"),
    "host-key fingerprint verification"
  )
  assert(fingerprint.include?(host_fingerprint), "embedded GitHub host key must match the pinned fingerprint")
  assert(fingerprint.include?("(ED25519)"), "embedded GitHub host key must be ED25519")
end

Dir.mktmpdir("openglucose-ledger-test") do |directory|
  directory = File.realpath(directory)
  File.chmod(0o700, directory)
  remote = File.join(directory, "ledger.git")
  require_success(run_command("git", "init", "--quiet", "--bare", remote), "bare ledger initialization")
  env = ledger_env(remote)

  source_commit = "a" * 40
  ipa_sha256 = "b" * 64
  app_id = "11111111-1111-1111-1111-111111111111"
  build_id = "22222222-2222-2222-2222-222222222222"
  attempt_id = "33333333-3333-3333-3333-333333333333"

  records = File.join(directory, "records")
  Dir.mkdir(records, 0o700)
  attempt_payload = {
    "schemaVersion" => 1,
    "kind" => "testflightUploadAttempt",
    "appId" => app_id,
    "bundleId" => env.fetch("TESTFLIGHT_LEDGER_BUNDLE_ID"),
    "version" => env.fetch("TESTFLIGHT_LEDGER_VERSION"),
    "buildNumber" => env.fetch("TESTFLIGHT_LEDGER_BUILD_NUMBER"),
    "sourceCommit" => source_commit,
    "ipaSha256" => ipa_sha256,
    "attemptId" => attempt_id,
    "continuationTokenSha256" => "c" * 64,
    "claimedAtUtc" => "2026-08-14T10:00:00Z"
  }
  attempt = write_record(records, "attempt.json", attempt_payload, 0o400)

  hostile_caller = File.join(directory, "hostile-caller")
  require_success(run_command("git", "init", "--quiet", hostile_caller), "hostile caller initialization")
  File.write(File.join(hostile_caller, "tracked.txt"), "caller index sentinel\n", mode: "wb", perm: 0o600)
  require_success(run_command("git", "-C", hostile_caller, "add", "tracked.txt"), "hostile caller index creation")
  require_success(
    run_command("git", "-C", hostile_caller, "config", "testflight-ledger.sentinel", "preserved"),
    "hostile caller config creation"
  )
  caller_git_directory = File.join(hostile_caller, ".git")
  caller_config = File.join(caller_git_directory, "config")
  caller_index = File.join(caller_git_directory, "index")
  caller_config_before = File.binread(caller_config)
  caller_index_before = File.binread(caller_index)
  caller_manifest_before = tree_manifest(hostile_caller)

  hostile_remote = File.join(directory, "hostile-environment.git")
  require_success(run_command("git", "init", "--quiet", "--bare", hostile_remote), "hostile remote initialization")
  hostile_environment = ledger_env(hostile_remote).merge(
    "GIT_ALTERNATE_OBJECT_DIRECTORIES" => File.join(caller_git_directory, "objects"),
    "GIT_COMMON_DIR" => caller_git_directory,
    "GIT_CONFIG" => caller_config,
    "GIT_CONFIG_COUNT" => "1",
    "GIT_CONFIG_KEY_0" => "remote.ledger.url",
    "GIT_CONFIG_PARAMETERS" => "malformed-hostile-config",
    "GIT_CONFIG_VALUE_0" => File.join(directory, "must-not-be-used.git"),
    "GIT_DEFAULT_HASH" => "sha256",
    "GIT_DIR" => caller_git_directory,
    "GIT_GRAFT_FILE" => File.join(caller_git_directory, "hostile-grafts"),
    "GIT_INDEX_FILE" => caller_index,
    "GIT_NAMESPACE" => "hostile-namespace",
    "GIT_OBJECT_DIRECTORY" => File.join(caller_git_directory, "objects"),
    "GIT_PREFIX" => "hostile-prefix/",
    "GIT_REPLACE_REF_BASE" => "refs/hostile-replacements/",
    "GIT_SHALLOW_FILE" => File.join(caller_git_directory, "hostile-shallow"),
    "GIT_SSH_COMMAND" => "false",
    "GIT_SSH_VARIANT" => "plink",
    "GIT_TEMPLATE_DIR" => File.join(directory, "must-not-be-used-template"),
    "GIT_WORK_TREE" => hostile_caller
  )
  require_success(
    run_ledger(hostile_environment, "persist", "upload_attempt", attempt),
    "hostile Git environment publish"
  )
  assert(
    tree_manifest(hostile_caller) == caller_manifest_before,
    "hostile Git environment must not mutate the caller repository"
  )
  assert(File.binread(caller_config) == caller_config_before, "caller config bytes must remain exact")
  assert(File.binread(caller_index) == caller_index_before, "caller index bytes must remain exact")
  _, _, leaked_remote_status = run_command(
    "git",
    "-C",
    hostile_caller,
    "config",
    "--get-regexp",
    "^remote\\.ledger\\."
  )
  assert(!leaked_remote_status.success?, "hostile caller must not gain a ledger remote")
  assert(
    remote_record(hostile_remote, "upload-attempt") == File.binread(attempt),
    "sanitized client must publish only to the requested scratch remote"
  )

  concurrent_remote = File.join(directory, "concurrent.git")
  require_success(run_command("git", "init", "--quiet", "--bare", concurrent_remote), "concurrent ledger initialization")
  race_barrier = File.join(directory, "concurrent-push-barrier")
  Dir.mkdir(race_barrier, 0o700)
  race_hook = File.join(concurrent_remote, "hooks", "pre-receive")
  escaped_barrier = Shellwords.escape(race_barrier)
  File.write(
    race_hook,
    <<~HOOK,
      #!/bin/sh
      set -eu
      barrier=#{escaped_barrier}
      mkdir "$barrier/arrival.$$"
      iteration=0
      while [ "$iteration" -lt 400 ]; do
        set -- "$barrier"/arrival.*
        if [ -e "$1" ] && [ "$#" -ge 2 ]; then
          exit 0
        fi
        iteration=$((iteration + 1))
        sleep 0.05
      done
      printf '%s\n' 'concurrent push barrier timed out' >&2
      exit 1
    HOOK
    mode: "wb",
    perm: 0o700
  )
  concurrent_attempt = write_record(
    records,
    "concurrent-attempt.json",
    attempt_payload.merge("attemptId" => "44444444-4444-4444-4444-444444444444"),
    0o400
  )
  ready = Queue.new
  start = Queue.new
  concurrent_runs = [attempt, concurrent_attempt].map do |record|
    Thread.new do
      ready << true
      start.pop
      run_ledger(ledger_env(concurrent_remote), "persist", "upload_attempt", record)
    end
  end
  2.times { ready.pop }
  2.times { start << true }
  concurrent_results = concurrent_runs.map(&:value)
  winners, losers = concurrent_results.partition { |result| result.fetch(2).success? }
  ref_stdout, ref_stderr, ref_status = run_command(
    "git",
    "--git-dir",
    concurrent_remote,
    "for-each-ref",
    "--format=%(refname) %(objectname)",
    "refs/tags/testflight-ledger-v1"
  )
  race_diagnostics = concurrent_results.each_with_index.map do |result, index|
    stdout, stderr, status = result
    "contender #{index + 1}: exit=#{status.exitstatus.inspect} " \
      "stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
  end
  race_diagnostics << "remote refs: exit=#{ref_status.exitstatus.inspect} " \
    "stdout=#{ref_stdout.inspect} stderr=#{ref_stderr.inspect}"
  race_diagnostics = race_diagnostics.join("\n")
  assert(
    winners.length == 1,
    "exactly one concurrent create-only publish must win\n#{race_diagnostics}"
  )
  assert(
    losers.length == 1,
    "exactly one concurrent create-only publish must fail\n#{race_diagnostics}"
  )
  assert(winners.fetch(0).fetch(0) == "upload-attempt\n", "the concurrent winner must report the persisted phase")
  assert(losers.fetch(0).fetch(0).empty?, "the concurrent loser must not report success")
  loser_error = losers.fetch(0).fetch(1)
  assert(
    loser_error.match?(/collid|already exists/),
    "the concurrent loser must report an immutable collision: #{loser_error}"
  )
  concurrent_refs = git_output(
    concurrent_remote,
    "for-each-ref",
    "--format=%(refname)",
    "refs/tags/testflight-ledger-v1"
  ).lines.map(&:strip)
  assert(concurrent_refs == [ref_for("upload-attempt")], "concurrent creates must produce exactly one ref")
  assert(
    [File.binread(attempt), File.binread(concurrent_attempt)].include?(remote_record(concurrent_remote, "upload-attempt")),
    "the concurrent ref must contain one complete contender record"
  )

  restore = File.join(directory, "empty-restore")
  Dir.mkdir(restore, 0o700)
  absent_result = run_ledger(
    env,
    "restore-state",
    File.join(restore, "attempt.json"),
    File.join(restore, "provenance.json"),
    File.join(restore, "notification.json")
  )
  assert(require_success(absent_result, "empty restore") == "absent\n", "empty ledger must report absent")

  attempt_result = run_ledger(env, "persist", "upload_attempt", attempt)
  assert(require_success(attempt_result, "attempt publish") == "upload-attempt\n", "attempt publish must normalize its kind")
  assert(remote_record(remote, "upload-attempt") == File.binread(attempt), "attempt bytes must be exact")
  assert_direct_parent(remote, "upload-attempt", nil)
  refs = git_output(remote, "for-each-ref", "--format=%(refname)", "refs/tags/testflight-ledger-v1").lines.map(&:strip)
  assert(refs == [ref_for("upload-attempt")], "ledger ref must be deterministic and flat")

  collision_error = require_failure(
    run_ledger(env, "persist", "upload-attempt", attempt),
    "already exists",
    "exact attempt collision"
  )
  assert(!collision_error.include?(env.fetch("TESTFLIGHT_LEDGER_SENTINEL_SECRET")), "errors must not print unrelated secrets")

  mismatched_attempt = write_record(
    records,
    "mismatched-attempt.json",
    attempt_payload.merge("attemptId" => "44444444-4444-4444-4444-444444444444"),
    0o400
  )
  require_failure(
    run_ledger(env, "persist", "upload-attempt", mismatched_attempt),
    "does not match",
    "mismatched attempt collision"
  )

  attempt_restore = File.join(directory, "attempt-restore")
  Dir.mkdir(attempt_restore, 0o700)
  restored_attempt = File.join(attempt_restore, "attempt.json")
  attempt_state = run_ledger(
    env,
    "restore-state",
    restored_attempt,
    File.join(attempt_restore, "provenance.json"),
    File.join(attempt_restore, "notification.json")
  )
  assert(require_success(attempt_state, "attempt restore") == "upload-attempt\n", "attempt state must be reported")
  assert(File.binread(restored_attempt) == File.binread(attempt), "restored attempt bytes must be exact")
  assert((File.stat(restored_attempt).mode & 0o777) == 0o400, "restored attempt mode must be 400")

  provenance_payload = {
    "schemaVersion" => 2,
    "kind" => "testflightUploadProvenance",
    "appId" => app_id,
    "bundleId" => env.fetch("TESTFLIGHT_LEDGER_BUNDLE_ID"),
    "buildId" => build_id,
    "buildAudienceType" => "APP_STORE_ELIGIBLE",
    "version" => env.fetch("TESTFLIGHT_LEDGER_VERSION"),
    "buildNumber" => env.fetch("TESTFLIGHT_LEDGER_BUILD_NUMBER"),
    "sourceCommit" => source_commit,
    "ipaSha256" => ipa_sha256,
    "uploadAttemptId" => attempt_id,
    "uploadAttemptSha256" => Digest::SHA256.file(attempt).hexdigest,
    "recordedAtUtc" => "2026-08-14T10:15:00Z"
  }
  invalid_provenance = write_record(
    records,
    "invalid-provenance.json",
    provenance_payload.merge("uploadAttemptSha256" => "d" * 64),
    0o400
  )
  require_failure(
    run_ledger(env, "persist", "upload_provenance", invalid_provenance),
    "does not link",
    "invalid provenance hash"
  )
  _, _, missing_provenance_status = run_command("git", "--git-dir", remote, "show-ref", "--verify", ref_for("upload-provenance"))
  assert(!missing_provenance_status.success?, "invalid provenance must not create a ref")

  provenance = write_record(records, "provenance.json", provenance_payload, 0o400)
  require_success(run_ledger(env, "persist", "upload-provenance", provenance), "provenance publish")
  assert(remote_record(remote, "upload-provenance") == File.binread(provenance), "provenance bytes must be exact")
  assert_direct_parent(remote, "upload-provenance", "upload-attempt")

  external_group = "55555555-5555-5555-5555-555555555555"
  internal_group = "66666666-6666-6666-6666-666666666666"
  claim_id = "77777777-7777-7777-7777-777777777777"
  pending_payload = {
    "schemaVersion" => 3,
    "appId" => app_id,
    "bundleId" => env.fetch("TESTFLIGHT_LEDGER_BUNDLE_ID"),
    "buildId" => build_id,
    "version" => env.fetch("TESTFLIGHT_LEDGER_VERSION"),
    "buildNumber" => env.fetch("TESTFLIGHT_LEDGER_BUILD_NUMBER"),
    "externalGroupId" => external_group,
    "automaticInternalGroupId" => internal_group,
    "associatedGroupIds" => [external_group, internal_group].sort,
    "externalTesterCount" => 23,
    "externalTesterIdsSha256" => "e" * 64,
    "sourceCommit" => source_commit,
    "ipaSha256" => ipa_sha256,
    "status" => "pending",
    "claimId" => claim_id,
    "claimedAtUtc" => "2026-08-14T10:30:00Z"
  }
  notification = write_record(records, "notification.json", pending_payload, 0o600)
  require_success(run_ledger(env, "persist", "notification_pending", notification), "pending notification publish")
  assert(remote_record(remote, "notification-pending") == File.binread(notification), "pending bytes must be exact")
  assert_direct_parent(remote, "notification-pending", "upload-provenance")

  pending_restore = File.join(directory, "pending-restore")
  Dir.mkdir(pending_restore, 0o700)
  pending_notification = File.join(pending_restore, "notification.json")
  pending_state = run_ledger(
    env,
    "restore-state",
    File.join(pending_restore, "attempt.json"),
    File.join(pending_restore, "provenance.json"),
    pending_notification
  )
  assert(require_success(pending_state, "pending restore") == "notification-pending\n", "pending state must be reported")
  assert((File.stat(pending_notification).mode & 0o777) == 0o600, "pending notification mode must be 600")
  assert(File.binread(pending_notification) == File.binread(notification), "pending restore bytes must be exact")

  complete_payload = pending_payload.merge(
    "status" => "complete",
    "notificationId" => "88888888-8888-8888-8888-888888888888",
    "notifiedAtUtc" => "2026-08-14T10:45:00Z"
  )
  File.chmod(0o600, notification)
  File.open(notification, File::WRONLY | File::TRUNC) do |file|
    file.write("#{JSON.generate(complete_payload)}\n")
    file.flush
    file.fsync
  end
  File.chmod(0o400, notification)
  require_success(run_ledger(env, "persist", "notification_complete", notification), "complete notification publish")
  assert(remote_record(remote, "notification-complete") == File.binread(notification), "completion bytes must be exact")
  assert_direct_parent(remote, "notification-complete", "notification-pending")

  complete_restore = File.join(directory, "complete-restore")
  Dir.mkdir(complete_restore, 0o700)
  complete_attempt = File.join(complete_restore, "attempt.json")
  complete_provenance = File.join(complete_restore, "provenance.json")
  complete_notification = File.join(complete_restore, "notification.json")
  complete_state = run_ledger(
    env,
    "restore-state",
    complete_attempt,
    complete_provenance,
    complete_notification
  )
  assert(require_success(complete_state, "complete restore") == "notification-complete\n", "complete state must be reported")
  assert(File.binread(complete_attempt) == File.binread(attempt), "complete restore must hydrate attempt")
  assert(File.binread(complete_provenance) == File.binread(provenance), "complete restore must hydrate provenance")
  assert(File.binread(complete_notification) == File.binread(notification), "complete restore must hydrate completion")
  assert((File.stat(complete_notification).mode & 0o777) == 0o400, "complete notification mode must be 400")

  conflicting_restore = File.join(directory, "conflicting-restore")
  Dir.mkdir(conflicting_restore, 0o700)
  conflicting_attempt = write_record(conflicting_restore, "attempt.json", attempt_payload.merge("attemptId" => "99999999-9999-9999-9999-999999999999"), 0o400)
  require_failure(
    run_ledger(
      env,
      "restore-state",
      conflicting_attempt,
      File.join(conflicting_restore, "provenance.json"),
      File.join(conflicting_restore, "notification.json")
    ),
    "different digest",
    "restore mismatch"
  )

  all_refs = git_output(remote, "for-each-ref", "--format=%(refname)", "refs/tags/testflight-ledger-v1").lines.map(&:strip)
  assert(
    all_refs == %w[notification-complete notification-pending upload-attempt upload-provenance].map { |kind| ref_for(kind) }.sort,
    "the ledger must contain exactly one flat ref per immutable phase"
  )

  gap_remote = File.join(directory, "gap.git")
  require_success(run_command("git", "init", "--quiet", "--bare", gap_remote), "gap ledger initialization")
  gap_blob = require_success(
    run_command("git", "--git-dir", gap_remote, "hash-object", "-w", notification),
    "gap blob creation"
  ).strip
  gap_tree = require_success(
    run_command(
      "git",
      "--git-dir",
      gap_remote,
      "mktree",
      stdin_data: "100644 blob #{gap_blob}\trecord.json\n"
    ),
    "gap tree creation"
  ).strip
  gap_commit = require_success(
    run_command(
      "git",
      "--git-dir",
      gap_remote,
      "-c",
      "user.name=Ledger Test",
      "-c",
      "user.email=ledger@example.invalid",
      "commit-tree",
      gap_tree,
      stdin_data: "gap test\n"
    ),
    "gap commit creation"
  ).strip
  require_success(
    run_command("git", "--git-dir", gap_remote, "update-ref", ref_for("notification-complete"), gap_commit),
    "gap ref creation"
  )
  gap_restore = File.join(directory, "gap-restore")
  Dir.mkdir(gap_restore, 0o700)
  require_failure(
    run_ledger(
      ledger_env(gap_remote),
      "restore-state",
      File.join(gap_restore, "attempt.json"),
      File.join(gap_restore, "provenance.json"),
      File.join(gap_restore, "notification.json")
    ),
    "non-contiguous",
    "non-contiguous remote chain"
  )

  rejected_remote = File.join(directory, "rejected.git")
  require_success(run_command("git", "init", "--quiet", "--bare", rejected_remote), "rejected ledger initialization")
  hook = File.join(rejected_remote, "hooks", "pre-receive")
  File.write(hook, "#!/bin/sh\nprintf '%s\\n' 'SENSITIVE-SERVER-TEXT' >&2\nexit 1\n", mode: "wb", perm: 0o700)
  rejected_error = require_failure(
    run_ledger(ledger_env(rejected_remote), "persist", "upload-attempt", attempt),
    "create-only publish failed",
    "rejected remote publish"
  )
  assert(!rejected_error.include?("SENSITIVE-SERVER-TEXT"), "remote diagnostics must not be echoed")
  assert(!rejected_error.include?(env.fetch("TESTFLIGHT_LEDGER_SENTINEL_SECRET")), "failure output must not contain secrets")
end

puts "TestFlight append-only ledger checks passed."
