# frozen_string_literal: true

script_path = File.expand_path("testflight.sh", __dir__)
script = File.read(script_path)

def require_match(text, pattern, message)
  raise "TestFlight signing contract failed: #{message}" unless text.match?(pattern)
end

internal_input_start = script.index('if [[ "$TESTFLIGHT_MODE" == "internal" ]]; then')
internal_input_end = script.index(
  'elif [[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" ]]',
  internal_input_start
)
unless internal_input_start && internal_input_end
  raise "TestFlight signing contract failed: internal input gate is missing"
end

internal_inputs = script[internal_input_start...internal_input_end]

%w[
  APP_STORE_PROFILE_UUID
  LIVE_ACTIVITY_APP_STORE_PROFILE_UUID
  IOS_DISTRIBUTION_CERTIFICATE_SHA1
].each do |variable|
  require_match(
    internal_inputs,
    /:\s+"\$\{#{Regexp.escape(variable)}:\?missing [^"]+\}"/,
    "internal mode must require #{variable}"
  )
end

notify_input_start = script.index(
  'elif [[ "$TESTFLIGHT_NOTIFY_ONLY" == "yes" ]]',
  internal_input_end
)
external_input_start = script.index("\nelse\n", notify_input_start)
external_input_end = script.index("\nfi\n", external_input_start)
unless notify_input_start && external_input_start && external_input_end
  raise "TestFlight signing contract failed: external input gate is missing"
end
notify_inputs = script[notify_input_start...external_input_start]
require_match(
  notify_inputs,
  /:\s+"\$\{TESTFLIGHT_UPLOAD_PROVENANCE_PATH:\?missing [^"]+\}"/,
  "notify-only mode must require immutable upload provenance"
)
external_inputs = script[external_input_start...external_input_end]
%w[
  TESTFLIGHT_GROUP_ID
  APP_STORE_PROFILE_UUID
  LIVE_ACTIVITY_APP_STORE_PROFILE_UUID
  IOS_DISTRIBUTION_CERTIFICATE_SHA1
  TESTFLIGHT_INTERNAL_GROUP
  TESTFLIGHT_INTERNAL_GROUP_ID
  TESTFLIGHT_INTERNAL_TESTER_ID
  TESTFLIGHT_EXTERNAL_TESTER_COUNT
  TESTFLIGHT_EXTERNAL_TESTER_IDS_SHA256
  TESTFLIGHT_UPLOAD_PROVENANCE_PATH
].each do |variable|
  require_match(
    external_inputs,
    /:\s+"\$\{#{Regexp.escape(variable)}:\?missing [^"]+\}"/,
    "external upload mode must require #{variable}"
  )
end

require_match(
  script,
  /UPLOAD_ATTEMPT_PATH=\$\(canonical_external_record_path \\\n+\s+"\$UPLOAD_PROVENANCE_PATH\.attempt" "upload attempt"\)/,
  "upload attempt path must derive deterministically from provenance"
)

claim_index = script.index('fastlane ios claim_external_upload_attempt')
attempt_hook_index = script.index(
  'persist_external_release_record upload_attempt "$UPLOAD_ATTEMPT_PATH"',
  claim_index
)
upload_index = script.index('fastlane pilot upload')
record_index = script.index('fastlane ios record_external_upload_provenance')
provenance_hook_index = script.index(
  'persist_external_release_record upload_provenance "$UPLOAD_PROVENANCE_PATH"',
  record_index
)
unless claim_index && attempt_hook_index && upload_index && record_index &&
       provenance_hook_index && claim_index < attempt_hook_index &&
       attempt_hook_index < upload_index && upload_index < record_index &&
       record_index < provenance_hook_index
  raise "TestFlight signing contract failed: attempt, ledger hooks, upload, and provenance order is unsafe"
end

metadata_index = script.index('fastlane ios verify_external_review_metadata')
clean_build_index = script.index('assert_clean_source "release build"')
profile_index = script.rindex("verify_distribution_profile \\\n", claim_index)
preupload_audience_index = script.rindex(
  'fastlane ios verify_external_group',
  claim_index
)
audience_assertion_index = script.rindex(
  'approved TestFlight audience changed before upload',
  claim_index
)
deterministic_preflights = [
  metadata_index,
  clean_build_index,
  profile_index,
  preupload_audience_index,
  audience_assertion_index
]
unless deterministic_preflights.all? { |index| index && index < claim_index }
  raise "TestFlight signing contract failed: every deterministic preflight must precede the upload attempt"
end

claim_end = script.index("\nfi\n", attempt_hook_index)
unless claim_end && script[(claim_end + 4)...upload_index].to_s.strip.empty?
  raise "TestFlight signing contract failed: pilot must run immediately after the durable attempt hook"
end

association_function_start = script.index(
  'associate_finalized_external_build() {'
)
association_function_end = script.index("\n}\n", association_function_start)
unless association_function_start && association_function_end
  raise "TestFlight signing contract failed: finalized association helper is missing"
end
association_function = script[association_function_start...association_function_end]
unless association_function.include?('fastlane ios associate_external_build')
  raise "TestFlight signing contract failed: finalized helper must run the association lane"
end
%w[
  version:$EXPECTED_MARKETING_VERSION
  build_number:$EXPECTED_BUILD_NUMBER
  source_commit:$head_commit
  upload_attempt_path:$UPLOAD_ATTEMPT_PATH
  upload_provenance_path:$UPLOAD_PROVENANCE_PATH
].each do |binding|
  unless association_function.include?(%Q{"#{binding}"})
    raise "TestFlight signing contract failed: finalized association must bind #{binding}"
  end
end

submit_start = script.index(
  'if [[ "$TESTFLIGHT_EXTERNAL_OPERATION" == "submit_review" ]]; then'
)
submit_end = script.index("\nfi\n", submit_start)
verify_start = script.index(
  'if [[ "$TESTFLIGHT_EXTERNAL_OPERATION" == "verify_notification" ]]; then',
  script.index('echo "==> Approved $TESTFLIGHT_MODE group ID')
)
verify_end = script.index("\nfi\n", verify_start)
notify_start = script.index(
  'if [[ "$TESTFLIGHT_EXTERNAL_OPERATION" == "notify_testers" ]]; then',
  association_function_end
)
notify_end = script.index("\nfi\n", notify_start)
unless submit_start && submit_end && verify_start && verify_end &&
       notify_start && notify_end
  raise "TestFlight signing contract failed: explicit external operation gates are missing"
end
submit_operation = script[submit_start...submit_end]
verify_operation = script[verify_start...verify_end]
notify_operation = script[notify_start...notify_end]
unless submit_operation.include?('associate_finalized_external_build') &&
       submit_operation.include?('exit 0')
  raise "TestFlight signing contract failed: submit_review must associate/submit and exit"
end
if submit_operation.include?('fastlane ios notify_external_build') ||
   submit_operation.include?('fastlane pilot upload') ||
   submit_operation.include?('flutter build ipa')
  raise "TestFlight signing contract failed: submit_review must not build, upload, or notify"
end
resume_associate = notify_operation.index('associate_finalized_external_build')
resume_notify = notify_operation.index('fastlane ios notify_external_build')
unless resume_associate && resume_notify && resume_associate < resume_notify &&
       notify_operation.include?('exit 0')
  raise "TestFlight signing contract failed: notify_testers must associate before one-shot notification"
end
if notify_operation.include?('fastlane pilot upload') ||
   notify_operation.include?('flutter build ipa')
  raise "TestFlight signing contract failed: notify_testers must not build or upload"
end
unless verify_operation.include?('fastlane ios verify_external_notification') &&
       verify_operation.include?('exit 0')
  raise "TestFlight signing contract failed: verify_notification must run the read-only lane and exit"
end
[
  'associate_finalized_external_build',
  'fastlane ios associate_external_build',
  'fastlane ios notify_external_build',
  'fastlane pilot upload',
  'flutter build ipa',
  'persist_external_release_record'
].each do |forbidden|
  if verify_operation.include?(forbidden)
    raise "TestFlight signing contract failed: verify_notification contains mutation #{forbidden.inspect}"
  end
end

upload_execution = script[notify_end..]
if upload_execution.include?('fastlane ios associate_external_build') ||
   upload_execution.include?('fastlane ios notify_external_build')
  raise "TestFlight signing contract failed: upload must exit after finalized provenance"
end
unless upload_execution.index('fastlane pilot upload') <
       upload_execution.index('fastlane ios record_external_upload_provenance') &&
       upload_execution.index('fastlane ios record_external_upload_provenance') <
       upload_execution.index('persist_external_release_record upload_provenance') &&
       upload_execution.index('persist_external_release_record upload_provenance') <
       upload_execution.rindex('exit 0')
  raise "TestFlight signing contract failed: upload provenance must persist before success"
end
require_match(
  script,
  /fastlane ios notify_external_build \\\n+(?:.*\\\n)*?\s+"upload_attempt_path:\$UPLOAD_ATTEMPT_PATH" \\\n+\s+"upload_provenance_path:\$UPLOAD_PROVENANCE_PATH"/,
  "external notification must validate immutable upload attempt and provenance"
)

require_match(
  script,
  /TESTFLIGHT_EXTERNAL_OPERATION must be upload, submit_review, notify_testers, or verify_notification/,
  "external operations must be explicit and closed to unknown values"
)
require_match(
  script,
  /\"\$TESTFLIGHT_LEDGER_HOOK\" persist \"\$kind\" \"\$path\"/,
  "ledger hook must receive direct persist/kind/path arguments without eval"
)

fastfile_source = File.read(
  File.expand_path("../fastlane/Fastfile", __dir__)
)
verify_lane_start = fastfile_source.index('lane :verify_external_notification')
notify_lane_start = fastfile_source.index('lane :notify_external_build')
unless verify_lane_start && notify_lane_start && verify_lane_start < notify_lane_start
  raise "TestFlight signing contract failed: read-only notification verification lane is missing"
end
verify_lane = fastfile_source[verify_lane_start...notify_lane_start]
%w[
  require_upload_provenance
  require_automatic_notification_disabled
  require_exact_external_association
  require_no_individual_testers
  require_approved_external_beta_review_submission
  require_external_notification_eligible_state
  notification_receipt_state
].each do |required_read|
  unless verify_lane.include?(required_read)
    raise "TestFlight signing contract failed: read-only lane omits #{required_read}"
  end
end
[
  'disable_automatic_notification',
  'patch_build_beta_details',
  'add_beta_groups',
  'post_beta_app_review_submission',
  'post_build_beta_notification_once',
  'persist_external_release_record',
  'create_notification_claim',
  'complete_notification_claim'
].each do |forbidden_mutation|
  if verify_lane.include?(forbidden_mutation)
    raise "TestFlight signing contract failed: read-only lane contains #{forbidden_mutation}"
  end
end

pending_gate = script.index(
  'notification_status=$(notification_receipt_status'
)
complete_schema_gate = script.index(
  'verify_complete_notification_receipt_before_asc',
  pending_gate
)
first_asc_lane = script.index('fastlane ios verify_external_group')
unless pending_gate && complete_schema_gate && first_asc_lane &&
       pending_gate < first_asc_lane && complete_schema_gate < first_asc_lane
  raise "TestFlight signing contract failed: restored notification state must be gated before ASC access"
end
require_match(
  script,
  /an immutable notification-pending claim cannot be retried/,
  "pending notification claims must fail before ASC access"
)

claim_call = fastfile_source.index(
  'claim_id = create_notification_claim(',
  notify_lane_start
)
pending_hook = fastfile_source.index(
  'kind: "notification_pending"',
  claim_call
)
audience_recheck = fastfile_source.index(
  'group = exact_external_group(',
  pending_hook
)
notification_post = fastfile_source.index(
  'post_build_beta_notification_once(',
  audience_recheck
)
completion_call = fastfile_source.index(
  'complete_notification_claim(',
  notification_post
)
complete_hook = fastfile_source.index(
  'kind: "notification_complete"',
  completion_call
)
unless [
  notify_lane_start,
  claim_call,
  pending_hook,
  audience_recheck,
  notification_post,
  completion_call,
  complete_hook
].all? &&
       claim_call < pending_hook && pending_hook < audience_recheck &&
       audience_recheck < notification_post &&
       notification_post < completion_call && completion_call < complete_hook
  raise "TestFlight signing contract failed: notification ledger hooks do not guard the one-shot POST"
end

require_match(
  script,
  /an upload attempt is pending without finalized provenance; preserve it, record an incident, and cut a new build number/,
  "pending-only upload state must block restarted automation"
)
require_match(
  script,
  /normal upload reruns are blocked after an attempt is finalized/,
  "normal reruns must not overwrite a completed upload state"
)

uuid_validator = Regexp.escape(
  "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
%w[APP_STORE_PROFILE_UUID LIVE_ACTIVITY_APP_STORE_PROFILE_UUID].each do |variable|
  require_match(
    script,
    /\[\[\s+"\$\{?#{Regexp.escape(variable)}\}?"\s+=~\s+#{uuid_validator}\s+\]\]/,
    "#{variable} must be validated as one canonical UUID"
  )
end

sha1_validator = Regexp.escape("^[0-9A-Fa-f]{40}$")
require_match(
  script,
  /\[\[\s+"\$\{?IOS_DISTRIBUTION_CERTIFICATE_SHA1\}?"\s+=~\s+#{sha1_validator}\s+\]\]/,
  "IOS_DISTRIBUTION_CERTIFICATE_SHA1 must be validated as exactly 40 hexadecimal characters"
)

external_export_start = script.index('external_export_options=')
external_export_end = script.index("\nfi\n", external_export_start)
unless external_export_start && external_export_end
  raise "TestFlight signing contract failed: external ExportOptions block is missing"
end
external_export_block = script[external_export_start...external_export_end]
require_match(
  external_export_block,
  /<key>signingStyle<\/key>\s*<string>manual<\/string>/,
  "external ExportOptions must use manual signing"
)
require_match(
  external_export_block,
  /<key>signingCertificate<\/key>\s*<string>\$\{?IOS_DISTRIBUTION_CERTIFICATE_SHA1\}?<\/string>/,
  "external ExportOptions must select the exact approved certificate SHA-1"
)
require_match(
  external_export_block,
  /<key>testFlightInternalTestingOnly<\/key>\s*<false\s*\/>/,
  "external ExportOptions must remain eligible for external TestFlight"
)
external_profiles_match = external_export_block.match(
  /<key>provisioningProfiles<\/key>\s*<dict>(.*?)<\/dict>/m
)
unless external_profiles_match
  raise "TestFlight signing contract failed: external provisioningProfiles mapping is missing"
end
external_profiles = external_profiles_match[1]
require_match(
  external_profiles,
  /<key>\$\{?APP_BUNDLE_ID\}?<\/key>\s*<string>\$\{?APP_STORE_PROFILE_UUID\}?<\/string>/,
  "external app bundle must map to APP_STORE_PROFILE_UUID"
)
require_match(
  external_profiles,
  %r{<key>\$\{?LIVE_ACTIVITY_BUNDLE_ID\}?</key>\s*
     <string>\$\{?LIVE_ACTIVITY_APP_STORE_PROFILE_UUID\}?</string>}x,
  "external extension bundle must map to LIVE_ACTIVITY_APP_STORE_PROFILE_UUID"
)

export_start = script.index('internal_export_options=')
export_end = script.index("\nelse\n", export_start)
unless export_start && export_end
  raise "TestFlight signing contract failed: internal ExportOptions block is missing"
end

export_block = script[export_start...export_end]

require_match(
  export_block,
  /<key>signingStyle<\/key>\s*<string>manual<\/string>/,
  "internal ExportOptions must use manual signing"
)
if export_block.match?(/<string>automatic<\/string>/)
  raise "TestFlight signing contract failed: internal ExportOptions must not use automatic signing"
end

require_match(
  export_block,
  /<key>signingCertificate<\/key>\s*<string>\$\{?IOS_DISTRIBUTION_CERTIFICATE_SHA1\}?<\/string>/,
  "internal ExportOptions must select the exact approved certificate SHA-1"
)
require_match(
  export_block,
  /<key>testFlightInternalTestingOnly<\/key>\s*<true\s*\/>/,
  "internal ExportOptions must remain permanently internal-only"
)

profiles_match = export_block.match(/<key>provisioningProfiles<\/key>\s*<dict>(.*?)<\/dict>/m)
unless profiles_match
  raise "TestFlight signing contract failed: provisioningProfiles mapping is missing"
end

profiles = profiles_match[1]
require_match(
  profiles,
  /<key>\$\{?APP_BUNDLE_ID\}?<\/key>\s*<string>\$\{?APP_STORE_PROFILE_UUID\}?<\/string>/,
  "the exact main-app bundle ID must map to APP_STORE_PROFILE_UUID"
)
require_match(
  profiles,
  %r{<key>\$\{?LIVE_ACTIVITY_BUNDLE_ID\}?</key>\s*
     <string>\$\{?LIVE_ACTIVITY_APP_STORE_PROFILE_UUID\}?</string>}x,
  "the exact Live Activity bundle ID must map to LIVE_ACTIVITY_APP_STORE_PROFILE_UUID"
)

require_match(
  script,
  /codesign\s+-d\s+--extract-certificates="\$certificate_prefix"\s+"\$bundle"/,
  "the signed leaf certificate must use codesign's attached-value extraction syntax"
)

puts "TestFlight phase, ledger-hook, and manual-signing contract checks passed."
