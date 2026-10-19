# CleanMyMac 5 System Junk: analysis and rebuild

**Target:** `/Applications/CleanMyMac_5_MAS.app` 5.7.1, analysed statically, without running it.

**Analysed binaries:**
- `SystemJunkScanning`
- `JunkCleanupModule`
- `CleaningCore`
- `ScanningCore`
- `TrashJunkScanning`
- `SharedObjcUtils`
- `LegacyScanningCore`
- `FileManagerService`

**How:** Ghidra 12.1.4 headless decompiles, plus REA function dossiers. Example: `ev_7135fad3…`, the `CMHardcodedPathCacheScanTask _groups` dossier. Symbol tables, bind tables and Swift reflection metadata filled in the rest.

## Specs

| File | Covers |
|---|---|
| [engine.md](engine.md) | Scanner list and gating, watchdog timeouts, result tree, sizing, auto-selection, the cleaning pipeline, sandbox permissions, UX flow |
| [caches.md](caches.md) | User, system and container caches, Electron, App Store, Spotify, Gradle, Dropbox, hard-coded app caches |
| [logs.md](logs.md) | User, sandbox and quarantine logs; system and private logs; truncate-vs-delete rule |
| [xcode.md](xcode.md) | DerivedData, Archives, DeviceSupport, module and doc caches, simulators (`simctl`), runtimes |
| [misc.md](misc.md) | Language files, universal binaries, broken prefs, launch agents, document versions, iOS backups, deleted users, trash |

Every claim in the specs is tagged:
- **[O]** observed in code
- **[I]** inferred
- **[?]** unknown

## Rebuild (`Sources/JunkCleanup`)

| CleanMyMac | MacCleaner |
|---|---|
| ObjC `CM*ScanTask` + `LegacyScanTaskWrapper` | `JunkScanTask` structs in `Scanners/` |
| `ProcessingQueue` + `TaskWatcher` (60 s; 300 s for document versions and runtimes) | `JunkScanner`: `TaskGroup`, with each task raced against its timeout |
| `CMByteSizer` (`fts` sum of `st_blocks`, allocated size) | `FileSizer.allocatedSize` (same algorithm, without the Spotlight shortcut) |
| `TasksProcessor` (serial) + `FileRemover` / `LogsRemover` / `simctl` / `NSFileVersion` / lipo | `JunkCleaner` (serial, one result per item, `RemovalAction` enum) |
| `CleanQueueResult.outcome` | `JunkCleanReport.outcome` (`success`, `partialSuccess`, `empty`, `failure`) |
| Knowledge-base ignore list + undo | `IgnoreList` (UserDefaults), set from the context menu ("Ignore in Future Scans") |
| `RunningApplicationsDependenciesResolver` | Quit-apps alert before cleaning (`quitBeforeCleaning`) |

## Deliberate differences

- **Scanner set:** MacCleaner is not sandboxed, so it uses CMM's direct-download (non-App-Store) scanner set: system caches and logs, deleted users, startup items, iOS backups, languages and universal binaries.
- **No privileged helper:** CMM retries root-owned items through its helper. MacCleaner only offers items the current user can delete (`FileManager.isDeletableFile`).
- **Rule database:** CMM's ignore and deep-search rules ship in the encrypted `Contents/Resources/info.cmmkb`. It was **not** decrypted. MacCleaner uses its own user ignore list. The app-cache paths are public facts recorded in the specs.
- **Not rebuilt:**
  - Login items, because the `LSSharedFileList` API is gone.
  - Mail trash and Mail attachments, which live in a separate framework and need Full Disk Access.
  - AI clutter scanners.
- **No artificial delay:** CMM pads each cleaning task to at least 2 s. MacCleaner does not.
- **Thinning implementation:** universal binaries are thinned with `/usr/bin/lipo -extract` into a temporary folder outside the bundle, instead of CMM's in-house writer. It was verified on a copy of Ghostty.app: `codesign --verify --deep --strict` still passes and the app runs. The same check passed after removing the language files.
- **Permanent delete:** removal is permanent, as in CMM (it never uses the Trash). MacCleaner adds a confirmation dialog first.

## Tools

- `make run`: the app. Click **System Junk** or **Trash Bins**.
- `make test`: unit tests.
- `.build/debug/junkscan [-v]`: a dry-run scan that prints what would be offered and never deletes anything.
- `.build/debug/junkscan --languages <App.app>`: lists the lproj folders that would be removed from one bundle.
