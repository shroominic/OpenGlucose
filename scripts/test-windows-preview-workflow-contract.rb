#!/usr/bin/env ruby

workflow = File.read(
  File.expand_path("../.github/workflows/windows-preview.yml", __dir__)
)
packager = File.read(
  File.expand_path("package-windows-preview.ps1", __dir__)
)
cmake = File.read(
  File.expand_path("../openhealth/windows/CMakeLists.txt", __dir__)
)
native_log_suppression = File.read(
  File.expand_path(
    "../openhealth/windows/runner/suppress_fbp_winrt_native_logs.h",
    __dir__
  )
)

def assert(condition, message)
  return if condition

  raise "Windows preview workflow contract failed: #{message}"
end

def position!(text, fragment)
  position = text.index(fragment)
  return position unless position.nil?

  raise "Windows preview workflow contract failed: missing #{fragment.inspect}"
end

assert(workflow.include?("name: Windows Preview"), "workflow name must be stable")
assert(workflow.include?("workflow_dispatch:\n    inputs:\n      release_tag:"), "manual builds must require a tag")
assert(workflow.include?("Existing strict vMAJOR.MINOR.PATCH tag"), "tag input must explain its strict contract")
assert(workflow.include?("refs/tags/$RELEASE_TAG^{commit}"), "tag must resolve to an immutable commit")
assert(workflow.include?('test "$source_commit" = "$tag_commit"'), "checkout must match the tag commit")
assert(workflow.include?('test "$RELEASE_TAG" = "v${version_record%%+*}"'), "tag must match the app version")
assert(workflow.include?('source_ref="refs/tags/$RELEASE_TAG"'), "manual evidence must retain the exact tag ref")
assert(workflow.include?("persist-credentials: false"), "checkout credentials must not persist")
assert(workflow.include?("permissions:\n  contents: read"), "workflow permissions must remain read-only")
assert(!workflow.include?("contents: write"), "preview workflow must never get release write access")
assert(!workflow.include?("gh release"), "preview workflow must not publish a release")
assert(!workflow.include?("uploads.github.com"), "preview workflow must not upload a release asset")
assert(workflow.include?("if: github.event_name == 'workflow_dispatch'"), "artifact upload must be manual-only")
assert(workflow.include?("${{ steps.package.outputs.archive }}"), "upload must select the exact packaged ZIP")
assert(workflow.include?("${{ steps.package.outputs.checksum }}"), "upload must select the exact packaged checksum")
assert(!workflow.include?("dist/windows/*.zip"), "artifact upload must not use a broad ZIP glob")
assert(workflow.include?("git diff --exit-code"), "build must preserve reviewed source")

%w[
  OpenGlucose.exe
  flutter_windows.dll
  flutter_blue_plus_winrt_plugin.dll
  msvcp140.dll
  vcruntime140.dll
  NOTICES.Z
].each do |required_file|
  assert(packager.include?(required_file), "packager must require #{required_file}")
end
assert(packager.include?("Source commit: $SourceCommit"), "bundle must record its source commit")
assert(packager.include?("Source ref: $SourceRef"), "bundle must record its source ref")
assert(packager.include?("App version: $VersionRecord"), "bundle must record version and build")
assert(packager.include?("Get-FileHash"), "bundle must have a SHA-256 checksum")
assert(packager.include?("forbiddenFiles"), "credential file types must fail packaging")
assert(cmake.include?("InstallRequiredSystemLibraries"), "portable bundle must install the MSVC runtime")
assert(
  cmake.include?("target_compile_options(flutter_blue_plus_winrt_plugin PRIVATE"),
  "native log suppression must apply only to the reviewed WinRT plugin"
)
assert(
  cmake.include?("/FI${CMAKE_CURRENT_SOURCE_DIR}/runner/suppress_fbp_winrt_native_logs.h"),
  "the WinRT plugin must force-include native log suppression"
)
assert(
  native_log_suppression.include?("#define OutputDebugStringA(message) ((void)(message))"),
  "native WinRT debug output must be disabled at compile time"
)

source = position!(workflow, "- name: Bind build to immutable source")
build = position!(workflow, "- name: Build Windows release bundle")
package = position!(workflow, "- name: Package complete portable bundle")
unchanged = position!(workflow, "- name: Verify source tree remained unchanged")
upload = position!(workflow, "- name: Upload manual preview artifact")

assert(source < build, "source must be bound before build")
assert(build < package, "build must finish before packaging")
assert(package < unchanged, "package must finish before the clean-source check")
assert(unchanged < upload, "clean-source check must pass before artifact upload")

puts "Windows preview workflow contract passed."
