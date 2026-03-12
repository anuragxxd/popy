# Popy

A lightweight macOS menu bar clipboard history manager. Tracks your last 25 text copies and lets you re-copy (or paste directly) with a single click.

## Features

- **Menu bar only** — lives in the top-right of your screen, no Dock icon
- **25-item history** — stores your recent text copies with relative timestamps
- **Click to copy** — click any entry to put it back on the clipboard
- **Click to paste directly** — optional mode that copies and simulates Cmd+V into the active app
- **Persistent history** — survives app restarts (stored in UserDefaults)
- **Launch at Login** — toggle to start Popy automatically on boot (macOS 13+)
- **Sound feedback** — optional subtle sound when re-copying
- **Zero dependencies** — pure AppKit/Swift, no third-party libraries
- **Tiny footprint** — polls clipboard every 0.5s using `changeCount` (no CPU/battery impact)

## Requirements

- macOS 12.0+ (Monterey or later)
- Xcode 14.0+ (to build from source)
- No Homebrew packages or third-party tools required

## Build

```bash
git clone <repo-url> popy
cd popy
bash setup.sh
```

The setup script will:
1. Generate `Popy.xcodeproj` (no XcodeGen needed — writes the project file directly)
2. Build a Release `.app` bundle
3. Print the path to run or install it

## Run

```bash
open build/Build/Products/Release/Popy.app
```

Or copy to Applications:

```bash
cp -R build/Build/Products/Release/Popy.app /Applications/
```

## Package as DMG

To create a distributable DMG with drag-to-install:

```bash
bash package.sh
```

Produces `Popy-1.0.0.dmg` with:
- `Popy.app`
- Applications symlink (drag to install)
- README.txt
- SHA-256 checksum file

## Usage

1. Click the clipboard icon in the menu bar
2. Your recent copies appear as a list with timestamps
3. Click any entry to copy it back to the clipboard
4. Configure behavior with the toggles at the bottom:

| Toggle | Description |
|---|---|
| **Click to Copy** | Default. Clicking an entry copies it to clipboard. |
| **Click to Paste Directly** | Copies and simulates Cmd+V into the frontmost app. Requires Accessibility permission. |
| **Sound on Copy** | Plays a subtle sound when re-copying an item. |
| **Launch at Login** | Start Popy automatically on boot (macOS 13+ via SMAppService). |

## "Paste Directly" Mode

When enabled, clicking an entry will:
1. Copy the text to the clipboard
2. Simulate a Cmd+V keystroke into whatever app is focused

This requires **Accessibility permissions**. macOS will prompt you to grant access in:
System Preferences → Security & Privacy → Privacy → Accessibility

## Project Structure

```
popy/
├── setup.sh                  # Build script (generates xcodeproj + builds)
├── package.sh                # DMG packaging script
├── Popy/
│   ├── main.swift            # App entry point
│   ├── AppDelegate.swift     # Menu bar UI and actions
│   ├── Models/
│   │   └── ClipboardItem.swift
│   ├── Services/
│   │   ├── ClipboardManager.swift      # Clipboard polling + persistence
│   │   ├── KeyboardSimulator.swift     # CGEvent Cmd+V simulation
│   │   ├── LoginItemManager.swift      # Launch at Login (SMAppService)
│   │   └── PreferencesManager.swift    # User preferences (UserDefaults)
│   └── Resources/
│       ├── Info.plist                  # LSUIElement=true (no Dock icon)
│       └── Popy.entitlements
├── .gitignore
├── LICENSE
└── README.md
```

## How It Works

- **Clipboard monitoring**: Polls `NSPasteboard.general.changeCount` every 0.5 seconds. Only reads the clipboard when the count changes — negligible CPU usage.
- **Deduplication**: If you copy the same text again, it moves to the top instead of creating a duplicate.
- **Persistence**: The history array is JSON-encoded via `Codable` and stored in `UserDefaults`.
- **Menu bar**: Uses `NSStatusBar` + `NSMenu` (AppKit), which works on all macOS versions. No SwiftUI `MenuBarExtra` dependency.

## CI / CD

The project includes two GitHub Actions workflows:

### `ci.yml` — Build on every push / PR
Runs on `macos-latest`. Generates the Xcode project, builds the app, and verifies the output. Triggered on pushes and PRs to `master`/`main`.

### `release.yml` — Publish a release with DMG
Triggered when you push a version tag. Builds the app, packages it into a DMG, and creates a GitHub Release with the DMG and SHA-256 checksum attached.

To cut a release:

```bash
# Update version in Popy/Resources/Info.plist if needed, then:
git tag v1.0.0
git push origin v1.0.0
```

The release will appear at `https://github.com/<owner>/popy/releases` with the DMG ready to download.

## License

MIT
