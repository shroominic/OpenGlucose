#!/usr/bin/env bash

set -euo pipefail
umask 077

sanitize_git_repository_environment() {
  local variable
  unset \
    GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_ASKPASS \
    GIT_COMMON_DIR \
    GIT_CONFIG \
    GIT_CONFIG_COUNT \
    GIT_CONFIG_GLOBAL \
    GIT_CONFIG_NOSYSTEM \
    GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_SYSTEM \
    GIT_DEFAULT_HASH \
    GIT_DIR \
    GIT_GRAFT_FILE \
    GIT_IMPLICIT_WORK_TREE \
    GIT_INDEX_FILE \
    GIT_NAMESPACE \
    GIT_NO_REPLACE_OBJECTS \
    GIT_OBJECT_DIRECTORY \
    GIT_PREFIX \
    GIT_QUARANTINE_PATH \
    GIT_REDIRECT_STDERR \
    GIT_REPLACE_REF_BASE \
    GIT_SHALLOW_FILE \
    GIT_SSH \
    GIT_SSH_COMMAND \
    GIT_SSH_VARIANT \
    GIT_TEMPLATE_DIR \
    GIT_TERMINAL_PROMPT \
    GIT_TRACE \
    GIT_TRACE2 \
    GIT_TRACE2_EVENT \
    GIT_TRACE_CURL \
    GIT_TRACE_CURL_NO_DATA \
    GIT_TRACE_PACKET \
    GIT_TRACE_PERFORMANCE \
    GIT_TRACE_SETUP \
    GIT_TRACE_SHALLOW \
    GIT_WORK_TREE
  while IFS= read -r variable; do
    [[ "$variable" =~ ^GIT_CONFIG_(KEY|VALUE)_[0-9]+$ ]] && unset "$variable"
  done < <(compgen -A variable GIT_CONFIG_)
}

# Git invokes hooks with repository-local variables such as GIT_DIR exported.
# Clear them before even initializing the private scratch repository so no
# client command can read or mutate the caller's repository, config, or index.
sanitize_git_repository_environment

readonly GITHUB_ED25519_HOST_KEY='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl'
readonly GITHUB_ED25519_FINGERPRINT='SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU'
readonly LEDGER_REF_NAMESPACE='refs/tags/testflight-ledger-v1'
readonly LEDGER_RECORD_NAME='record.json'

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage:' \
    '  testflight-ledger.sh persist KIND ABSOLUTE_RECORD_PATH' \
    '  testflight-ledger.sh restore-state ABSOLUTE_ATTEMPT_PATH ABSOLUTE_PROVENANCE_PATH ABSOLUTE_NOTIFICATION_PATH' >&2
  exit 64
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

portable_mode() {
  ruby -e 'printf "%o\n", File.lstat(ARGV.fetch(0)).mode & 0o777' "$1"
}

normalize_kind() {
  case "$1" in
    upload-attempt|upload_attempt) printf '%s\n' 'upload-attempt' ;;
    upload-provenance|upload_provenance) printf '%s\n' 'upload-provenance' ;;
    notification-pending|notification_pending) printf '%s\n' 'notification-pending' ;;
    notification-complete|notification_complete) printf '%s\n' 'notification-complete' ;;
    *) fail 'ledger record kind is invalid' ;;
  esac
}

previous_kind() {
  case "$1" in
    upload-attempt) return 1 ;;
    upload-provenance) printf '%s\n' 'upload-attempt' ;;
    notification-pending) printf '%s\n' 'upload-provenance' ;;
    notification-complete) printf '%s\n' 'notification-pending' ;;
    *) fail 'internal ledger kind error' ;;
  esac
}

kind_mode() {
  case "$1" in
    notification-pending) printf '%s\n' '600' ;;
    upload-attempt|upload-provenance|notification-complete) printf '%s\n' '400' ;;
    *) fail 'internal ledger kind error' ;;
  esac
}

component_hex() {
  LC_ALL=C od -An -v -tx1 | tr -d ' \n'
}

validate_identity() {
  : "${TESTFLIGHT_LEDGER_BUNDLE_ID:?missing TESTFLIGHT_LEDGER_BUNDLE_ID}"
  : "${TESTFLIGHT_LEDGER_PLATFORM:?missing TESTFLIGHT_LEDGER_PLATFORM}"
  : "${TESTFLIGHT_LEDGER_VERSION:?missing TESTFLIGHT_LEDGER_VERSION}"
  : "${TESTFLIGHT_LEDGER_BUILD_NUMBER:?missing TESTFLIGHT_LEDGER_BUILD_NUMBER}"
  : "${TESTFLIGHT_LEDGER_REPOSITORY_URL:?missing TESTFLIGHT_LEDGER_REPOSITORY_URL}"

  [[ "$TESTFLIGHT_LEDGER_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] ||
    fail 'TESTFLIGHT_LEDGER_BUNDLE_ID is malformed'
  ((${#TESTFLIGHT_LEDGER_BUNDLE_ID} <= 255)) ||
    fail 'TESTFLIGHT_LEDGER_BUNDLE_ID is too long'
  [[ "$TESTFLIGHT_LEDGER_PLATFORM" == 'ios' ]] ||
    fail 'TESTFLIGHT_LEDGER_PLATFORM must be ios'
  [[ "$TESTFLIGHT_LEDGER_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail 'TESTFLIGHT_LEDGER_VERSION must contain three decimal components'
  [[ "$TESTFLIGHT_LEDGER_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] ||
    fail 'TESTFLIGHT_LEDGER_BUILD_NUMBER must be a positive decimal integer'

  local bundle_hex platform_hex version_hex
  bundle_hex=$(printf '%s' "$TESTFLIGHT_LEDGER_BUNDLE_ID" | component_hex)
  platform_hex=$(printf '%s' "$TESTFLIGHT_LEDGER_PLATFORM" | component_hex)
  version_hex=$(printf '%s' "$TESTFLIGHT_LEDGER_VERSION" | component_hex)
  LEDGER_IDENTITY="b${bundle_hex}-p${platform_hex}-v${version_hex}-n${TESTFLIGHT_LEDGER_BUILD_NUMBER}"
  readonly LEDGER_IDENTITY
}

ref_for_kind() {
  printf '%s/%s-%s\n' "$LEDGER_REF_NAMESPACE" "$LEDGER_IDENTITY" "$1"
}

validate_parent_directory() {
  local path=$1
  ruby - "$path" <<'RUBY'
path = ARGV.fetch(0)
abort "path must be absolute" unless path.start_with?("/") && File.expand_path(path) == path
parent = File.dirname(path)
stat = File.lstat(parent)
abort "parent must be a non-symlink directory" unless stat.directory? && !stat.symlink?
abort "parent path must not traverse symlinks" unless File.realpath(parent) == parent
abort "parent directory must have mode 700" unless (stat.mode & 0o777) == 0o700
abort "parent directory must be owned by the current user" unless stat.uid == Process.euid
RUBY
}

validate_record_path() {
  local path=$1 kind=$2 expected_mode
  expected_mode=$(kind_mode "$kind")
  validate_parent_directory "$path" || fail 'ledger record parent directory is unsafe'
  [[ -f "$path" && ! -L "$path" ]] || fail 'ledger record must be a regular non-symlink file'
  [[ "$(portable_mode "$path")" == "$expected_mode" ]] ||
    fail "ledger record must have mode $expected_mode"
}

validate_restore_path() {
  local path=$1
  validate_parent_directory "$path" || fail 'ledger restore parent directory is unsafe'
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -f "$path" && ! -L "$path" ]] ||
      fail 'ledger restore destination must be a regular non-symlink file'
  fi
}

validate_record_schema() {
  local kind=$1 path=$2
  ruby -rjson -rtime - "$kind" "$path" \
    "$TESTFLIGHT_LEDGER_BUNDLE_ID" "$TESTFLIGHT_LEDGER_VERSION" \
    "$TESTFLIGHT_LEDGER_BUILD_NUMBER" <<'RUBY'
require "digest"

class StrictObject < Hash
  def []=(key, value)
    raise JSON::ParserError, "duplicate object key" if key?(key)
    super
  end
end

kind, path, bundle_id, version, build_number = ARGV
bytes = File.binread(path)
abort "record must be one canonical JSON line" unless bytes.end_with?("\n") && !bytes.delete_suffix("\n").include?("\n")
record = JSON.parse(bytes, object_class: StrictObject)
abort "record must be a JSON object" unless record.instance_of?(StrictObject)
abort "record must use canonical compact JSON" unless JSON.generate(record) + "\n" == bytes

schemas = {
  "upload-attempt" => %w[
    appId attemptId buildNumber bundleId claimedAtUtc continuationTokenSha256
    ipaSha256 kind schemaVersion sourceCommit version
  ],
  "upload-provenance" => %w[
    appId buildAudienceType buildId buildNumber bundleId ipaSha256 kind
    recordedAtUtc schemaVersion sourceCommit uploadAttemptId
    uploadAttemptSha256 version
  ],
  "notification-pending" => %w[
    appId associatedGroupIds automaticInternalGroupId buildId buildNumber
    bundleId claimId claimedAtUtc externalGroupId externalTesterCount
    externalTesterIdsSha256 ipaSha256 schemaVersion sourceCommit status version
  ],
  "notification-complete" => %w[
    appId associatedGroupIds automaticInternalGroupId buildId buildNumber
    bundleId claimId claimedAtUtc externalGroupId externalTesterCount
    externalTesterIdsSha256 ipaSha256 notificationId notifiedAtUtc
    schemaVersion sourceCommit status version
  ]
}
abort "record has an unexpected schema" unless record.keys.sort == schemas.fetch(kind).sort
abort "record bundle does not match the ledger identity" unless record["bundleId"] == bundle_id
abort "record version does not match the ledger identity" unless record["version"] == version
abort "record build does not match the ledger identity" unless record["buildNumber"] == build_number

id = /\A[A-Za-z0-9-]+\z/
uuid = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
sha256 = /\A[0-9a-f]{64}\z/
commit = /\A[0-9a-f]{40}\z/
timestamp = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

%w[appId buildId externalGroupId automaticInternalGroupId notificationId].each do |field|
  next unless record.key?(field)
  abort "record #{field} is malformed" unless record[field].is_a?(String) && record[field].match?(id)
end
%w[attemptId uploadAttemptId claimId].each do |field|
  next unless record.key?(field)
  abort "record #{field} is malformed" unless record[field].is_a?(String) && record[field].match?(uuid)
end
%w[ipaSha256 continuationTokenSha256 uploadAttemptSha256 externalTesterIdsSha256].each do |field|
  next unless record.key?(field)
  abort "record #{field} is malformed" unless record[field].is_a?(String) && record[field].match?(sha256)
end
abort "record sourceCommit is malformed" unless record["sourceCommit"].is_a?(String) && record["sourceCommit"].match?(commit)
%w[claimedAtUtc recordedAtUtc notifiedAtUtc].each do |field|
  next unless record.key?(field)
  value = record[field]
  abort "record #{field} is malformed" unless value.is_a?(String) && value.match?(timestamp)
  parsed = Time.iso8601(value)
  abort "record #{field} is not canonical UTC" unless parsed.utc.iso8601 == value
end

case kind
when "upload-attempt"
  abort "upload attempt schema version is invalid" unless record["schemaVersion"] == 1
  abort "upload attempt kind is invalid" unless record["kind"] == "testflightUploadAttempt"
when "upload-provenance"
  abort "upload provenance schema version is invalid" unless record["schemaVersion"] == 2
  abort "upload provenance kind is invalid" unless record["kind"] == "testflightUploadProvenance"
  abort "upload provenance audience is invalid" unless record["buildAudienceType"] == "APP_STORE_ELIGIBLE"
when "notification-pending", "notification-complete"
  abort "notification schema version is invalid" unless record["schemaVersion"] == 3
  expected_status = kind.delete_prefix("notification-")
  abort "notification status is invalid" unless record["status"] == expected_status
  count = record["externalTesterCount"]
  abort "external tester count is invalid" unless count.is_a?(Integer) && count.positive?
  groups = record["associatedGroupIds"]
  abort "associated groups are invalid" unless groups.is_a?(Array) && groups.all? { |value| value.is_a?(String) && value.match?(id) }
  expected_groups = [record["automaticInternalGroupId"], record["externalGroupId"]].uniq.sort
  abort "associated groups do not match the approved groups" unless groups == expected_groups && groups.length == 2
end
RUBY
}

validate_chain() {
  local kind=$1 current_path=$2 previous_path=$3
  ruby -rjson -rdigest - "$kind" "$current_path" "$previous_path" <<'RUBY'
kind, current_path, previous_path = ARGV
current = JSON.parse(File.binread(current_path))
previous_bytes = File.binread(previous_path)
previous = JSON.parse(previous_bytes)

case kind
when "upload-provenance"
  abort "provenance does not link to the exact upload attempt" unless
    current["uploadAttemptSha256"] == Digest::SHA256.hexdigest(previous_bytes) &&
    current["uploadAttemptId"] == previous["attemptId"] &&
    %w[appId bundleId version buildNumber sourceCommit ipaSha256].all? do |field|
      current[field] == previous[field]
    end
when "notification-pending"
  abort "notification does not link to the exact upload provenance" unless
    %w[appId bundleId buildId version buildNumber sourceCommit ipaSha256].all? do |field|
      current[field] == previous[field]
    end
when "notification-complete"
  stable_fields = previous.keys - ["status"]
  abort "notification completion does not link to the exact pending claim" unless
    previous["status"] == "pending" &&
    stable_fields.all? { |field| current[field] == previous[field] }
else
  abort "unexpected chain kind"
end
RUBY
}

setup_transport() {
  local test_mode=${TESTFLIGHT_LEDGER_TEST_MODE:-}
  if [[ -n "$test_mode" && "$test_mode" != 'local' ]]; then
    fail 'TESTFLIGHT_LEDGER_TEST_MODE is invalid'
  fi

  if [[ "$test_mode" == 'local' ]]; then
    [[ "$TESTFLIGHT_LEDGER_REPOSITORY_URL" == /* ]] ||
      fail 'local test ledger must be an absolute path'
    [[ -d "$TESTFLIGHT_LEDGER_REPOSITORY_URL" && ! -L "$TESTFLIGHT_LEDGER_REPOSITORY_URL" ]] ||
      fail 'local test ledger must be a non-symlink directory'
    [[ "$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$TESTFLIGHT_LEDGER_REPOSITORY_URL")" == "$TESTFLIGHT_LEDGER_REPOSITORY_URL" ]] ||
      fail 'local test ledger path must not traverse symlinks'
    [[ "$(git -C "$TESTFLIGHT_LEDGER_REPOSITORY_URL" rev-parse --is-bare-repository 2>/dev/null)" == 'true' ]] ||
      fail 'local test ledger must be a bare Git repository'
    LEDGER_SSH_COMMAND=''
    readonly LEDGER_SSH_COMMAND
    return
  fi

  [[ "$TESTFLIGHT_LEDGER_REPOSITORY_URL" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ||
    fail 'TESTFLIGHT_LEDGER_REPOSITORY_URL must be a GitHub SSH repository URL'
  : "${TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH:?missing TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH}"
  [[ "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
    fail 'TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH is unsafe'
  [[ -f "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" && ! -L "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" ]] ||
    fail 'ledger deploy key must be a regular non-symlink file'
  [[ "$(ruby -e 'print File.realpath(ARGV.fetch(0))' "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH")" == "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" ]] ||
    fail 'ledger deploy key path must not traverse symlinks'
  [[ -O "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" ]] ||
    fail 'ledger deploy key must be owned by the current user'
  case "$(portable_mode "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH")" in
    400|600) ;;
    *) fail 'ledger deploy key must have mode 400 or 600' ;;
  esac
  ssh-keygen -y -P '' -f "$TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH" \
    >"$ledger_work_dir/deploy-key-public" 2>"$ledger_work_dir/deploy-key-error" ||
    fail 'ledger deploy key must be a valid unencrypted SSH private key'

  LEDGER_KNOWN_HOSTS_PATH="$ledger_work_dir/github-known-hosts"
  printf '%s\n' "$GITHUB_ED25519_HOST_KEY" >"$LEDGER_KNOWN_HOSTS_PATH"
  chmod 600 "$LEDGER_KNOWN_HOSTS_PATH"
  local fingerprint key_type key_count
  fingerprint=$(ssh-keygen -lf "$LEDGER_KNOWN_HOSTS_PATH" -E sha256 | awk '{print $2}')
  key_type=$(ssh-keygen -lf "$LEDGER_KNOWN_HOSTS_PATH" -E sha256 | awk '{print $4}')
  key_count=$(ssh-keygen -lf "$LEDGER_KNOWN_HOSTS_PATH" -E sha256 | wc -l | tr -d ' ')
  [[ "$fingerprint" == "$GITHUB_ED25519_FINGERPRINT" && "$key_type" == '(ED25519)' && "$key_count" == '1' ]] ||
    fail 'embedded GitHub ED25519 host key verification failed'

  LEDGER_SSH_COMMAND="ssh -i $TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH -o BatchMode=yes -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PubkeyAuthentication=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$LEDGER_KNOWN_HOSTS_PATH -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=ssh-ed25519"
  readonly LEDGER_KNOWN_HOSTS_PATH LEDGER_SSH_COMMAND
}

transport_git() {
  if [[ -n "$LEDGER_SSH_COMMAND" ]]; then
    GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$LEDGER_SSH_COMMAND" \
      git "$@"
  else
    GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 git "$@"
  fi
}

remote_oid() {
  local ref=$1 output_path=$2 error_path=$3 status=0 output oid returned_ref
  : >"$output_path"
  : >"$error_path"
  transport_git -C "$ledger_git_dir" ls-remote --exit-code --refs ledger "$ref" \
    >"$output_path" 2>"$error_path" || status=$?
  if [[ "$status" == '2' ]]; then
    return 1
  fi
  [[ "$status" == '0' ]] || fail 'remote ledger lookup failed'
  output=$(<"$output_path")
  [[ "$output" == *$'\t'* && "$output" != *$'\n'* ]] ||
    fail 'remote ledger ref response is malformed'
  oid=${output%%$'\t'*}
  returned_ref=${output#*$'\t'}
  [[ "$oid" =~ ^[0-9a-f]{40}$ && "$returned_ref" == "$ref" ]] ||
    fail 'remote ledger ref response is malformed'
  printf '%s\n' "$oid"
}

fetch_ref() {
  local ref=$1 expected_oid=$2 error_path=$3 fetched_oid object_type
  : >"$error_path"
  transport_git -C "$ledger_git_dir" fetch --quiet --no-tags ledger "$ref" \
    2>"$error_path" || fail 'remote ledger fetch failed'
  fetched_oid=$(git -C "$ledger_git_dir" rev-parse --verify FETCH_HEAD)
  [[ "$fetched_oid" == "$expected_oid" ]] || fail 'remote ledger ref changed during verification'
  object_type=$(git -C "$ledger_git_dir" cat-file -t "$fetched_oid")
  [[ "$object_type" == 'commit' ]] || fail 'remote ledger ref must point directly to a commit'
}

read_remote_record() {
  local kind=$1 output_path=$2 ref oid previous previous_ref previous_oid
  local lookup_out="$ledger_work_dir/lookup-$RANDOM" lookup_err="$ledger_work_dir/lookup-error-$RANDOM"
  local fetch_err="$ledger_work_dir/fetch-error-$RANDOM" tree_listing parent_listing blob_oid
  local tree_metadata tree_name tree_mode tree_type tree_extra
  ref=$(ref_for_kind "$kind")
  oid=$(remote_oid "$ref" "$lookup_out" "$lookup_err") || return 1
  fetch_ref "$ref" "$oid" "$fetch_err"

  tree_listing=$(git -C "$ledger_git_dir" ls-tree "$oid")
  [[ "$tree_listing" == *$'\t'* && "$tree_listing" != *$'\n'* ]] ||
    fail 'remote ledger commit tree is malformed'
  tree_metadata=${tree_listing%%$'\t'*}
  tree_name=${tree_listing#*$'\t'}
  read -r tree_mode tree_type blob_oid tree_extra <<<"$tree_metadata"
  [[ "$tree_mode" == '100644' && "$tree_type" == 'blob' && -z "$tree_extra" &&
    "$blob_oid" =~ ^[0-9a-f]{40}$ && "$tree_name" == "$LEDGER_RECORD_NAME" ]] ||
    fail 'remote ledger commit tree is malformed'
  parent_listing=$(
    git -C "$ledger_git_dir" cat-file -p "$oid" |
      sed -n '/^$/q; s/^parent //p'
  )
  if previous=$(previous_kind "$kind"); then
    previous_ref=$(ref_for_kind "$previous")
    previous_oid=$(remote_oid "$previous_ref" "$lookup_out" "$lookup_err") ||
      fail 'remote ledger parent ref is missing'
    [[ "$parent_listing" == "$previous_oid" ]] ||
      fail 'remote ledger parent chain is malformed'
  else
    [[ -z "$parent_listing" ]] || fail 'first remote ledger record must not have a parent'
  fi

  git -C "$ledger_git_dir" cat-file blob "$blob_oid" >"$output_path"
  validate_record_schema "$kind" "$output_path" || fail 'remote ledger record validation failed'
  if previous=$(previous_kind "$kind"); then
    local previous_path="$ledger_work_dir/previous-$kind-$RANDOM.json"
    read_remote_record "$previous" "$previous_path" >/dev/null ||
      fail 'remote ledger parent record is missing'
    validate_chain "$kind" "$output_path" "$previous_path" ||
      fail 'remote ledger record chain validation failed'
  fi
  printf '%s\n' "$oid"
}

ledger_state() {
  local kind ref lookup_out="$ledger_work_dir/state-lookup" lookup_err="$ledger_work_dir/state-error"
  local state='absent' gap='no'
  for kind in upload-attempt upload-provenance notification-pending notification-complete; do
    ref=$(ref_for_kind "$kind")
    if remote_oid "$ref" "$lookup_out" "$lookup_err" >/dev/null; then
      [[ "$gap" == 'no' ]] || fail 'remote ledger contains a non-contiguous record chain'
      state=$kind
    else
      gap='yes'
    fi
  done
  if [[ "$state" != 'absent' ]]; then
    local state_path="$ledger_work_dir/state-$state.json"
    read_remote_record "$state" "$state_path" >/dev/null ||
      fail 'remote ledger state could not be verified'
  fi
  printf '%s\n' "$state"
}

publish_record() {
  local kind=$1 path=$2 state expected_state previous parent_oid=''
  local existing_path="$ledger_work_dir/existing-$kind.json"
  local ref blob_oid tree_oid commit_oid push_error="$ledger_work_dir/push-error"
  local verified_path="$ledger_work_dir/verified-$kind.json" verified_oid
  validate_record_path "$path" "$kind"
  validate_record_schema "$kind" "$path" || fail 'ledger record validation failed'

  state=$(ledger_state)
  if previous=$(previous_kind "$kind"); then
    expected_state=$previous
  else
    expected_state='absent'
  fi
  if [[ "$state" != "$expected_state" ]]; then
    if read_remote_record "$kind" "$existing_path" >/dev/null 2>&1; then
      if cmp -s "$path" "$existing_path"; then
        fail 'ledger record already exists; no retry is permitted'
      fi
      fail 'ledger record collision does not match the existing immutable bytes'
    fi
    fail "ledger record cannot follow remote state $state"
  fi

  if previous=$(previous_kind "$kind"); then
    local previous_path="$ledger_work_dir/publish-parent-$kind.json"
    parent_oid=$(read_remote_record "$previous" "$previous_path") ||
      fail 'ledger parent record is missing'
    validate_chain "$kind" "$path" "$previous_path" ||
      fail 'ledger record does not link to its immutable parent'
  fi

  blob_oid=$(git -C "$ledger_git_dir" hash-object -w "$path")
  tree_oid=$(
    printf '100644 blob %s\t%s\n' "$blob_oid" "$LEDGER_RECORD_NAME" |
      git -C "$ledger_git_dir" mktree
  )
  if [[ -n "$parent_oid" ]]; then
    commit_oid=$(
      printf 'OpenGlucose TestFlight ledger: %s\n' "$kind" |
        git -C "$ledger_git_dir" commit-tree "$tree_oid" -p "$parent_oid"
    )
  else
    commit_oid=$(
      printf 'OpenGlucose TestFlight ledger: %s\n' "$kind" |
        git -C "$ledger_git_dir" commit-tree "$tree_oid"
    )
  fi
  ref=$(ref_for_kind "$kind")
  : >"$push_error"
  if ! transport_git -C "$ledger_git_dir" push --quiet ledger "$commit_oid:$ref" \
    2>"$push_error"; then
    if read_remote_record "$kind" "$existing_path" >/dev/null 2>&1; then
      if cmp -s "$path" "$existing_path"; then
        fail 'ledger publish lost a create-only collision; no retry is permitted'
      fi
      fail 'ledger publish collided with different immutable bytes'
    fi
    fail 'remote ledger create-only publish failed'
  fi

  verified_oid=$(read_remote_record "$kind" "$verified_path") ||
    fail 'published ledger record could not be re-read'
  [[ "$verified_oid" == "$commit_oid" ]] || fail 'published ledger commit identity changed'
  [[ "$(sha256_file "$verified_path")" == "$(sha256_file "$path")" ]] ||
    fail 'published ledger record digest does not match'
  cmp -s "$verified_path" "$path" || fail 'published ledger bytes do not match'
  printf '%s\n' "$kind"
}

restore_exact_file() {
  local source_path=$1 destination_path=$2 mode=$3 temporary_path
  validate_restore_path "$destination_path"
  if [[ -e "$destination_path" || -L "$destination_path" ]]; then
    [[ "$(portable_mode "$destination_path")" == "$mode" ]] ||
      fail 'existing ledger restore destination has the wrong mode'
    [[ "$(sha256_file "$destination_path")" == "$(sha256_file "$source_path")" ]] ||
      fail 'existing ledger restore destination has a different digest'
    cmp -s "$destination_path" "$source_path" ||
      fail 'existing ledger restore destination has different bytes'
    return
  fi

  temporary_path=$(mktemp "$(dirname "$destination_path")/.testflight-ledger.XXXXXX")
  dd if="$source_path" of="$temporary_path" bs=65536 2>/dev/null
  chmod "$mode" "$temporary_path"
  if ! ln "$temporary_path" "$destination_path" 2>/dev/null; then
    if [[ -f "$destination_path" && ! -L "$destination_path" ]] &&
      [[ "$(portable_mode "$destination_path")" == "$mode" ]] &&
      cmp -s "$destination_path" "$source_path"; then
      rm -f -- "$temporary_path"
      return
    fi
    rm -f -- "$temporary_path"
    fail 'ledger restore destination collision does not match immutable bytes'
  fi
  rm -f -- "$temporary_path"
  [[ "$(portable_mode "$destination_path")" == "$mode" ]] ||
    fail 'restored ledger record has the wrong mode'
  [[ "$(sha256_file "$destination_path")" == "$(sha256_file "$source_path")" ]] ||
    fail 'restored ledger record digest does not match'
  cmp -s "$destination_path" "$source_path" || fail 'restored ledger record bytes do not match'
}

restore_state() {
  local attempt_path=$1 provenance_path=$2 notification_path=$3 state
  [[ "$attempt_path" != "$provenance_path" && "$attempt_path" != "$notification_path" && "$provenance_path" != "$notification_path" ]] ||
    fail 'ledger restore destinations must be different'
  validate_restore_path "$attempt_path"
  validate_restore_path "$provenance_path"
  validate_restore_path "$notification_path"
  state=$(ledger_state)

  local attempt_record="$ledger_work_dir/restore-attempt.json"
  local provenance_record="$ledger_work_dir/restore-provenance.json"
  local notification_record="$ledger_work_dir/restore-notification.json"
  case "$state" in
    absent)
      [[ ! -e "$attempt_path" && ! -L "$attempt_path" && ! -e "$provenance_path" && ! -L "$provenance_path" && ! -e "$notification_path" && ! -L "$notification_path" ]] ||
        fail 'local ledger records exist while the remote ledger is absent'
      ;;
    upload-attempt)
      read_remote_record upload-attempt "$attempt_record" >/dev/null
      restore_exact_file "$attempt_record" "$attempt_path" 400
      [[ ! -e "$provenance_path" && ! -L "$provenance_path" && ! -e "$notification_path" && ! -L "$notification_path" ]] ||
        fail 'local ledger state is ahead of the remote ledger'
      ;;
    upload-provenance|notification-pending|notification-complete)
      read_remote_record upload-attempt "$attempt_record" >/dev/null
      read_remote_record upload-provenance "$provenance_record" >/dev/null
      restore_exact_file "$attempt_record" "$attempt_path" 400
      restore_exact_file "$provenance_record" "$provenance_path" 400
      if [[ "$state" == 'upload-provenance' ]]; then
        [[ ! -e "$notification_path" && ! -L "$notification_path" ]] ||
          fail 'local notification state is ahead of the remote ledger'
      else
        read_remote_record "$state" "$notification_record" >/dev/null
        restore_exact_file "$notification_record" "$notification_path" "$(kind_mode "$state")"
      fi
      ;;
    *) fail 'internal ledger state error' ;;
  esac
  printf '%s\n' "$state"
}

require_command git
require_command ruby
require_command ssh
require_command ssh-keygen
require_command awk
require_command sed
require_command cmp
require_command od
require_command mktemp
if ! command -v sha256sum >/dev/null 2>&1; then
  require_command shasum
fi

[[ $# -ge 1 ]] || usage
command_name=$1
shift
validate_identity

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

ledger_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-testflight-ledger.XXXXXX")
chmod 700 "$ledger_work_dir"
ledger_git_dir="$ledger_work_dir/git"
cleanup() {
  case "$ledger_work_dir" in
    "${TMPDIR:-/tmp}"/openglucose-testflight-ledger.*) rm -rf -- "$ledger_work_dir" ;;
    *) printf '%s\n' 'warning: refusing to clean an unexpected ledger work path' >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

git init --quiet "$ledger_git_dir"
git -C "$ledger_git_dir" config user.name 'OpenGlucose TestFlight Ledger'
git -C "$ledger_git_dir" config user.email 'testflight-ledger@openglucose.invalid'
git -C "$ledger_git_dir" config core.hooksPath /dev/null
git -C "$ledger_git_dir" remote add ledger "$TESTFLIGHT_LEDGER_REPOSITORY_URL"
setup_transport

export GIT_AUTHOR_NAME='OpenGlucose TestFlight Ledger'
export GIT_AUTHOR_EMAIL='testflight-ledger@openglucose.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

case "$command_name" in
  persist)
    [[ $# == 2 ]] || usage
    publish_record "$(normalize_kind "$1")" "$2"
    ;;
  restore-state)
    [[ $# == 3 ]] || usage
    restore_state "$1" "$2" "$3"
    ;;
  *) usage ;;
esac
