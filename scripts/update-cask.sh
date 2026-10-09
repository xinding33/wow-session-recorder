#!/bin/sh
# Writes the wow-session-recorder cask for a release into a homebrew-tap checkout.
# Usage: scripts/update-cask.sh TAP_DIR VERSION SHA256
set -eu
TAP="$1" VERSION="$2" SHA="$3"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/wow-session-recorder.rb" <<CASK
cask "wow-session-recorder" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/xinding33/wow-session-recorder/releases/download/v#{version}/WoW-Session-Recorder-#{version}.dmg"
  name "WoW Session Recorder"
  desc "Menu bar app that records World of Warcraft and labels it from the combat log"
  homepage "https://github.com/xinding33/wow-session-recorder"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "WoW Session Recorder.app"

  uninstall launchctl: [
              "io.github.wowsessionrecorder.open-with-wow",
              "io.github.xinding33.wow-session-recorder.open-with-wow",
            ],
            quit:      "io.github.xinding33.wow-session-recorder"

  # Footage and the library stay where you chose to keep them (~/Movies/WoW Session Recorder
  # by default).
  zap trash: [
    "~/Library/Caches/io.github.wowsessionrecorder.SessionRecorder",
    "~/Library/Caches/io.github.xinding33.wow-session-recorder",
    "~/Library/Preferences/io.github.wowsessionrecorder.SessionRecorder.plist",
    "~/Library/Preferences/io.github.xinding33.wow-session-recorder.plist",
  ]
end
CASK
