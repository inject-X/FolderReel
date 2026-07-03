# FolderReel

FolderReel is a native macOS screen saver (`.saver`) that plays videos from a folder.

It is not a standalone app. After building, the output is a normal macOS screen saver bundle that can be installed from Finder or copied into `~/Library/Screen Savers`.

## Features

- Choose a local folder of videos from the screen saver options panel.
- Preview videos directly in the options panel.
- Playback modes:
  - Sequential Loop
  - Random Loop
  - Single Video Loop
- Mark the selected single-loop video with a `⭐️` prefix in the video list.
- Mutes playback by default.
- Falls back to a black message screen when no folder or playable video is configured.

## Supported Videos

FolderReel currently scans the selected folder's top level only and supports:

- `.mp4`
- `.mov`
- `.m4v`

Subfolders are not scanned.

## Build

Build a release `.saver` bundle with Xcode:

```bash
xcodebuild \
  -project FolderReel.xcodeproj \
  -scheme FolderReel \
  -configuration Release \
  -derivedDataPath /private/tmp/FolderReel-DerivedData \
  build
```

The release bundle will be created at:

```text
/private/tmp/FolderReel-DerivedData/Build/Products/Release/FolderReel.saver
```

## Install

Double-click `FolderReel.saver`, or copy it manually:

```bash
mkdir -p "$HOME/Library/Screen Savers"
cp -R /private/tmp/FolderReel-DerivedData/Build/Products/Release/FolderReel.saver \
  "$HOME/Library/Screen Savers/FolderReel.saver"
```

Then open:

```text
System Settings -> Screen Saver -> FolderReel -> Options
```

Choose a folder, select a playback mode, and save.

## Update Or Uninstall

macOS loads legacy screen savers through `legacyScreenSaver`. If System Settings or a preview is open, the `.saver` bundle can stay locked and Finder may fail to delete it.

Before replacing or deleting FolderReel:

```bash
osascript -e 'tell application "System Settings" to quit'
pkill -x legacyScreenSaver 2>/dev/null || true
pkill -x ScreenSaverEngine 2>/dev/null || true
```

Then remove the installed bundle:

```bash
rm -rf "$HOME/Library/Screen Savers/FolderReel.saver"
```

## Development Notes

- Main implementation: `FolderReel/FolderReelView.m`
- Screen saver entry point: `FolderReelView`
- Preferences are stored with `ScreenSaverDefaults`, not standard `NSUserDefaults`.
- Video playback uses `AVPlayerLayer`.
- The configuration panel is provided by `ScreenSaverView`'s `configureSheet`.
