#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

: "${ASC_API_KEY_ID:?missing ASC_API_KEY_ID (see .env.example)}"
: "${ASC_API_ISSUER_ID:?missing ASC_API_ISSUER_ID (see .env.example)}"
: "${APP_BUNDLE_ID:?missing APP_BUNDLE_ID (see .env.example)}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_API_KEY_ID}.p8}"
FASTLANE_KEY_JSON="$HOME/.appstoreconnect/fastlane_api_key.json"

EXTERNAL_GROUP="${TESTFLIGHT_GROUP:-External Testers}"
CHANGELOG="${TESTFLIGHT_CHANGELOG:-Latest build.}"

export PATH="$HOME/.local/flutter/bin:$PATH"
command -v flutter >/dev/null || { echo "flutter not found in PATH"; exit 1; }
[[ -f "$ASC_API_KEY_PATH" ]] || { echo "missing API key: $ASC_API_KEY_PATH"; exit 1; }

ensure_fastlane() {
  if ! command -v fastlane >/dev/null; then
    echo "==> fastlane not found; installing via Homebrew"
    if ! command -v brew >/dev/null; then
      echo "Homebrew not found. Install fastlane manually: https://docs.fastlane.tools/" >&2
      exit 1
    fi
    brew install fastlane
  fi
}

ensure_fastlane_key_json() {
  if [[ ! -f "$FASTLANE_KEY_JSON" ]]; then
    echo "==> Writing fastlane API key JSON to $FASTLANE_KEY_JSON"
    local key_pem
    key_pem=$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$ASC_API_KEY_PATH")
    mkdir -p "$(dirname "$FASTLANE_KEY_JSON")"
    cat > "$FASTLANE_KEY_JSON" <<EOF
{
  "key_id": "$ASC_API_KEY_ID",
  "issuer_id": "$ASC_API_ISSUER_ID",
  "key": $key_pem,
  "in_house": false
}
EOF
    chmod 600 "$FASTLANE_KEY_JSON"
  fi
}

bump_build_number() {
  local pubspec="$ROOT/pubspec.yaml"
  local current new
  current=$(grep -E '^version: ' "$pubspec" | sed -E 's/^version: (.*)$/\1/')
  local name="${current%+*}" build="${current##*+}"
  new="${name}+$((build + 1))"
  /usr/bin/sed -i '' "s/^version: ${current}$/version: ${new}/" "$pubspec"
  echo "$new"
}

echo "==> Bumping build number"
VERSION=$(bump_build_number)
MARKETING_VERSION="${VERSION%+*}"
BUILD_NUMBER="${VERSION##*+}"
echo "    new version: $VERSION (marketing=$MARKETING_VERSION build=$BUILD_NUMBER)"

echo "==> Building IPA (flutter build ipa)"
flutter build ipa --release --export-method app-store

IPA=$(ls "$ROOT"/build/ios/ipa/*.ipa | head -n 1)
[[ -f "$IPA" ]] || { echo "IPA not found in build/ios/ipa/"; exit 1; }
echo "    built: $IPA"

echo "==> Uploading to App Store Connect"
xcrun altool --upload-app --type ios -f "$IPA" \
  --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID"

ensure_fastlane
ensure_fastlane_key_json

echo "==> Waiting for Apple processing and submitting for external beta review"
echo "    group:     $EXTERNAL_GROUP"
echo "    changelog: $CHANGELOG"

fastlane pilot distribute \
  --api_key_path "$FASTLANE_KEY_JSON" \
  --app_identifier "$APP_BUNDLE_ID" \
  --app_platform ios \
  --app_version "$MARKETING_VERSION" \
  --build_number "$BUILD_NUMBER" \
  --distribute_external true \
  --groups "$EXTERNAL_GROUP" \
  --notify_external_testers true \
  --changelog "$CHANGELOG" \
  --wait_processing_interval 30 \
  --skip_waiting_for_build_processing false

echo "==> Done. Build $VERSION submitted to group '$EXTERNAL_GROUP'"
echo "    https://appstoreconnect.apple.com/apps → TestFlight"
