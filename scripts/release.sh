#!/bin/sh
# Builds a public release: a notarized disk image that opens without Gatekeeper warnings.
#
#   scripts/release.sh    writes build/WoW-Session-Recorder-<version>.dmg
#
# Needs, once per Mac:
#   - A "Developer ID Application" certificate in your login keychain (developer.apple.com →
#     Certificates → +, or Xcode → Settings → Accounts → Manage Certificates).
#   - Notarization credentials saved in the keychain:
#       xcrun notarytool store-credentials WoWSessionRecorder --apple-id <you> --team-id <team>
#     It asks for an app-specific password, made at account.apple.com → Sign-In and Security.
#
# DEVELOPER_ID overrides the certificate, NOTARY_PROFILE the saved credentials' name.
set -eu

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-WoWSessionRecorder}"
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"

if [ -z "$IDENTITY" ]; then
    echo "No \"Developer ID Application\" certificate in your keychain; see the top of $0." >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No working notarization credentials named \"$PROFILE\"; see the top of $0." >&2
    exit 1
fi

SIGN_IDENTITY="$IDENTITY" scripts/build.sh

APP="build/DerivedData/Build/Products/Release/WoW Session Recorder.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/WoW-Session-Recorder-$VERSION.dmg"

# The disk image holds the app and a shortcut to Applications to drag it onto.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "WoW Session Recorder" "$STAGE" "$DMG" >/dev/null 2>&1
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing (usually a few minutes)…"
RESULT=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json)
STATUS=$(echo "$RESULT" | plutil -extract status raw -)
if [ "$STATUS" != "Accepted" ]; then
    ID=$(echo "$RESULT" | plutil -extract id raw -)
    echo "Notarization: $STATUS. Apple's report:" >&2
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    exit 1
fi

# Attach the ticket so the image also opens offline.
xcrun stapler staple "$DMG" >/dev/null
spctl --assess --type open --context context:primary-signature "$DMG"
echo "Released $DMG (signed with \"$IDENTITY\", notarized)"
