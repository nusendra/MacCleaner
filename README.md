# MacCleaner

A native macOS app (SwiftUI, macOS 14+) for cleaning up and managing your Mac.

| Tool | What it does |
|---|---|
| **System Junk** | Caches, logs, broken preferences and launch agents, Xcode leftovers, old iOS backups, unused language files and CPU architectures |
| **Trash Bins** | Empties the Trash on your Mac, iCloud Drive and external drives |
| **Uninstaller** | Removes apps together with every file they leave around |
| **Leftovers** | Finds files of apps you already deleted |
| **Space Lens** | Shows folders as bubbles sized by how much they hold |
| **Duplicates** | Finds identical files and similar photos, keeping the best copy |
| **Maintenance** | Frees RAM, flushes DNS, reindexes Spotlight, thins snapshots and more |

Removed files go to the Trash, so you can put them back. The exceptions are System Junk, which deletes caches and logs permanently (they are recreated as needed), and the Trash Bins tool.

## Install

1. Download `MacCleaner-<version>.dmg`, open it and drag **MacCleaner** onto **Applications**.
2. The first time, **right-click MacCleaner → Open**, then confirm. This build is not notarized by Apple, so a normal double-click shows "Apple could not verify…". You can also allow it in **System Settings → Privacy & Security → Open Anyway**.
3. For complete results, give MacCleaner **Full Disk Access** in **System Settings → Privacy & Security → Full Disk Access**. Without it, private folders (Documents, Desktop, Mail, other apps' data) are listed but not read.

## Build from source

You need macOS 14+ with the Xcode Command Line Tools (`xcode-select --install`). Xcode itself is not required.

```bash
make run       # build and run from the terminal
make test      # unit tests (MACCLEANER_E2E=1 adds an end-to-end uninstall test)
make app       # universal dist/MacCleaner.app (Apple silicon + Intel)
make dmg       # dist/MacCleaner-<version>.dmg
make install   # copy the app to /Applications
```

`VERSION=1.2.0 make dmg` sets the version.

### Signed and notarized releases

With an Apple Developer account, sign with your Developer ID and notarize, and the app then opens without any warning:

```bash
xcrun notarytool store-credentials maccleaner --apple-id you@example.com --team-id TEAMID --password <app-specific password>
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
NOTARY_PROFILE=maccleaner scripts/make-dmg.sh
```

## Project layout

| Path | Contents |
|---|---|
| `Sources/MacCleaner` | The app (SwiftUI) |
| `Sources/JunkCleanup`, `AppUninstaller`, `SpaceLens`, `Duplicates`, `Maintenance` | One library per tool, with no UI code |
| `Sources/junkscan` | Read-only command-line dry runs (`--app`, `--leftovers`, `--lens`, `--dups`) |
| `docs/` | Behaviour notes for each tool |
| `scripts/` | App bundle, DMG and icon generation |
