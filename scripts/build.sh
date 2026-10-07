#!/bin/sh
# Builds WoW Session Recorder.app (Release) and optionally installs it to /Applications.
#
#   scripts/build.sh              build into build/
#   scripts/build.sh --install    build, then copy to /Applications (or ~/Applications if
#                                 /Applications isn't writable without admin rights)
#
# macOS ties the Screen Recording permission to the app's code signature. Ad-hoc builds
# (the default) get a new signature every build, so you'll be asked to re-grant permission
# after rebuilding. Sign with a stable identity to avoid that:
#
#   SIGN_IDENTITY="Apple Development" scripts/build.sh --install
set -eu

cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"

xcodebuild \
    -project SessionRecorder.xcodeproj \
    -scheme SessionRecorder \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    build | grep -E "error|warning: |BUILD" || true

APP="build/DerivedData/Build/Products/Release/WoW Session Recorder.app"
[ -d "$APP" ] || { echo "Build failed" >&2; exit 1; }
echo "Built $APP"

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
