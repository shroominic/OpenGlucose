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
