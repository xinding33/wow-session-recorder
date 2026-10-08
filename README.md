<img src="assets/icon.png" width="96" height="96" alt="">

# WoW Session Recorder

A lightweight macOS menu bar app that records retail World of Warcraft and turns your
combat log into a reviewable library: every boss pull, Mythic+ key, arena match and death,
each one click away.

Created in [T3 Code](https://t3.codes).

## How it works

- **Capture.** While WoW is running, [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
  records only the WoW window (no notifications or other apps) plus game audio. Video is
  encoded as HEVC on Apple Silicon's media engine into one-minute segment files.
- **Labelling.** The app follows `_retail_/Logs/WoWCombatLog-*.txt` and turns events into
  activities:
  - `CHALLENGE_MODE_START/END` → a Mythic+ run, with boss pulls, kills and wipes as markers
  - Entering a delve → one delve run until you leave, with the boss as a marker
  - `ENCOUNTER_START/END` → a raid or dungeon boss pull (kill or wipe)
  - `ARENA_MATCH_START/END` → an arena match (win or loss)
  - `UNIT_DIED` → death markers for you and your group (Feign Death is ignored)
  - your interrupts and dispels, your major cooldowns, Bloodlust and battle resses → markers
- **Details.** Each activity also records your character and spec, the group's specs, pull
  numbers per boss per night, the boss's lowest health on wipes, and for keys the level,
  affixes and whether it was timed (+1/+2/+3) or depleted. It also remembers where in the
  combat log the activity lives, for features that re-read it later.
- **Trimming.** Footage is recorded continuously and matched to events by timestamp, so the
  combat log's write delay never costs you the start of a pull. Footage outside any activity
  is deleted after 24 hours (configurable); activities are kept for 30 days, favorites forever.
- **Playback.** Segments are stitched into a single seamless timeline on the fly, with
  markers on the scrub bar, a marker list, 0.25×–2× speed, frame stepping and passthrough
  MP4 export.
- **Review.** Click a death to see a death recap: every hit and heal in the 10 seconds before
  it, with health after each, read back from the combat log (so it needs that log file to
  still be in `_retail_/Logs`). Click a line to see that moment. Set start and end points to
  export part of a recording or keep it as a clip, show or hide marker types, and write notes
  on any activity.
- **Library.** Search titles, places and notes, and filter by boss or dungeon, result
  (kill, wipe, timed, depleted, completed, abandoned), key level, date and character. Each
  row has a thumbnail from its footage. Select several activities (⌘- or ⇧-click, ⌘A) to
  favorite or delete them together.

## Requirements

- macOS 15 or later, Apple Silicon recommended
- Xcode 16 or later to build

## Build and run

```sh
scripts/build.sh --install          # builds Release, copies to /Applications
open /Applications/WoW\ Session\ Recorder.app
```

Or open `SessionRecorder.xcodeproj` in Xcode and run the **SessionRecorder** scheme.

On first launch:

1. **Grant Screen Recording permission** when macOS asks (System Settings → Privacy &
   Security → Screen & System Audio Recording), then relaunch the app.
2. **Install the helper addon** from Settings → World of Warcraft (see below), or type
   `/combatlog` in game each session.

> macOS remembers permissions by the app's code signature. Run `scripts/make-signing-cert.sh`
> once to add a local signing certificate to your keychain; every build is then signed the same
> way and keeps its permissions. Without it, builds are signed ad hoc and macOS asks again
> after every rebuild. `SIGN_IDENTITY="Apple Development" scripts/build.sh` uses an Apple
> developer certificate instead.

## The helper addon

WoW turns combat logging off at every logout, and without the log there's nothing to label.
`addon/SessionRecorderHelper` is a tiny addon that:

- turns combat logging on when you enter a dungeon, raid, delve, arena or battleground, and
  back off when you leave (only if it turned it on itself)
- enables Advanced Combat Logging if it's off
- saves Mythic+ timers, affix names and spec names from the game (the combat log only has
  IDs), so keys show timed/depleted
- saves which of your class and spec spells have a cooldown of a minute or more, so the app
  can mark when you use them

WoW writes this data on logout or `/reload`, so timed/depleted results and cooldown markers
appear after your first logout or `/reload` with the addon installed. Cooldowns are learned
per character, so log in on each character once.

The app can install it for you with one click. In game, `/srh` shows its status;
`/srh always` and `/srh off` change its mode.

## Only recording in instances

Settings → Recording → **Record: Only in instances** records only in dungeons, raids and
delves, including Mythic+. Recording starts when you zone in and keeps going for 2 minutes
after you leave; a key in progress keeps recording even if you step outside. WoW can hold
combat log lines back for a minute or more, so recording starts as soon as a new log file
appears (the helper addon starts one when you zone in) rather than waiting for its contents. This skips
town, queues and character select, roughly 6 GB per hour of footage that would otherwise
be deleted.

- It reads your location from the combat log, so it needs the helper addon (or
  `/combatlog`). If the addon is missing or turned off in WoW's addon list, it falls back
  to recording everything and says so.
- If the log goes quiet for 5 minutes, it assumes you've left the instance even if WoW never
  wrote the zone change.
- Battlegrounds and other PvP aren't detected.
- In the open world, ⌃⌥B starts a 1-minute recording from the moment you press it (there's
  no earlier footage to save), and ⌃⌥C records until you press it again.

## Opening with WoW

Settings → World of Warcraft → **Open WoW Session Recorder** has three choices:

- **When WoW launches.** Nothing runs while you're not playing. A launchd agent
  (`~/Library/LaunchAgents/io.github.wowsessionrecorder.open-with-wow.plist`) watches files
  WoW rewrites at startup in `_retail_/Logs` and opens the recorder. The recorder quits
  itself when WoW quits, unless the library window is open.
- **At login.** Stays in the menu bar.
- **Manually.**

**Also open with WoW** opens any other apps you play with in the
background when WoW starts. If you choose, it quits them 30 seconds after WoW quits,
giving them time to sync.

## Using it

| Action | How |
| --- | --- |
| Bookmark a moment | **⌃⌥B**. Adds a marker to the current activity, or saves a 40-second clip if nothing is in progress |
| Start or stop a manual clip | **⌃⌥C** |
| Pause recording | Menu bar → Pause Recording |
| Review | Menu bar → Open Library… |

In the player:

| Key | Action |
| --- | --- |
| **K** | Play or pause |
| **[** / **]** | Previous or next marker |
| **←** / **→** | Step one frame |
| **I** / **O** | Start or end the selection here |
| **X** | Clear the selection |

With a selection, **Export → Export Selection…** saves just that part as an MP4 without
re-encoding, and the scissors button keeps it in the library under Clips, so its footage
outlives the rest. The filter button above the marker list shows or hides marker types
(interrupts, dispels, cooldowns and so on); the choice is remembered. The **Notes** tab saves
as you type; a note icon marks activities with notes in the library.

Footage lives in `~/Movies/WoW Session Recorder` by default and can be moved in Settings.
Thumbnails are cached next to it in `Thumbnails/` (about 20 KB each). They're made the first
time a row is shown, and only while the recorder is the frontmost app, so nothing is decoded
while you play. Each one decodes a single keyframe (around 15 ms). A thumbnail is deleted
with its activity, and kept if the activity's footage is cleaned up first.
Expect roughly 6–9 GB per hour at 1440p60 before trimming.

## Project layout

```
Packages/RecorderCore/     Pure Swift logic, unit-tested with `swift test`
  CombatLogParser.swift      log line and timestamp parsing
  ActivityTracker.swift      events → activities state machine
  DeathRecap.swift           death recaps, read back from log files on demand
  Segments.swift             segment naming, index, sessions
  PlaybackTimeline.swift     wall-clock ↔ playback time across segment gaps
  Retention.swift            what to delete and when
  ActivityFilter.swift       library search, filters and the choices they offer
  Thumbnails.swift           which frame a thumbnail shows, and its cache files
SessionRecorder/           The app
  Capture/                   ScreenCaptureKit stream and HEVC segment writer
  CombatLog/                 log file tailer
  System/                    WoW detection, global hotkeys, addon installer
  Views/                     menu bar, library, player, settings
addon/SessionRecorderHelper/ The WoW addon (bundled into the app at build time)
scripts/make-icon.swift      Draws the app icon; rerun after editing it
scripts/make-signing-cert.sh Creates the local signing certificate, once per Mac
```

Run the core tests with:

```sh
cd Packages/RecorderCore && swift test
# Optionally smoke-test against a real log:
COMBAT_LOG_PATH=/path/to/WoWCombatLog-....txt swift test --filter parsesRealLog
```

## Troubleshooting

The app logs to the unified log. In zsh, `log` is a shell built-in, so use the full path:

```sh
/usr/bin/log stream --predicate 'subsystem == "SessionRecorder"' --level info
```

Each finished segment logs how many frames WoW delivered and how many the encoder dropped.
Drops should be 0. A low frame rate with no drops means WoW itself was rendering slowly
(e.g. its background frame cap while unfocused).

## Known limitations

- Footage from the last minute isn't playable until its segment finishes.
- If the app starts mid-key, that key isn't detected, because the log is read from the end
  on launch.
- Microphone and voice chat aren't recorded.
- Hotkeys are fixed.
