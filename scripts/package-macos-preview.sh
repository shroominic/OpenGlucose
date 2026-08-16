#!/bin/sh
set -eu

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

require_file() {
  [ -f "$1" ] || die "required macOS bundle file is missing: $1"
}

require_directory() {
  [ -d "$1" ] || die "required macOS bundle directory is missing: $1"
}

[ "$#" -eq 5 ] || die \
  'usage: package-macos-preview.sh APP_PATH OUTPUT_DIR VERSION SOURCE_COMMIT SOURCE_REF'

app_input=$1
output_input=$2
version_record=$3
source_commit=$4
source_ref=$5
repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

require_tool codesign
require_tool ditto
require_tool file
require_tool git
require_tool grep
require_tool lipo
require_tool shasum

printf '%s\n' "$version_record" |
  grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\+(0|[1-9][0-9]*)$' ||
  die "version must be strict MAJOR.MINOR.PATCH+BUILD: $version_record"
printf '%s\n' "$source_commit" | grep -Eq '^[0-9a-f]{40}$' ||
  die "source commit must be a full lowercase SHA-1: $source_commit"

case "$source_ref" in
  "ci:$source_commit") ;;
  refs/tags/v*)
    app_version=${version_record%%+*}
    [ "$source_ref" = "refs/tags/v$app_version" ] ||
      die "source tag does not match app version: $source_ref"
    ;;
  *) die "source ref is not an exact CI commit or strict version tag: $source_ref" ;;
esac

actual_source_commit=$(git -C "$repo_root" rev-parse HEAD)
[ "$actual_source_commit" = "$source_commit" ] ||
  die "source commit does not match the checkout: $actual_source_commit"
[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ] ||
  die 'source checkout is not clean; refusing to package unreviewed bytes'

app_parent=$(CDPATH='' cd -- "$(dirname -- "$app_input")" && pwd)
app_path="$app_parent/$(basename -- "$app_input")"
require_directory "$app_path"
[ "$(basename -- "$app_path")" = 'OpenGlucose Preview.app' ] ||
  die "unexpected application bundle name: $(basename -- "$app_path")"

info_plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/OpenGlucose Preview"
notices="$app_path/Contents/Frameworks/App.framework/Resources/flutter_assets/NOTICES.Z"
ble_framework="$app_path/Contents/Frameworks/flutter_blue_plus_darwin.framework"
require_file "$info_plist"
require_file "$executable"
require_file "$notices"
require_directory "$ble_framework"

plist_read() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist"
}

bundle_identifier=$(plist_read CFBundleIdentifier)
bundle_version=$(plist_read CFBundleShortVersionString)
bundle_build=$(plist_read CFBundleVersion)
bluetooth_purpose=$(plist_read NSBluetoothAlwaysUsageDescription)
[ "$bundle_identifier" = 'com.openglucose.app.macos.preview' ] ||
  die "unexpected bundle identifier: $bundle_identifier"
[ "$bundle_version+$bundle_build" = "$version_record" ] ||
  die "bundle version $bundle_version+$bundle_build does not match $version_record"
[ -n "$bluetooth_purpose" ] || die 'Bluetooth usage description is empty'

archs=$(lipo -archs "$executable")
[ "$archs" = arm64 ] ||
  die "preview executable must be arm64-only; found: $archs"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/openglucose-macos-preview.XXXXXX")
cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

macho_failures="$temporary_root/macho-architecture-failures.txt"
: >"$macho_failures"
find "$app_path" -type f -exec sh -c '
  report=$1
  shift
  for candidate do
    description=$(file -b "$candidate") || {
      printf "could not inspect %s\n" "$candidate" >>"$report"
      continue
    }
    case "$description" in
      *Mach-O*)
        candidate_archs=$(lipo -archs "$candidate") || {
          printf "could not read architectures for %s\n" "$candidate" >>"$report"
          continue
        }
        case " $candidate_archs " in
          *" arm64 "*) ;;
          *) printf "missing arm64: %s (%s)\n" "$candidate" "$candidate_archs" >>"$report" ;;
        esac
        ;;
    esac
  done
' sh "$macho_failures" {} +
if [ -s "$macho_failures" ]; then
  sed -n '1,80p' "$macho_failures" >&2
  die 'every bundled Mach-O must contain an arm64 slice'
fi

codesign --verify --deep --strict "$app_path"
signature_details=$(codesign -dv --verbose=4 "$app_path" 2>&1)
printf '%s\n' "$signature_details" | grep -Fq 'Signature=adhoc' ||
  die 'preview bundle is not ad-hoc signed'

entitlements="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$app_path" >"$entitlements" 2>/dev/null
entitlement_read() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$entitlements" 2>/dev/null
}
[ "$(entitlement_read com.apple.security.app-sandbox)" = true ] ||
  die 'app sandbox entitlement is missing'
[ "$(entitlement_read com.apple.security.device.bluetooth)" = true ] ||
  die 'Bluetooth entitlement is missing'
if entitlement_read com.apple.security.network.client >/dev/null 2>&1; then
  die 'release preview must not have outgoing-network access'
fi
if entitlement_read keychain-access-groups >/dev/null 2>&1; then
  die 'ad-hoc preview must keep Keychain-backed AI disabled'
fi
if entitlement_read com.apple.security.get-task-allow >/dev/null 2>&1; then
  die 'release preview must not contain get-task-allow'
fi

mkdir -p "$output_input"
output_dir=$(CDPATH='' cd -- "$output_input" && pwd)
safe_version=$(printf '%s' "$version_record" | tr '+' '-')
archive_name="openglucose-$safe_version-macos-arm64-preview.zip"
archive_path="$output_dir/$archive_name"
checksum_path="$archive_path.sha256"
[ ! -e "$archive_path" ] || die "refusing to replace existing output: $archive_path"
[ ! -e "$checksum_path" ] || die "refusing to replace existing output: $checksum_path"

stage="$temporary_root/OpenGlucose-macOS-Preview"
mkdir "$stage"
ditto "$app_path" "$stage/OpenGlucose Preview.app"
cp "$repo_root/LICENSE" "$stage/LICENSE"
cp "$repo_root/NOTICE.md" "$stage/NOTICE.md"
cp "$repo_root/docs/macos-preview.md" "$stage/README-macOS-PREVIEW.md"
cat >"$stage/BUILD-INFO.txt" <<EOF
OpenGlucose macOS preview
App version: $version_record
Source commit: $source_commit
Source ref: $source_ref
Architectures: arm64
Signing: ad-hoc; not Developer ID signed or notarized
Physical macOS/AiDEX verification: not recorded
Distribution status: reviewer preview; not a stable OpenGlucose release
EOF

forbidden_files=$(find "$stage" -type f \( \
  -name '*.p8' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o \
  -name '*.mobileprovision' -o -name '*.jks' -o -name '*.keystore' \
  \) -print)
[ -z "$forbidden_files" ] || die 'staged preview contains signing or credential material'
codesign --verify --deep --strict "$stage/OpenGlucose Preview.app"

ditto -c -k --keepParent --sequesterRsrc "$stage" "$archive_path"
archive_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
printf '%s  %s\n' "$archive_sha256" "$archive_name" >"$checksum_path"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'archive=%s\n' "$archive_path"
    printf 'checksum=%s\n' "$checksum_path"
    printf 'sha256=%s\n' "$archive_sha256"
  } >>"$GITHUB_OUTPUT"
fi

printf 'Created %s\nSHA-256 %s\n' "$archive_path" "$archive_sha256"
