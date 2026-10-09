#!/bin/sh
# Builds a public release: a notarized disk image that opens without Gatekeeper warnings.
#
#   scripts/release.sh                    writes build/WoW-Session-Recorder-<version>.dmg
#   RELEASE_VERSION=1.2.3 scripts/release.sh
#
# The version is the latest v* tag unless RELEASE_VERSION is set; pushing a v* tag runs this
# on GitHub Actions (.github/workflows/release.yml) and publishes the result.
#
# Needs, once per Mac:
#   - A "Developer ID Application" certificate in your login keychain (developer.apple.com →
#     Certificates → +, or Xcode → Settings → Accounts → Manage Certificates).
#   - Notarization credentials saved in the keychain, from an App Store Connect API key
#     (appstoreconnect.apple.com → Users and Access → Integrations → Team Keys):
#       xcrun notarytool store-credentials WoWSessionRecorder --key AuthKey_<id>.p8 \
#           --key-id <id> --issuer <issuer id> --keychain ~/Library/Keychains/login.keychain-db
#     (Without --keychain it may not be saved.) An Apple ID with an app-specific password
#     works too: --apple-id <you> --team-id <team>.
#
# DEVELOPER_ID overrides the certificate, NOTARY_PROFILE the saved credentials' name. CI sets
# NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID to use an API key directly instead.
set -eu

cd "$(dirname "$0")/.."

IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
if [ -z "$IDENTITY" ]; then
    echo "No \"Developer ID Application\" certificate in your keychain; see the top of $0." >&2
    exit 1
fi

if [ -n "${NOTARY_KEY_ID:-}" ]; then
    set -- --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
else
    PROFILE="${NOTARY_PROFILE:-WoWSessionRecorder}"
    set -- --keychain-profile "$PROFILE"
    if ! xcrun notarytool history "$@" >/dev/null 2>&1; then
        echo "No working notarization credentials named \"$PROFILE\"; see the top of $0." >&2
        exit 1
    fi
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
# hdiutil sometimes fails with "Resource busy" on CI runners; a retry gets past it.
for ATTEMPT in 1 2 3; do
    hdiutil create -quiet -volname "WoW Session Recorder" -srcfolder "$STAGE" -format UDZO "$DMG" && break
    [ "$ATTEMPT" = 3 ] && exit 1
    sleep 5
done
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "Notarizing (usually a few minutes)…"
RESULT=$(xcrun notarytool submit "$DMG" "$@" --wait --output-format json)
ID=$(echo "$RESULT" | plutil -extract id raw -o - -)
STATUS=$(echo "$RESULT" | plutil -extract status raw -o - -)
if [ "$STATUS" != "Accepted" ]; then
    echo "Notarization: $STATUS. Apple's report:" >&2
    xcrun notarytool log "$ID" "$@" >&2 || true
    exit 1
fi

# Attach the ticket so the image also opens offline.
xcrun stapler staple "$DMG" >/dev/null
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
spctl --assess --type execute --verbose=2 "$APP"
echo "Released $DMG (signed with \"$IDENTITY\", notarized)"
echo "sha256: $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
