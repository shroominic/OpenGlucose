#!/usr/bin/env ruby
# frozen_string_literal: true

root = File.expand_path('..', __dir__)
workflow_path = File.join(root, '.github/workflows/release-testflight-beta.yml')
android_workflow_path = File.join(root, '.github/workflows/release-android-beta.yml')

abort "missing #{workflow_path}" unless File.file?(workflow_path)
abort "missing independent Android release workflow" unless File.file?(android_workflow_path)

workflow = File.read(workflow_path)

def assert_contract(condition, message)
  abort "TestFlight workflow contract failed: #{message}" unless condition
end

def assert_in_order(text, earlier, later, message)
  earlier_index = text.index(earlier)
  later_index = text.index(later)
  assert_contract(earlier_index && later_index && earlier_index < later_index, message)
end

dispatch = workflow[/^  workflow_dispatch:\n(.*?)^concurrency:/m, 1]
assert_contract(dispatch, 'workflow_dispatch must be declared')
dispatch_choices = dispatch.scan(/^          - ([a-z_]+)$/).flatten
assert_contract(
  dispatch_choices == %w[submit_review notify_testers],
  'manual choices must be exactly submit_review and notify_testers',
)
assert_contract(
  dispatch.scan(/^      ([a-z_]+):$/).flatten == %w[operation release_tag],
  'manual inputs must be exactly operation and release_tag',
)

[
  "release:\n    types:\n      - published",
  'github.event.release.prerelease == true',
  'group: openglucose-testflight-external',
  'cancel-in-progress: false',
  "permissions: {}",
  'environment:',
  'name: testflight-external',
  'runs-on: macos-26',
  'timeout-minutes: 180',
  'DEVELOPER_DIR: /Applications/Xcode_26.6.app/Contents/Developer',
  'FLUTTER_VERSION: "3.41.6"',
].each do |required_text|
  assert_contract(workflow.include?(required_text), "missing #{required_text.inspect}")
end

assert_contract(
  workflow.scan('actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1').length == 2,
  'both checkouts must use the reviewed immutable action SHA',
)
assert_contract(
  workflow.include?('ref: ${{ needs.validate.outputs.source_sha }}'),
  'the macOS job must check out the validated commit SHA, not a mutable ref',
)
assert_contract(
  workflow.include?('persist-credentials: false'),
  'source checkout must not persist the GitHub token',
)

[
  'releases/tags/$RELEASE_TAG',
  "'.prerelease'",
  'refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG',
  'git rev-parse "${RELEASE_TAG}^{commit}"',
  'git merge-base --is-ancestor',
  "openhealth/pubspec.yaml",
  'test "$RELEASE_TAG" = "v$marketing_version"',
  'test "$RELEASE_TAG" = "v${actual_version%%+*}"',
].each do |validation_text|
  assert_contract(
    workflow.include?(validation_text),
    "release validation is missing #{validation_text.inspect}",
  )
end
assert_contract(
  workflow.include?('^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$'),
  'release tags must use the strict vMAJOR.MINOR.PATCH grammar',
)
assert_contract(
  workflow.scan('"$RELEASE_TAG" == "v0.1.0"').length == 2 &&
    workflow.scan('"$RELEASE_TAG" == "v0.1.1"').length == 2 &&
    workflow.include?('"$release_version" == "0.1.0+18"') &&
    workflow.include?('"$actual_version" == "0.1.0+18"') &&
    workflow.include?('"$release_version" == "0.1.1+19"') &&
    workflow.include?('"$actual_version" == "0.1.1+19"'),
  'hosted automation must reject releases that predate the workflow',
)
assert_contract(
  workflow.scan('Hosted TestFlight automation starts after v0.1.1; resume v0.1.0 build 18 from preserved local state and never upload either earlier release through this workflow.').length == 2,
  'the historical-release gate must direct operators to the preserved local resume state',
)

assert_contract(
  workflow.scan('subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2').length == 1,
  'Flutter setup must use the reviewed immutable action SHA',
)
assert_contract(
  workflow.scan('gem install --user-install --no-document').length == 2,
  'Fastlane and CocoaPods must be installed as exact user gems',
)
assert_contract(
  workflow.include?("fastlane_version=$(sed -n '1p' .fastlane-version)"),
  'Fastlane must come from the checked-in version pin',
)
assert_contract(
  workflow.include?("cocoapods_version=$(sed -n '1p' .cocoapods-version)"),
  'CocoaPods must come from the checked-in version pin',
)
assert_contract(
  !workflow.match?(/GEM_(?:HOME|PATH)=.*GITHUB_ENV/),
  'GEM_HOME and GEM_PATH must not persist through GITHUB_ENV',
)
assert_contract(
  workflow.include?('env -u GEM_HOME -u GEM_PATH'),
  'the release command must reject inherited RubyGems path overrides',
)

assert_in_order(
  workflow,
  'Restore dependencies and run release checks',
  'Restore and gate immutable release state',
  'checks must complete before immutable state is restored',
)
assert_in_order(
  workflow,
  'Restore and gate immutable release state',
  'ASC_API_KEY_P8_BASE64: ${{ secrets.ASC_API_KEY_P8_BASE64 }}',
  'ledger state must be approved before the ASC key is exposed or decoded',
)
assert_in_order(
  workflow,
  'Upload signed TestFlight build',
  'decode_base64 "$ASC_API_KEY_P8_BASE64"',
  'ASC key decoding must happen only in the gated upload step',
)

gate_step = workflow[/      - name: Restore and gate immutable release state\n(.*?)      - name: Upload signed TestFlight build\n/m, 1]
upload_step = workflow[/      - name: Upload signed TestFlight build\n(.*?)      - name: Materialize notification ledger write credential\n/m, 1]
notification_ledger_step = workflow[/      - name: Materialize notification ledger write credential\n(.*?)      - name: Run approved review or notification phase\n/m, 1]
followup_step = workflow[/      - name: Run approved review or notification phase\n(.*?)      - name: Clean up restored runner state\n/m, 1]
assert_contract(
  gate_step && upload_step && notification_ledger_step && followup_step,
  'operation and credential-scope steps must remain separate',
)

[
  'upload:absent)',
  'submit_review:upload-provenance)',
  'notify_testers:upload-provenance)',
  'notify_testers:notification-complete)',
  'script_operation=verify_notification',
  'notify_testers:notification-pending)',
].each do |matrix_text|
  assert_contract(
    gate_step.include?(matrix_text),
    "operation/state gate is missing #{matrix_text.inspect}",
  )
end
assert_contract(
  !gate_step.include?('ASC_API_KEY_P8_BASE64'),
  'ASC material must not be present before the operation/state gate',
)
assert_contract(
  gate_step.include?('TESTFLIGHT_LEDGER_READ_ONLY_DEPLOY_KEY: ${{ secrets.TESTFLIGHT_LEDGER_READ_ONLY_DEPLOY_KEY }}') &&
    !gate_step.include?('${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}'),
  'state restoration must use only the read-only ledger deploy key',
)
assert_in_order(
  upload_step,
  'trap cleanup EXIT',
  'decode_base64 "$ASC_API_KEY_P8_BASE64"',
  'upload cleanup must be armed before ASC or signing material is decoded',
)
assert_in_order(
  followup_step,
  'trap cleanup EXIT',
  'printf \'%s\' "$ASC_API_KEY_P8_BASE64"',
  'follow-up cleanup must be armed before ASC material is decoded',
)
assert_contract(
  notification_ledger_step.include?("if: steps.ledger.outputs.script_operation == 'notify_testers'") &&
    notification_ledger_step.include?('TESTFLIGHT_LEDGER_DEPLOY_KEY: ${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}'),
  'the write-capable ledger key must be exposed only to the notification operation',
)
assert_contract(
  workflow.scan('${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}').length == 2 &&
    upload_step.include?('${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}') &&
    notification_ledger_step.include?('${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}') &&
    !followup_step.include?('${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}'),
  'only upload and notification credential materialization may reference the write key',
)
assert_contract(
  followup_step.include?('if [[ "$SCRIPT_OPERATION" == "notify_testers" ]]') &&
    followup_step.include?('"TESTFLIGHT_LEDGER_HOOK=$ledger_hook"') &&
    followup_step.include?('"TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH=$ledger_write_key_path"') &&
    followup_step.include?('[[ ! -e "$state_dir/ledger-write-key"') &&
    followup_step.include?('unset TESTFLIGHT_LEDGER_REPOSITORY_URL'),
  'submit_review and verify_notification must run without ledger write credentials',
)

[
  'security create-keychain',
  'security import "$p12_path"',
  'security set-key-partition-list',
  'security delete-keychain',
  'IOS_APP_STORE_PROFILE_BASE64',
  'IOS_LIVE_ACTIVITY_PROFILE_BASE64',
  'ASC_API_KEY_P8_BASE64',
  '$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles',
  'rm -f -- "$app_profile_destination"',
  'rm -f -- "$live_profile_destination"',
  'rm -rf -- "$state_dir"',
  'rm -rf -- "$material_dir"',
].each do |credential_text|
  assert_contract(
    workflow.include?(credential_text),
    "temporary credential handling is missing #{credential_text.inspect}",
  )
end

upload_only_secret_references = %w[
  IOS_APP_STORE_PROFILE_BASE64
  IOS_DISTRIBUTION_P12_BASE64
  IOS_DISTRIBUTION_P12_PASSWORD
  IOS_LIVE_ACTIVITY_PROFILE_BASE64
]
upload_only_secret_references.each do |secret_name|
  expression = "${{ secrets.#{secret_name} }}"
  assert_contract(
    workflow.scan(expression).length == 1 && upload_step.include?(expression),
    "#{secret_name} must be scoped exclusively to the upload step",
  )
  assert_contract(
    !followup_step.include?(secret_name),
    "follow-up child processes must never inherit #{secret_name}",
  )
end
assert_contract(
  followup_step.include?('TESTFLIGHT_EXTERNAL_OPERATION="$SCRIPT_OPERATION"'),
  'the gated follow-up operation must be passed explicitly',
)
assert_contract(
  followup_step.include?('verify_notification'),
  'completed notification receipts must select read-only verification',
)

[
  'TESTFLIGHT_LEDGER_READ_ONLY_DEPLOY_KEY: ${{ secrets.TESTFLIGHT_LEDGER_READ_ONLY_DEPLOY_KEY }}',
  'TESTFLIGHT_LEDGER_DEPLOY_KEY: ${{ secrets.TESTFLIGHT_LEDGER_DEPLOY_KEY }}',
  'TESTFLIGHT_LEDGER_REPOSITORY_URL: ${{ vars.TESTFLIGHT_LEDGER_REPOSITORY_URL }}',
  'ledger_hook="$GITHUB_WORKSPACE/openhealth/scripts/testflight-ledger.sh"',
  'TESTFLIGHT_LEDGER_DEPLOY_KEY_PATH="$ledger_key_path"',
  'TESTFLIGHT_LEDGER_BUNDLE_ID="$APP_BUNDLE_ID"',
  'TESTFLIGHT_LEDGER_PLATFORM=ios',
  'TESTFLIGHT_LEDGER_VERSION="$RELEASE_MARKETING_VERSION"',
  'TESTFLIGHT_LEDGER_BUILD_NUMBER="$RELEASE_BUILD_NUMBER"',
  '"$ledger_hook" restore-state',
  '"$upload_attempt_path"',
  '"$upload_provenance_path"',
  '"$notification_receipt_path"',
].each do |ledger_text|
  assert_contract(
    workflow.include?(ledger_text),
    "private release ledger wiring is missing #{ledger_text.inspect}",
  )
end

[
  'TESTFLIGHT_EXTERNAL_OPERATION=upload',
  'TESTFLIGHT_EXTERNAL_OPERATION="$SCRIPT_OPERATION"',
  'RELEASE_COMMIT="$RELEASE_SOURCE_SHA"',
  'RELEASE_VERSION="$RELEASE_VERSION"',
  'TESTFLIGHT_LEDGER_HOOK="$ledger_hook"',
  'TESTFLIGHT_UPLOAD_PROVENANCE_PATH="$upload_provenance_path"',
  'TESTFLIGHT_NOTIFICATION_RECEIPT_PATH="$notification_receipt_path"',
  '"$GITHUB_WORKSPACE/openhealth/scripts/testflight.sh"',
].each do |execution_text|
  assert_contract(
    workflow.include?(execution_text),
    "checked-in release execution is missing #{execution_text.inspect}",
  )
end

assert_contract(
  workflow.include?('release-android-beta.yml') &&
    !workflow.include?('uses: ./.github/workflows/release-android-beta.yml'),
  'Android must remain an independent parallel release workflow',
)

puts 'TestFlight release workflow contract passed.'
