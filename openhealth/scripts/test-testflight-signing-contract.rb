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

record_index = script.index(
  'fastlane ios record_external_upload_provenance'
)
associate_index = script.index('fastlane ios associate_external_build')
unless record_index && associate_index && record_index < associate_index
  raise "TestFlight signing contract failed: upload provenance must be recorded before association"
end
require_match(
  script,
  /fastlane ios notify_external_build \\\n+(?:.*\\\n)*?\s+"upload_provenance_path:\$UPLOAD_PROVENANCE_PATH"/,
  "external notification must validate immutable upload provenance"
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

puts "Internal TestFlight manual-signing contract checks passed."
