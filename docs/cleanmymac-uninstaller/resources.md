# CleanMyMac 5 (MAS 5.7.1): Uninstaller "which files belong to an app" spec

This spec comes from static analysis only. Addresses are function entry points.
**US** = UninstallerScanning (default binary), **AS** = ApplicationsService, **AMD** = ApplicationsModuleDomain, **AM** = ApplicationsModule, **SOU** = SharedObjcUtils, **KBS** = KnowledgeBaseService.
Evidence tags: **[O]** observed in code · **[I]** inferred · **[?]** unknown.

---

## 0. Pipeline

1. `CMResourcesFetcher.uninstallerFetcher(fullDiskAccessPermissionProvider:knowledgeBase:isForPlugin:…)` @US 0x31d64 picks a builder. [O]
   * Apps use `CMResourcesFetcherBuilder buildWithKnowledgeBase:isFDAGranted:…` @0x8a70. It runs 19 fetchers in this order: SupportingFiles, PreferencesFiles, LaunchDemons, CrashLogs, Cookies, LoginItems, Logs, ApplicationSavedState, LibraryPaths, PDFServices, Plugins, ApplicationHelp, ExtraFilesForSandboxedApplication, TempFiles, ApplicationContainer, Receipt, ResourcesFromKnowledgeBase, DockIcon, Caches. **DownloadFiles is added only when Full Disk Access is granted.** [O]
   * Plugins use `buildForPlugins…` @0x8eb4. It drops LaunchDemons, Receipt and DockIcon and adds `CMPluginResourcesFetcher`. [O]
   * Launch agents use `buildForLaunchAgents…` @0x928c, which runs only `CMLaunchDemonsFetcher`. [O]
2. `fetchAllResourcesForApplication:addAppBundleToResourceList:` @0x7958 [O]:
   * **Nested apps.** `CMResourceFetcherHelper appsInsideBundleAtPath:` @0x63a0 recursively enumerates `<app>/Contents/Library` and `<app>/Contents/MacOS`. It keeps every `*.app` whose path does not contain `/Frameworks/` (filter FUN_00006590). Each nested app is fetched recursively with `addAppBundle = NO`, and its resources are merged into the result.
   * **The bundle itself.** It becomes a resource of type `4` (Binaries), value = app path. `removable = !app.isRestricted && !KB.isAppProtectedWithBundleId(bundleID)`. `isRestricted` = `NSFileManager isFileRestricted:` on Info.plist @AS 0x26c0, which is the SIP-restricted flag [I].
   * Each fetcher's `fetchResourcesForApplication:` runs in turn. A per-fetcher cache keyed by fetcher class name and then app path is consulted first (`applicationsResourcesForApplication:forFetcher:` @0x871c).
   * The results go into an `NSMutableSet`. `CMApplicationResource isEqual:` means same `value` string AND same `type`, and the hash is `value.hash ^ type` (@0x5790/0x5858). The same path can therefore appear under two different types. [O]
3. **App identity inputs** (AS):
   * `bundleID` = trimmed `CFBundleIdentifier` (@0x21fc).
   * `name` = `CFBundleName` when it is a string, else the bundle filename without `.app` (@0x2358). This is not the display name and not the executable name. [O]
   * `privilegedExecutables` = keys of `SMPrivilegedExecutables` (@0x2e60).
   * `sandboxContainerPath` = `~/Library/Containers/%@/Data` with bundleID (@0x2508).
   * Paths come from CMPaths (SOU). `userHome` is the real home directory even when sandboxed (`APP_SANDBOX_CONTAINER_ID` check @SOU 0x10ebc). `libraryPaths` = `[~/Library, /Library]` (@SOU 0x11768). `applicationSupportPaths` = `[~/Library/Application Support, /Library/Application Support]` (@SOU 0x11924). [O]

## 1. Core matcher: `CMDirectoryFileFinder` (US)

Request = `{name, lowercasedName, path, matchByWords, customMatcher}` (`initWithName:atPath:matchByWords:` @0x1a9d8). Requests with an empty name are dropped (@0x18f00). [O]

**Enumeration** (`fastEnumerateFilesAtPath:onFile:` @0x19c10) [O]:
* Uses `fts_open(path, FTS_NOCHDIR|FTS_NOSTAT|FTS_PHYSICAL)`, so symlinks are not followed.
* Every entry gets `fts_set(FTS_SKIP)`, so **only the immediate children of the root are visited** (depth 1).
* Hidden files are included.
* Any entry whose name equals the root's last path component is skipped.
* Roots `""`, `"/"` and `"."` are refused.
* An entry counts as a directory when `fts_info` ∈ {FTS_D, FTS_DNR, FTS_DP}.

**Per-entry match** (block FUN_000193cc) [O]:
```
full  = lowercase(entryName)                       // extension kept
base  = lowercase(lastPathComponent(isDir ? entryName : entryName minus extension))
for each request:
  if isValidVersionPattern(base, req.lowercasedName): skip      // exclusion, see below
  if req.customMatcher:   match = customMatcher(req, base)
  elif req.matchByWords:  match = every word of req.nameComponents ∈ base.split(" ")
  else:                   match = full.contains(req.lowercasedName)   // case-insensitive substring
```
* `nameComponents` = `lowercasedName` split on the character set `"._ "` (@0x1ac28). The file side is split on `" "` only (@0x195a0). The word check is an order-independent, whole-word subset test (`…NameComponents:matchedByWords…` @0x1a3a0, confirmed in the disassembly). [O]
* **Version exclusion** (`isValidVersionPattern:forApplicationName:` @0x19e78) [O]:
  * condition: `lower(base).hasPrefix(lower(appName))` AND the regex `\s*\d+` (case-insensitive, FUN_00019f84) matches anywhere in the rest of the name after the prefix.
  * effect: such entries are rejected. Examples: "Foo 2", "Foo2", "com.foo.app2" and "Foo Helper 3" are all rejected for "Foo" / "com.foo.app". The purpose is to avoid catching another major version's data [I].
* There is no minimum-length check and no generic-name stop list in the finder. Generic-name protection comes only from the KB (§3). [O]

Consequences [I]:
* A bundle-ID request (substring mode) catches `com.foo.app.plist`, `com.foo.app.helper`, `group.com.foo.app` and also `com.foo.application`. The last one is a false positive.
* A name request in word mode catches "Visual Studio Code" and "Visual Studio Code - Insiders", but not "VisualStudioCode" or "Visual.Studio.Code".

## 2. Fetchers

`skipKB` means the fetcher does **not** call `KB isIgnoreOrSystemItemFileWithPath:`. Every other fetcher drops any path that call accepts. Unless stated otherwise, `removable` = YES (default in `initWithValue:…sizeProvider:` @0x56ac). "name≠bid" means the name request is added only when `bundleID != name` (`isEqualToString`, case-sensitive).

| Fetcher (fetch @addr) | Paths searched | Match rule | Type |
|---|---|---|---|
| **SupportingFiles** @0x14d8c | `~/Library/Application Support/*`, `/Library/Application Support/*`, `~/Library/Application Support/Adobe/AIR/ELS/*` (bundleID only) | bundleID substring (only when name≠bid) + name words | 0x20 |
| **LibraryPaths** @0xf2b8 | `~/Library/*`, `/Library/*` (top level only) | bundleID substring (only when name≠bid) + name words | 0x10 |
| **Caches** @0xaf00 (batched via `filesForApplications:` @0x1a4cc) | `~/Library/Caches/*`, `$DARWIN_USER_CACHE_DIR/*` (`darwinUserCaches` @SOU 0x120a8: confstr path with the sandbox container ID stripped) | bundleID substring (only when name≠bid) + name words, on both roots | 0x2 |
| **TempFiles** @0x15728 | `userTempPath/*` (stringByStandardizingPath of the temporary directory @SOU 0x12340; [I] NSTemporaryDirectory) | bundleID substring (only when name≠bid) + name words | 0x2 |
| **Logs** @0x10120 | `~/Library/Logs/*`, `/Library/Logs/*` | bundleID substring (only when name≠bid) + name words | 0x8 |
| **PDFServices** @0x109dc | `~/Library/PDF Services/*`, `/Library/PDF Services/*` | name words only | 0x80 |
| **PreferencesFiles** @0x12f84 | top-level contents of `~/Library/Preferences` and `/Library/Preferences`, skipping hidden files (`CMSystemPreferencesProvider` @AS 0xc030/0xc160). Each key = `lowercase(lastPathComponent)` with the extension stripped for files, then a trailing `.plist` stripped again (FUN_000098e0 @AS). ByHost is not descended. | (a) **bundleID**: all `.`-components of bid ∈ `.`-components of the pref name, as an order-free set, with the version exclusion (`…separator:` @0x19fc8). (b) when name≠bid, **name**: all `"._ "`-words of name ∈ `"._ "`-words of the pref name (`…separators:` @0x1a1b4). The URL must be reachable. | 0x1 |
| **ApplicationContainer** @0x94a8 → `_fetch…containers:` @0x981c | `~/Library/Containers/<bid>/Data`; see §2.1 | exact bundleID directory | per subfolder |
| **ExtraFilesForSandboxedApplication** @0xda64 | children of `~/Library/Containers/<bid>/Data/Library` (CMFTS, non-recursive, symlinks skipped). Requires `Containers/<bid>` to exist. | everything except lowercase names in {application support, logs, preferences, saved application state, caches, cookies, application scripts, images, .ds_store} (const array 0x57580) | 0x20 |
| **ApplicationSavedState** @0xa8fc | `~/Library/Saved Application State/<bid>.savedState` | exact, must exist | 0x400 |
| **Cookies** @0xb824 | `~/Library/Cookies/<bid>.binarycookies` | exact, must exist | 0x100000 |
| **ApplicationHelp** @0xa2cc | `~/Library/Preferences/SDMHelpData/Other/<bid>.help`, `/Library/Documentation/Applications/<name>` | exact, must exist | 0x2000 |
| **CrashLogs** @0xbcfc (skipKB) | for each `L` in libraryPaths: `L/Logs/CrashReporter/<name>.crash.log` (exact); `L/Logs/CrashReporter/*` with suffix `.crash`; `L/Logs/DiagnosticReports/*` with suffix `.crash`/`.diag`/`.hang`/`.spin`; `L/Application Support/CrashReporter/*` with suffix `.plist`; `L/Logs/HangReporter/<name>/*` with suffix `.hang` | case-sensitive `hasPrefix(name + "_")` plus the suffix (filters FUN_0000c458/c4fc/c5dc/c680). **`.ips` files are not matched.** [O] | 0x40 |
| **DownloadFiles** @0xd118 (FDA only; skipKB) | `~/Downloads/*` | custom matcher FUN_0000d240: every `"._ "`-word of the lowercase app name is a **substring** of the lowercase file name. Only extension `dmg` is kept (@0xd388). | 0x40000 |
| **Plugins** @0x126d4 | (1) recursively enumerate the app bundle (skip package descendants and hidden files) and collect the last path component of every item whose extension is in {plugin, webplugin, component, bundle, mdimporter, qlgenerator, mailbundle, service, workflow, osax} (const 0x57568; `originalPluginsForApplicationWithURL:` @0x12af8). (2) for each name, check `<root>/<name>` in pluginsPaths = /Library/{QuickTime, Internet Plug-ins, QuickLook, Contextual Menu Items, Spotlight, InputManagers, iTunes/iTunes Plug-ins, Address Book Plug-Ins, Mail/Bundles, Services, ScriptingAdditions} plus the `~/` variant of each (@0x60f4) | exact name of a plugin shipped inside the bundle, must exist | 0x80 |
| **LaunchDemons** @0xe1bc | see §5 | | 0x200 |
| **LoginItems** @0xfabc | see §5 | | 0x100 / 0x8000 |
| **DockIcon** @0xcb50 (skipKB) | `defaults export com.apple.dock $TMPDIR/com.apple.dock.tmp.<UUID>.plist`, then `persistent-apps` + `persistent-others` (@0x6824) | tile-type `file-tile`/`directory-tile` and `tile-data.file-data._CFURLString`→path **==** app path (@0x6ae0) | 0x1000, value = app path |
| **Receipt** @0x13780 | see §6 | | resourceTypeByPath / 0x800 |
| **ResourcesFromKnowledgeBase** @0x14194 (skipKB) | `KB additionalFilesForApplicationName:bundleId:` (§3.2) | KB-defined. Type 0x4000 → `resourceTypeByPath`. Type 0x10 → `resourceTypeByPath` unless that returns 0x4000. Type 0x800 + `isInstalledPackageWithID(name)` → full receipt expansion (§6). | KB |
| **PluginResources** (plugin flow only) @0x11308 | `commonPluginResourcesPaths` (`~/Documents`, `~/Application Support` — note: no `Library/` component, @SOU 0x11a90 — and `/Library/Application Support`) plus vendor-mark paths (`buildAllVaildPaths…VendorMark:` @0x11eb0, …ApplicationSupport/Library/Documents ± "Presets") | bundleID substring (only when name≠bid) + name words, plus a custom handler: `potentialPluginNameFromString:` (@0x12070; "com.x.y" → last component, joining a trailing numeric component; else the last space-word, again joining a trailing number) then `matchFilesLhs:rhs:commonComponent:` (@0x11b98; `"._ "`-word match that ignores the vendor word and numeric words). `canRemoveResourceWithPath:` @0x11b38 = `!hasPrefix("/Library") \|\| !hasPrefix("/System")`, which is always YES (bug). | 0x20 |

### 2.1 ApplicationContainerFetcher detail (@0x981c) [O]
* Runs only when bundleID is non-nil. The container `C = ~/Library/Containers/<bid>/Data` must exist and must not be KB-ignored.
* For each key in the const dict 0x57658, list the children of `C/<key>`. Skip the names `.DS_Store`, `Library`, `Documents` and `CrashReporter`, skip symlinks (`NSFileTypeSymbolicLink`), skip KB-ignored paths, and emit one resource per child with the mapped type:
  `/`→0x10, `/Documents`→0x10, `Library/Application Support`→0x20, `Library/Application Support/CrashReporter`→0x40, `Library/Caches`→0x2, `Library/Cookies`→0x100000, `Library/Logs`→0x8, `Library/Preferences`→0x1, `Library/Saved Application State`→0x400.
* Also emits `C + "Library/<name>"` as 0x10 if it exists. This is a plain string append with no "/" (`stringByAppendingFormat:@"Library/%@"`), so in practice the path never exists [I] (bug).
* Finally emits the whole container directory `~/Library/Containers/<bid>` (the trailing `Data` is stripped) as **0x20000 Container**.
* `isInsideContainer` = `type != 0x20000 && value.hasPrefix(~/Library/Containers)` (@0x5528). The UI uses it to nest these items under the container (AM FUN_00031d38/00032254) [I].
* **Mobile (iOS-on-Mac) apps** (`fetchResourcesForMobileApplication:` @0x956c): the candidate set is every container whose `.com.apple.containermanagerd.metadata.plist` `MCMMetadataIdentifier` **hasPrefix(bundleID)** (case-sensitive; `CMApplicationsContainerStorage` @AS 0x6bb8), plus the app's own container. This catches extension containers `bid.*`.
* **Group Containers** (`~/Library/Group Containers/<TEAMID>.*`, `group.*`): no uninstaller fetcher references `sandboxGroupContainer` or `securityApplicationGroupIdentifiers`. They reach the result only through the KB [O, by absence] (or through substring hits, which cannot happen because no fetcher scans that root).

### 2.2 `CMResourceFetcherHelper resourceTypeByPath:` @0x5d58 [O]
Checked in this order:
1. subpath of `/Library/Application Support` → 0x20
2. `.app` extension, or prefix `/usr/local/bin` or `/usr/bin` → 0x4
3. subpath of `/Library/Logs` → 0x8
4. subpath of `/Library/PDF Services`, or extension in the plugin list → 0x80
5. subpath of `~/Library/LaunchAgents`, `/Library/LaunchAgents` or `/Library/LaunchDaemons` → 0x200
6. subpath of `/System/Library/Extensions` or `/Library/Extensions` → 0x10000
7. anything else → 0x4000 (Other)

## 3. Safety and exclusions

### 3.1 Knowledge base (UninstallerKnowledgeBase, AMD; backed by KBS `KnowledgeBaseScannerService`)
* `isIgnoreOrSystemItemFileWithPath:` @AMD 0x146d8 → FUN_0001459c is TRUE if any of these hold [O call chain; method mapping I]:
  * user custom-ignore `(category 1, valueType 4)` (an ignored file/path)
  * user custom-ignore `(1001, 0)`
  * KB `isPathIgnored` (+0x10)
  * second service `isSystemItemAtPath` (+0x18)
* `isAppProtectedWithBundleId:` @0x13f1c → KB `isAppProtected(withBundleId:)`. It only makes the bundle resource non-removable. The app's other files are still listed. [O]
* `isAppIgnoredWithBundleId:` @0x13dec = custom-ignore (0,3) ∨ (1000,0xD) ∨ KB +0x10. `isApplicationIgnoredWithApplication:` also checks the path (1001,0) and the name (2,0xC). These hide the whole app from the list (they are not used by the fetchers) [I].
* `isDirectoryExcludedButChildrenNot:` @0x13fc8 is used only for receipt BOM paths. It drops shared parent directories such as `/Library/Application Support` while their children stay eligible [I].
* The KB content (ignored paths, system items, protected IDs, additional files) is **not shipped as a readable file**. It is downloaded and encrypted (`KnowledgeBaseCipherCompatibility`) [?]. A reimplementation needs its own list. Recommended: a whole-directory deny-list for shared roots (`~/Library/{Application Support,Caches,Preferences,Logs,Containers,…}` themselves, `com.apple.*`, `Apple`, `/Library/{Apple,Audio,…}`), plus `com.apple.` bundle protection.
* There is no "shared by multiple apps" logic in the fetchers. The result set is per app. The only cross-app guards are the version exclusion (§1), the KB, and `CMPackage isApple` (`com.apple.` prefix) on receipts @SOU 0xe67c. [O/I]

### 3.2 KB additional files (`additionalFilesForApplicationName:bundleId:` @AMD 0x15598 → FUN_00014970/00014c64)
* KB `AppResource{path, value, isRegex, groupType}` is converted to `CMUninstallerAdditionalKBFile{type,url,name}` (@US 0x4f24).
* The path gets `~` expanded. groupType 21 is `userTempPath/<value>`.
* **Non-regex:** the path must exist (groupType 13 is exempt).
* **Regex:** NSRegularExpression `value` is matched against these candidates:
  * groupType 6 → localPreferences
  * groupType 12 → userPreferences
  * groupType 22 → systemReceipts
  * otherwise → contents of the parent directory of `path`
  For candidates outside those three lists, existence is re-checked.
* groupType → resource type table @AMD 0x20050 [O]: `0:0x4000 1:0x20 2:0x4000 3:0x200 4:0x200 5:0x10 6:0x1 7:0x20 8:0x2 9:0x200 10:0x200 11:0x10 12:0x1 13:0x800 14:0x10000 15:0x10000 16:0x4000 17:0x4000 18:0x8 19:0x8 20:0x10 21:0x80000 22:0x800 23–25:0x8 26:0x20000`.

## 4. Types, groups, size, selection

Group = the first mask in this order that `type & mask` hits (AM FUN_00038ba8, masks @AM 0xc9d98). Mask → label key via FUN_00032ff8 + en Localizable.strings. [O]

| Order | Mask | Group (UI) | Types (who produces them) |
|---|---|---|---|
| 1 | 0x182422 | **Supporting Files** | 0x2 Caches/Temp · 0x20 App Support / extra container Library files · 0x400 Saved State · 0x2000 Help · 0x80000 KB temp · 0x100000 Cookies |
| 2 | 0x48 | **Logs** | 0x8 Logs · 0x40 Crash reports |
| 3 | 0x8300 | **Login Items** | 0x100 login item · 0x200 launch agent/daemon · 0x8000 SMLoginItem helper |
| 4 | 0x10080 | **Plugins** | 0x80 plugins / PDF Services · 0x10000 kexts |
| 5 | 0x10 | **User Data** | 0x10 `~/Library/*` and `/Library/*` top-level hits, container Data and Documents items |
| 6 | 0x1 | **Preferences** | 0x1 |
| 7 | 0x4 | **Binaries** | 0x4 the app bundle, `.app` items, /usr/bin and /usr/local/bin |
| 8 | 0x200000 | **Applications** | no producer seen in the fetchers [?] |
| 9 | 0x1000 | **Dock Icon** | 0x1000 |
| 10 | 0x40800 | **Installers** | 0x800 receipt · 0x40000 downloaded dmg |
| 11 | 0x20000 | **Container** | 0x20000 whole sandbox container |
| — | else | **Other** | 0x4000 |

The localized strings for "Crashes" and "Help" exist, but no mask maps to them in 5.7.1. [O]

* **Size** (`ResourceSizeProvider.size(forType:resourceValue:)` @US 0x27388) [O]:
  * types 0x100, 0x800, 0x1000 and 0x8000 → 0
  * every other type → `FileSizingService.byteSizeAtPath:` (with a cancellation flag), which is a recursive directory size
  * whether that is logical or allocated size is [?]
  * the size is computed eagerly at resource creation, and a cancelled resource is dropped
  * the bundle is sized the same way as any other path
* **App bundle** = type 4 resource, value = bundle path (§0). Its UI selectability (AM FUN_00039b54) = `removable && !isFromAppStore`, plus another check through a protocol method [I: the MAS build cannot delete App Store apps itself and delegates that].
* **Default selection:** every resource is `removable = YES` except the bundle rule in §0. The UI treats `isRemovable` as "selectable/checked". For items inside the root container, a child count decides (FUN_00034820, FUN_00039b54) [I]. No per-group default-off rule was observed [?].

## 5. Launch agents/daemons and login items

**CMLaunchDemonsFetcher** @0xe1bc [O]:
* (a) For each `L` ∈ {~/Library, /Library}, it adds finder requests on `L/LaunchDaemons` and `L/LaunchAgents` with **name = bundleID, matchByWords = YES**, plus one request per `SMPrivilegedExecutables` key on `L/LaunchDaemons` (also word mode).
  * Because word mode splits the request on `._ ` but the file name only on spaces, a dotted plist such as `com.foo.app.plist` does **not** match through this path.
  * Effectively this only matches single-component IDs [I] (likely a bug). A reimplementation that wants the intended behaviour should use a bundleID-prefix or substring match.
* (b) `fetchLaunchAgentsFrom:` @0xe81c is the effective path. It reads every `*.plist` (lowercase suffix) in `L/LaunchAgents` and `L/LaunchDaemons` and keeps those whose `AssociatedBundleIdentifiers` (string, or array of strings) **equals** bundleID exactly (@0xee10).
* `Program`/`ProgramArguments` paths and `Label` prefixes are **not** consulted. [O]
* `/Library/PrivilegedHelperTools/*` is not searched here. It comes only through receipts or the KB. [O by absence]
* All hits → 0x200 (Login Items).

**CMLoginItemsFetcher** @0xfabc [O]:
* If the app path is in the LSSharedFileList session login items (`validLoginItemsList`/`fullLoginItemsList` @AS 0x4e9c/0x4ff4, only entries that exist), it emits `{value: app path, type 0x100}`.
* Otherwise it looks for the first bundle with an infoDictionary under `<app>/Contents/Library/LoginItems/` (`loginItemInfoPlistForAppURL:helperAppURL:` @AS 0x4c74). If that helper has a CFBundleIdentifier and the app `isInSMLoginItems` (computed in `isInLoginItems` @AS 0x3994 via `SMCopyAllJobDictionaries(kSMDomainUserLaunchd)` containing the helper ID), it emits `{value: helper path, type 0x8000}`.
* Both are size 0. Both are skipped if KB-ignored.

## 6. Receipts

**CMReceiptFetcher** @0x13780 (needs both name and bundleID) [O]:
* `CMPackageManager findPackagesByBundleID:lowercase(bid)` @SOU 0xfa4c looks up `pkgIDToPkg[bid]` and `pkgIDToPkg[bid + ".pkg"]`. The map is built from `/usr/sbin/pkgutil` output (allPackages @SOU 0xfb5c; [I] `--pkgs`) with lowercased keys. The package ID must equal the bundle ID, or the bundle ID + `.pkg`, exactly and case-insensitively. Vendor-wide or team-ID matching is not done.
* `_findReceiptResourcesForPackage:` @0x13a10:
  1. Skip the package if KB-ignored.
  2. `dependencies` = `pkgutil --lsbom <pkgid>` (CMDBPackage @SOU 0xe02c).
  3. Base dir comes from `/var/db/receipts/<pkgid>.plist` (`packageBaseDirFromPlist:`, [I] InstallPrefixPath), defaulting to `/`.
  4. `processReceiptsOutput:filtered:` @SOU 0xea1c drops `.` and `./Applications`. It collapses entries to their top-level bundle using the regex `.(.*?/.+?\..+?)/` when the extension is in {prefpane, app, plugin, framework}, or when it is a file package, and joins the result with the base dir.
  5. For each path: strip newlines, standardize the path, apply the KB ignore and `isDirectoryExcludedButChildrenNot`, require the path to exist, then type = `resourceTypeByPath` (§2.2).
  6. Plus one **receipt pseudo-resource** `{value: pkg bundleID/pkgid, type 0x800}` (Installers, size 0). The remover presumably forgets the receipt (`pkgutil --forget`) [I].
* The KB can name additional pkg IDs (type 0x800 → `isInstalledPackageWithID`). Those are expanded the same way (@0x14194).

## 7. Other helpers

* `ApplicationContainerAccessProbe.probe()` @US 0x277dc / `probe(sandboxContainerDataPath:)` @0x27990: for the Apple containers com.apple.{Photos, mail, Safari, MobileSMS, Notes, iCal, Music, AppStore}, it tests whether `…/Data/{Library/Logs, Library/Caches, Library/Preferences, Library/Application Support}` and `…/Data/Library` exist and are readable (FUN_00027bb4). This detects whether the app has the permission to read other apps' containers (macOS App Data / FDA) [I]. It does not take part in matching.
* `ApplicationSupportDirectoryProvider.applicationSupportDirectory(withAppName:)` @0x3965c returns `<urlProvider base>/Library/Application Support[/name]` for the audio-plugin loader [I].

## 8. Reimplementation checklist

1. Identity: bundleID = CFBundleIdentifier; name = CFBundleName, else the bundle basename.
2. Scan depth 1 under each root, without following symlinks, including hidden files.
3. For each entry, apply the version exclusion (prefix + `\s*\d+`), then:
   * bundleID substring, case-insensitive (only when bundleID ≠ name)
   * name whole-word subset (app split on `._ `, file split on spaces, extension stripped for files)
4. Preferences use the `.`-component subset rule for the bundle ID and the `._ `-word subset rule for the name.
5. Exact paths: Saved State, Cookies, Help, the container `<bid>` (per-subfolder typing), crash reports `name_*.crash|diag|hang|spin` (consider adding `.ips`, which CMM misses).
6. Launch plists: `AssociatedBundleIdentifiers == bid` (consider also `bid`-prefixed Label, and Program inside the bundle).
7. pkg receipts: `pkgid == bid | bid.pkg` → lsbom → collapse to top-level bundles → exclude shared directories.
8. Apply a deny-list (KB substitute) to every candidate. Size everything except login-item, receipt and dock pseudo-items. Group by the mask table in §4.
