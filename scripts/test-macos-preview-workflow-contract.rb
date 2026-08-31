#!/usr/bin/env ruby

require "json"

root = File.expand_path("..", __dir__)
workflow = File.read(File.join(root, ".github/workflows/macos-preview.yml"))
packager = File.read(File.join(root, "scripts/package-macos-preview.sh"))
workspace = File.read(File.join(root, "scripts/flutter-workspace.sh"))
release_entitlements = File.read(
  File.join(root, "openhealth/macos/Runner/Release.entitlements")
)
release_config = File.read(
  File.join(root, "openhealth/macos/Runner/Configs/Release.xcconfig")
)
preview_notice = File.read(
  File.join(root, "openhealth/lib/src/macos_preview_notice.dart")
)
english_catalog = JSON.parse(
  File.read(File.join(root, "openhealth/lib/l10n/app_en.arb"))
)

def assert(condition, message)
  return if condition

  raise "macOS preview workflow contract failed: #{message}"
end

def position!(text, fragment)
  position = text.index(fragment)
  return position unless position.nil?

  raise "macOS preview workflow contract failed: missing #{fragment.inspect}"
end

assert(workflow.include?("name: macOS Preview"), "workflow name must be stable")
assert(
  workflow.include?("workflow_dispatch:\n    inputs:\n      release_tag:"),
  "manual builds must require a release tag"
)
assert(
  workflow.include?("refs/tags/$RELEASE_TAG^{commit}"),
  "manual checkout must resolve an immutable tag commit"
)
assert(
  workflow.include?('test "$source_commit" = "$tag_commit"'),
  "checked-out source must equal the tag commit"
)
assert(
  workflow.include?('test "$RELEASE_TAG" = "v${version_record%%+*}"'),
  "tag must match the app version"
)
assert(
  workflow.include?("persist-credentials: false"),
  "checkout credentials must not persist"
)
assert(
  workflow.include?("permissions:\n  contents: read"),
  "workflow permissions must remain read-only"
)
assert(!workflow.include?("contents: write"), "preview cannot write releases")
assert(!workflow.include?("gh release"), "preview cannot publish a release")
assert(
  !workflow.include?("uploads.github.com"),
  "preview cannot upload a release asset"
)
assert(
  workflow.include?("if: github.event_name == 'workflow_dispatch'"),
  "downloadable artifact must be manual-only"
)
assert(
  workflow.include?("${{ steps.package.outputs.archive }}"),
  "artifact upload must select the exact archive"
)
assert(
  workflow.include?("${{ steps.package.outputs.checksum }}"),
  "artifact upload must select the exact checksum"
)
assert(!workflow.include?("dist/macos/*.zip"), "upload cannot use a broad ZIP glob")
assert(workflow.include?("git diff --exit-code"), "build must preserve reviewed source")
assert(
  workflow.include?("/Applications/Xcode_26.6.app/Contents/Developer"),
  "workflow must use the pinned Xcode"
)
assert(
  workflow.include?('cocoapods_root="$RUNNER_TEMP/cocoapods/'),
  "workflow must isolate the pinned CocoaPods installation"
)

assert(
  workspace.include?("flutter build macos --release --no-pub"),
  "macOS build must be a release-mode Flutter build"
)
assert(
  workspace.include?("git status --porcelain -- macos/Podfile.lock"),
  "macOS build must reject lockfile drift"
)
assert(packager.include?("codesign --verify --deep --strict"), "bundle signature must be verified")
assert(
  packager.include?('actual_source_commit=$(git -C "$repo_root" rev-parse HEAD)'),
  "packager must verify the checkout commit"
)
assert(
  packager.include?("status --porcelain --untracked-files=normal"),
  "packager must reject an unclean source checkout"
)
assert(packager.include?("Signature=adhoc"), "packager must record ad-hoc signing")
assert(packager.include?("com.apple.security.device.bluetooth"), "Bluetooth entitlement must be checked")
assert(packager.include?("com.apple.security.app-sandbox"), "sandbox entitlement must be checked")
assert(
  packager.include?("must not have outgoing-network access"),
  "release package must reject outgoing-network access"
)
assert(packager.include?("keychain-access-groups"), "Keychain entitlement must be rejected")
assert(packager.include?("com.apple.security.get-task-allow"), "debug entitlement must be rejected")
assert(packager.include?("arm64"), "arm64 must be checked")
assert(
  packager.include?('find "$app_path" -type f'),
  "every bundled file must be inspected for Mach-O architecture"
)
assert(
  packager.include?("every bundled Mach-O must contain an arm64 slice"),
  "packaging must fail closed on a non-arm64 Mach-O"
)
assert(!packager.include?("macos-universal"), "artifact cannot claim universal support")
assert(packager.include?("NOTICES.Z"), "dependency notices must be required")
assert(packager.include?("Source commit: $source_commit"), "source commit must be packaged")
assert(packager.include?("Source ref: $source_ref"), "source ref must be packaged")
assert(packager.include?("shasum -a 256"), "archive must have a SHA-256 checksum")
assert(packager.include?("forbidden_files"), "credential file types must fail packaging")

assert(
  release_entitlements.include?("com.apple.security.device.bluetooth"),
  "release target must request sandboxed Bluetooth"
)
assert(
  release_entitlements.include?("com.apple.security.app-sandbox"),
  "release target must keep the app sandbox"
)
assert(
  !release_entitlements.include?("keychain-access-groups"),
  "ad-hoc preview cannot claim the Keychain access-group capability"
)
assert(
  !release_entitlements.include?("com.apple.security.get-task-allow"),
  "release entitlements cannot permit debugger attachment"
)
assert(
  release_config.match?(/^ARCHS = arm64$/),
  "release target must remain Apple-silicon-only"
)
assert(
  preview_notice.include?("l10n.macosTransportPreviewDescription"),
  "the app must render the localized physical-device evidence notice"
)
assert(
  english_catalog.fetch("macosTransportPreviewDescription").include?(
    "verified on Mac hardware"
  ),
  "the app must disclose the physical-device evidence gap"
)
assert(
  english_catalog.fetch("macosTransportPreviewDescription").include?(
    "cannot remove a system"
  ),
  "the app must disclose the bond-removal gap"
)
assert(
  preview_notice.include?("l10n.macosPreviewAiUnavailableDescription"),
  "the app must render the localized secure-storage notice"
)
assert(
  english_catalog.fetch("macosPreviewAiUnavailableDescription").include?(
    "Cloud AI remains disabled"
  ),
  "the app must fail closed when secure API-key storage is unavailable"
)

source = position!(workflow, "- name: Bind build to immutable source")
build = position!(workflow, "- name: Run macOS checks")
package = position!(workflow, "- name: Package reviewer preview")
unchanged = position!(workflow, "- name: Verify source tree remained unchanged")
upload = position!(workflow, "- name: Upload manual preview artifact")

assert(source < build, "source must be bound before the build")
assert(build < package, "build must complete before packaging")
assert(package < unchanged, "package must complete before the clean-source check")
assert(unchanged < upload, "clean-source check must pass before upload")

puts "macOS preview workflow contract passed."
