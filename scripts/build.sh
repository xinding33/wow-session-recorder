#!/bin/sh
# Builds WoW Session Recorder.app (Release) and optionally installs it to /Applications.
#
#   scripts/build.sh              build into build/
#   scripts/build.sh --install    build, then copy to /Applications (or ~/Applications if
#                                 /Applications isn't writable without admin rights)
#
# macOS remembers Screen Recording and file access permissions by the app's signature.
# Run scripts/make-signing-cert.sh once and every build is signed the same way, so you grant
# permissions once. Without it, builds are signed ad hoc and ask again after every rebuild.
# SIGN_IDENTITY overrides the identity, e.g. SIGN_IDENTITY="Apple Development".
set -eu

cd "$(dirname "$0")/.."

LOCAL_IDENTITY="WoW Session Recorder Local Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    IDENTITY="$SIGN_IDENTITY"
elif security find-identity -p codesigning | grep -q "\"$LOCAL_IDENTITY\""; then
    IDENTITY="$LOCAL_IDENTITY"
else
    IDENTITY="-"
fi

APP="build/DerivedData/Build/Products/Release/WoW Session Recorder.app"
LOG="build/xcodebuild.log"
mkdir -p build
rm -rf "$APP"

# Signed below rather than by Xcode, which wants a development team for anything but ad hoc.
if ! xcodebuild \
    -project SessionRecorder.xcodeproj \
    -scheme SessionRecorder \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u >&2 || true
    echo "Build failed; full log in $LOG" >&2
    exit 1
fi
grep -E "\.swift:[0-9]+:[0-9]+: warning:" "$LOG" | sort -u || true

codesign --force --options runtime --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
    echo "Built $APP (signed ad hoc: macOS will ask for permissions again; see scripts/make-signing-cert.sh)"
else
    echo "Built $APP (signed with \"$IDENTITY\")"
fi

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications"
    if [ ! -w "$DEST" ]; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
    fi

    osascript -e 'tell application "WoW Session Recorder" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application "Session Recorder" to quit' >/dev/null 2>&1 || true

    # Remove copies left by earlier versions of this script, so there's only one app.
    for OLD in "$HOME/Applications/Session Recorder.app" "$HOME/Applications/WoW Session Recorder.app"; do
        if [ -d "$OLD" ] && [ "$OLD" != "$DEST/WoW Session Recorder.app" ]; then
            rm -rf "$OLD"
            echo "Removed old $OLD"
        fi
    done

    rm -rf "$DEST/WoW Session Recorder.app"
    cp -R "$APP" "$DEST/"
    echo "Installed to $DEST/WoW Session Recorder.app"
fi
