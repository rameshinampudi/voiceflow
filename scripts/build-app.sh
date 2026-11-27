#!/usr/bin/env bash
# Builds build/VoiceFlow.app from the Swift package.
#
# Signing: macOS ties Microphone/Accessibility permissions to the app's signature.
# An ad-hoc signature changes on every build, so you'd re-grant Accessibility after
# each rebuild. Run scripts/create-signing-cert.sh once to get a stable local identity.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/VoiceFlow.app"
IDENTITY="${VOICEFLOW_SIGN_IDENTITY:-}"
LOCAL_CERT="VoiceFlow Local Signing"

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG" --product VoiceFlow
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceFlow" "$APP/Contents/MacOS/VoiceFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

if [ -z "$IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$LOCAL_CERT"; then
  IDENTITY="$LOCAL_CERT"
fi

if [ -n "$IDENTITY" ]; then
  echo "→ signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" --identifier local.voiceflow.dictation "$APP"
else
  echo "→ ad-hoc signing (run scripts/create-signing-cert.sh so permissions survive rebuilds)"
  codesign --force --sign - --identifier local.voiceflow.dictation "$APP"
fi

echo "✔ $APP"
