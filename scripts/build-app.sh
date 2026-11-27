#!/usr/bin/env bash
# Builds build/Airflow.app from the Swift package.
#
# Signing: macOS ties Microphone/Accessibility permissions to the app's signature.
# An ad-hoc signature changes on every build, so you'd re-grant Accessibility after
# each rebuild. Run scripts/create-signing-cert.sh once to get a stable local identity.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/Airflow.app"
IDENTITY="${AIRFLOW_SIGN_IDENTITY:-}"
LOCAL_CERT="Airflow Local Signing"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG" --product Airflow
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Airflow" "$APP/Contents/MacOS/Airflow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$LOCAL_CERT"; then
  IDENTITY="$LOCAL_CERT"
fi

if [ -n "$IDENTITY" ]; then
  echo "→ signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" --identifier local.airflow.dictation "$APP"
else
  echo "→ ad-hoc signing (run scripts/create-signing-cert.sh so permissions survive rebuilds)"
  codesign --force --sign - --identifier local.airflow.dictation "$APP"
fi

echo "✔ $APP"
