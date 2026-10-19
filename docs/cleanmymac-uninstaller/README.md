# CleanMyMac 5 Uninstaller and Leftovers: analysis and rebuild

**Target:** `/Applications/CleanMyMac_5_MAS.app` 5.7.1, analysed statically, without running it.

**Analysed binaries:**
- `UninstallerScanning`
- `ApplicationsService`
- `ApplicationsModule`
- `ApplicationsModuleDomain`
- `ApplicationsTerminator`
- `ApplicationSelfRemoverService`
- `SharedObjcUtils`

**How:** Ghidra 12.1.4 headless decompiles, the same engine REA drives, plus symbol tables, bind tables and Swift field metadata.

## Specs

| File | Covers |
|---|---|
| [resources.md](resources.md) | How a file is attributed to an app: the 21 fetchers, the matcher, receipts, launch agents, groups |
| [apps-and-leftovers.md](apps-and-leftovers.md) | App discovery, app metadata (vendor, store, unused), special loaders, leftover detection |
| [removal-and-flow.md](removal-and-flow.md) | Removers per resource type, quitting apps, App Store and self-removal, reset, UX, config |

## Rebuild (`Sources/AppUninstaller`)

| CleanMyMac | MClean |
|---|---|
| `CMSystemApplicationsProvider` | `ApplicationDiscovery` |
| `CMApplicationInfo` | `InstalledApplication` |
| `CMDirectoryFileFinder` matching rules | `ResourceMatcher` |
| 19 `CM*Fetcher` classes | `AppResourcesScanner` (one method per fetcher family) |
| `LeftoversFetcher` | `LeftoversScanner` |
| `ApplicationRemovalTaskFactory` + per-type removers | `Uninstaller` + `ResourceRemoval` |
| `TerminatorViewModel` (Quit, then Force Quit after 5 s) | `QuitAppsSheet` |

### Behaviour kept from CleanMyMac

- **App identity:** `CFBundleIdentifier`, and `CFBundleName` with the bundle file name as fallback.
- **Matching:** only depth-1 entries are considered.
  - Bundle ID: case-insensitive substring.
  - Name: whole-word subset.
  - Later major versions ("Foo 2") are not claimed.
  - Preferences match on the bundle ID's `.` components.
- **Exact-path items:** saved state, cookies, help, sandbox container, `pkgutil` receipts (collapsed to their top-level bundle), Dock tile, and helpers in `Contents/Library/LoginItems` that are registered with launchd.
- **Leftovers:**
  - Sources: containers whose recorded `application_bundle` is gone, and reverse-DNS preference files.
  - Matching against installed IDs is a prefix match in either direction, after stripping Team IDs, the `group.`/`maccatalyst.` prefixes and 22 helper suffixes. LaunchServices and the `/Applications/<Name>.app` check also count.
- **Removal:**
  - Preferences: `defaults delete`, then `killall cfprefsd`.
  - Launch agents and login helpers: `launchctl bootout`.
  - Dock icon: `defaults export`/`import` of `com.apple.dock`, then `killall Dock`.
- **Protected bundles:** App Store, system and SIP-restricted app bundles are never removed. Their data can still be removed, which resets the app.

### Deliberate differences

- **Trash, not delete:** uninstalled items go to the **Trash**. CleanMyMac deletes permanently.
- **Leftovers start unselected.** On the test Mac one leftover was 56.8 GB of Docker Desktop VM data. It was correct to flag, but it must not be preselected.
- **Launch agents** match by `AssociatedBundleIdentifiers`, a Label starting with the bundle ID, or a Program inside the bundle. CleanMyMac's word-mode match effectively never fires.
- **Bundle-ID matches need a word boundary,** so `com.foo.app` does not claim `com.foo.application`.
- **Crash reports** in `.ips` format are included. CleanMyMac misses them.
- **Container fixes:** the container-path bug is fixed. Extension containers (`<id>.*`) and app-group containers (read from the signature's entitlements) are included.
- **Own rules instead of CleanMyMac's encrypted knowledge base:**
  - A deny-list of shared folders and vendor names.
  - Generic app names ("Notes") only match by bundle ID.
  - `com.apple.*`, system-group and framework IDs (Sparkle, Qt, Segment…) are never leftovers.
  - Version-insensitive family matching: `net.telestream.screenflow.globallibrary` belongs to `…screenflow10`.
  - Same-vendor shared files stay while the vendor has an app installed (`com.microsoft.shared`, `us.zoom.updater.config`).
  - Helper leftovers fold into their app (`com.googlecode.iterm2.private` folds into `com.googlecode.iterm2`).
- **App discovery** also scans `~/Applications`. It lists dot-files only explicitly, because Safari in `/Applications` is a hidden symlink into a Cryptex. Apps whose real path is under `/System` count as system apps, so Safari can only be reset.
- **Not rebuilt:**
  - Steam, Battle.net and JetBrains loaders
  - Audio plugins
  - iOS-on-Mac apps
  - Package-receipt forgetting (needs root)
  - Legacy LSSharedFileList login items
  - The App Updater

## Verification

- `make test`: unit tests for the matcher, leftover rules, resource scanner, removal order and discovery.
- `MCLEAN_E2E=1 make test` installs a probe app in the real home folder, with preferences, caches, support files and a loaded launch agent. It uninstalls the probe and asserts that the files are gone, the agent is unloaded and the defaults domain is cleared. The probe's files land in the Trash.
- `.build/debug/junkscan --app <name>` and `--leftovers` are dry runs. They print what would be removed.
