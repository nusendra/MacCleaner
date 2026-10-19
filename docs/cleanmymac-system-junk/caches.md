# CleanMyMac 5 (MAS 5.7.1): System Junk "Caches" scanning spec

This spec comes from static analysis only. Addresses are function entry points. Unless noted, they are in **SystemJunkScanning** (SJS). Other binaries: **SOU** = SharedObjcUtils (arm64 slice), **LSC** = LegacyScanningCore, **JCM** = JunkCleanupModule, **KBS** = KnowledgeBaseService, **CC** = CleaningCore.
Evidence tags: **[O]** observed in code · **[I]** inferred · **[?]** unknown.

---

## 0. Task tree

```
UserCachesCompound   (CMUserCachesCompoundTask = Swift UserCachesCompoundTask, FUN_00042e20 @0x42e20)  id CMSystemJunkScanIdentifierUserCachesCompound
 ├─ tasks (plain, grouped by URL):  CMUserCachesScanTask, CMDarwinUserCachesScanTask, CMSandboxContainersCachesScanTask
 ├─ customTasks (return CMCacheGroupModel[]):  CMElectronAppsCacheScanTask, CMHardcodedPathCacheScanTask
 └─ groupedTasks {groupId: task}:
        "com.getdropbox.dropbox" → CMDropboxCacheScanTask
        "com.spotify.client"     → CMSpotifyCacheScanTask (Swift SpotifyCacheScanTask)
        "com.apple.appstore"     → CMAppStoreDownloadsCacheScanTask
        "Gradle"                 → CMGradleCacheScanTask
SystemCachesCompound (CMSystemCachesCompoundTask init @0x8a50)  id CMSystemJunkScanIdentifierSystemCachesCompound
 └─ tasks: CMSystemCachesScanTask, CMCoreSymbolicationdCacheScanTask
```
[O] FUN_00042e20: the dictionary keys are Swift literals at 0x5a160, 0x5a180 and 0x5a1a0, plus the inline small string "Gradle". [O] 0x8a50 builds a 2-element array, and the compound identifier is the CFString at 0x6f988.
[O] JCM maps UI categories `Tagged.userCaches` to `CMSystemJunkScanIdentifierUserCachesCompound` (FUN_0002a7c8) and `Tagged.systemCaches` to `...SystemCachesCompound` (FUN_0002a7f8).
[O] Swift factory: `SystemJunkScanTasksFactory.userCache(knowledgeBase:privilegedOperationsPerformer:)` @0x3a478 and `.systemCache(...)` @0x3a3a0 wrap these in `LegacyScanTaskWrapper<[CacheModel]>`.

## 1. Locations scanned

All CMPaths getters are in SOU and are lazily cached. "Sandboxed" means the env var `APP_SANDBOX_CONTAINER_ID` is present (CMPaths.isSandboxed @SOU 0x12ef4) [O]. The MAS build is sandboxed, so the sandboxed branches apply.

| # | Task (identifier) | Base path template | How it is resolved | Item granularity | Group id | Auto-selected |
|---|---|---|---|---|---|---|
| 1 | CMUserCachesScanTask (`...UserCache`) @0x9c4c | `~/Library/Caches` | CMPaths.userCaches @SOU 0x11e5c. Sandboxed: `userHome + "Library/Caches"`, where userHome = `getpwuid(getuid())->pw_dir` (@SOU 0x10ebc, the real home, not the container). Otherwise `NSSearchPathForDirectoriesInDomains(NSCachesDirectory=13, NSUserDomainMask=1)[0]` [O] | Each **immediate child** of the dir is one item, sized recursively. Deep-search children are the exception (see §3) [O] | the child's lastPathComponent, normally a bundle ID [O] | YES [O] |
| 2 | CMDarwinUserCachesScanTask (`...DarwinUserCache`) @0x9898 | `$DARWIN_USER_CACHE_DIR` (`/var/folders/xx/yyyy/C/`) | CMPaths.darwinUserCaches @SOU 0x120a8: `confstr(0x10002 = _CS_DARWIN_USER_CACHE_DIR, buf, 1024)`. If sandboxed, it deletes `"<mainBundle.bundleIdentifier>/"` from the string so the path points at the user's real `C/` dir, not the app's own subdir [O] | immediate children [O] | lastPathComponent [O] | YES [O] |
| 3 | CMSandboxContainersCachesScanTask (`...SandboxContainersCache`) @0x9958 | `~/Library/Containers/*/Data/Library/Caches/*` | CMPaths.sandboxContainer @SOU 0x12564 = `userHome + "Library/Containers"`. contentOfCachesDirectoryURL @0x9a0c lists the containers, appends `Data/Library/Caches` to each, and concatenates their contents. A missing dir is skipped silently [O] | each entry inside a container's Caches dir [O] | the **container dir name** (the path component right after `~/Library/Containers`), from `_groupIdentifierFromURL:` @0x85b0 [O] | YES [O] |
| 4 | CMElectronAppsCacheScanTask (`...ElectronAppsCache`) @0xab04 | `~/Library/Application Support/<AppName>/Cache`. For a sandboxed app: `<app.sandboxContainerPath>/Library/Application Support/<AppName>/Cache` | `_electronCacheURLForApplication:` @0xb264. Apps come from `CMSystemInfo.userApplications` [O] | the whole `Cache` folder is one item [O] | app.bundleID [O] | YES (group and file) [O] |
| 5 | CMHardcodedPathCacheScanTask (`...HardcodedPathCache`) @0xb834 | 10 fixed sources (§5.5) | `~` is expanded with `cmm_stringByExpandingTildeInPath` [O] | whole folder (CMFolderModel), except Photos, which gives individual files [O] | per source [O] | NO, except Photos = YES [O] |
| 6 | CMDropboxCacheScanTask (`...DropboxCache`) @0x9f2c | `<DropboxAccountFolder>/.dropbox.cache` | §5.2 | entries traversed under `.dropbox.cache` [O] | `com.getdropbox.dropbox` [O] | YES [O] |
| 7 | CMSpotifyCacheScanTask (`...SpotifyCache`) | the Spotify storage location | §5.3 | storage → subfolder → files [O/I] | `com.spotify.client` [O] | **NO** [O] |
| 8 | CMAppStoreDownloadsCacheScanTask (`...AppStoreDownloadsCache`) @0x8f4c | each path in `$DARWIN_USER_CACHE_DIR/com.apple.appstore/manifest.plist["purgeables"]` | §5.4 | each listed path is one file item [O] | `com.apple.appstore` [O] | YES [O] |
| 9 | CMGradleCacheScanTask (`...GradleCache`) @0xb5e0 | `~/.gradle/caches` | CMPaths.gradleCaches @SOU 0x122d8 = `userHome + ".gradle/caches"` [O] | immediate children (CMCacheScanTask logic) [O] | `Gradle` [O] | **NO**: `isResultAutoselectable` returns 0 @0xb6a0 [O] |
| 10 | CMSystemCachesScanTask (`...SystemCache`) @0x8cdc | `/Library/Caches` | CMPaths.allUsersCaches @SOU 0x11f88. Sandboxed: literal `"/Library/Caches"`. Otherwise `NSSearchPath(13, NSLocalDomainMask=2)[0]` [O] | immediate children [O] | lastPathComponent [O] | YES [O] |
| 11 | CMCoreSymbolicationdCacheScanTask (`...CoreSymbolicationdCache`) @0x8b90 | `/System/Library/Caches/com.apple.coresymbolicationd` | CMPaths.coresymbolicationdCaches @SOU 0x12328 (literal) [O] | **the directory itself** is the single item. contentOfCachesDirectoryURL @0x8c50 returns `[cachesDirectoryURL]` [O] | `com.apple.coresymbolicationd` [O] | YES [O] |

The scan does **not** cover `$TMPDIR` / `_CS_DARWIN_USER_TEMP_DIR`. CMPaths.userTempPath exists (`NSTemporaryDirectory()` standardized, @SOU 0x12340), but no cache task references it [O by xref absence].
Scope is per user: only the current user's home is scanned. There is no iteration over other users' homes. `/Library/Caches` and `/System/...` are global [O].

## 2. Grouping and item model

- **Context** CMCachesContext @0x80b0. It holds `groups: NSMutableArray<CMCacheGroupModel>` and `sandboxContainerPath = CMPaths.sandboxContainer.path` [O].
- `CMCachesCompoundTask.scan` @0x744c runs three steps in order: `_scanPlainTasksInContext:` → `_scanGroupedTasksInContext:` → `_addCustomItemsInContext:`. It returns `context.cacheGroups` (a copy) [O].
  - **Plain tasks** @0x7730: every item → `addItem:` @0x8208. The group id comes from `_groupIdentifierFromURL:` @0x85b0. If the path starts with `~/Library/Containers`, the id is the container name. Otherwise it is `lastPathComponent` of the item URL [O].
  - **Grouped tasks** @0x79b4: every item with `size != 0` goes to the group named by the dictionary key [O].
  - **Custom tasks** @0x7ba8: each returned CMCacheGroupModel is unpacked. Each `CMFileModel` child is added to the context group with the same identifier, so Electron and user-cache items for the same bundle ID merge into one group [O].
- `addItem:toGroupWithIdentifier:` @0x8288 does three things [O]:
  1. If `knowledgeBase.isIgnoreItem(groupIdentifier)` is true, it drops the item. This is a whole-group ignore by bundle ID or folder name.
  2. It fetches or creates the group. `_fetchOrCreateCacheGroupWithIdentifier:` @0x86f8 creates `CMCacheGroupModel(identifier, isAutoselected: NO)`. The group's flag is NO; selection is carried by the children [I].
  3. If the item is a `CMFileURLSequenceModel` (a deep-search result) whose children are all `CMFileModel`, it adds the **children** directly (flattened). Otherwise it adds the item itself.
- Group identifier = bundle ID or folder name. There is **no bundle-ID→app-name lookup in the scanner**. Swift `CacheModel` has fields `name`, `source`, `files`. `CacheFileModel` has `url`, `size`, `isAutoselected`, `isContainer`, `children` (init @0x25c44, converter FUN_00025778) [O]. The display name is resolved later, in the UI or KB (`KnowledgeBaseScannerService.applicationName(for:)` exists in KBS) [I/?].
- CMCacheGroupModel @0x8920 is a CMTreeEntity whose `value` is the identifier. `items` is its children [O].

### CMCacheScanTask base algorithm (used by tasks 1, 2, 3, 9, 10, 11): `scan` @0x672c, per-item block FUN_000069fc
```
filter = OR( CMFileNamePredicate(".DS_Store"),  CMFileIgnorePredicate(kb) )
for url in contentOfCachesDirectoryURL():         # FileManagerService contentsOfDirectoryAt(..., options:0)
    if filter.shouldIgnore(url): skip
    if kb.shouldPerformDeepSearchForItem(url.lastPathComponent):
        item = deepSearch(url)                    # @0x6c2c: one level of children, each filtered and sized
                                                  #   → CMFileURLSequenceModel(autoselected) or nil if empty
    else:
        size = fileSizer.byteSize(url)            # @0x6f34. If 0 and !isReadable && helper authorized
                                                  #   → privilegedOperationsPerformer.fileSizeAtURL
        if size == 0 and !privileged.isAuthorized: skip    # empty or unreadable items dropped
        item = CMFileModel(url, size, autoselected = isResultAutoselectable)   # base returns YES @0x7130
```
[O] all steps.

## 3. Exclusion and safety rules

| Rule | Where | Evidence |
|---|---|---|
| Skip `.DS_Store` by name | CMFileNamePredicate.dsStoreFileNamePredicate @LSC 0x1b44 (`isEqualToString` on lastPathComponent @LSC 0x1a0c) | [O] |
| Skip KB-ignored items | CMFileIgnorePredicate.shouldIgnoreObject @LSC 0x1550. NSString/NSURL inputs → `kb.isIgnoreItem:` on both the path and its lastPathComponent. FTS entries → on `name` and `path` | [O] (exact argument order [I]) |
| Skip a whole group by id | CMCachesContext.addItem:toGroupWithIdentifier: @0x8288 | [O] |
| Electron, hardcoded and Spotify paths are also checked with `kb.isIgnoreItem(path)` | @0xae18, @0xbb54/@0xbf0c, Spotify scan FUN_00041984 | [O] |
| **KB `isIgnoreItem`** = `isPathIgnored(scannerGroup, item)` OR `isCustomItemIgnored(item, categoryTypes:[1,1000], valueType:nil)` | JCM CachesKnowledgeBaseWrapper.isIgnoreItem: @JCM 0x3a248 → FUN_0003aba8. Witness offsets +0x10 and +0x38 map to KBS `KnowledgeBaseScannerService.isPathIgnored` @KBS 0x4d6c and `isCustomItemIgnored(_:categoryTypes:valueType:)` @KBS 0x4f34 | [O] mapping. The array `[1,1000]` is read from a static object near JCM 0xc0218 [I] |
| **Deep search** = `isDeepSearchNeeded(for: lastPathComponent)` | CachesKnowledgeBaseWrapper.shouldPerformDeepSearchForItem: @JCM 0x3a254 → witness +0x50 = KBS isDeepSearchNeeded @0x50d4 | [O] |
| The rule data (ignored paths, deep-search folder names, protected apps) is **data-driven** | It comes from the bundled encrypted KB `Contents/Resources/info.cmmkb` (SQLite-like tables `ScanItems`, `GroupType(PrefixPath)`, `ApplicationInfo`, `ApplicationFiles`, `UserIgnore`, `General`). The user ignore list is table `UserIgnore`. No hard-coded bundle-ID exclusion list for caches exists in SJS or JCM | [O] strings in main binary. List contents [?] (encrypted, not decoded) |
| Minimum size: drop 0-byte items unless the privileged helper is authorized | FUN_000069fc; grouped tasks require `size != 0` @0x79b4; Dropbox uses `NOT(CMFileSizePredicate(limit:0))`, so size > 0 is required (@LSC 0x1c74 compares `size > limit`) | [O] |
| Unreadable items: size them via the privileged helper if authorized, otherwise size 0, which means dropped | `_fileSizeAtURL:cancellationFlag:` @0x6f34 | [O] |
| SIP-restricted paths are skipped (hardcoded task only) | `isFileRestrictedAtPath:` @0xbb54 / @0xbf0c | [O] |
| No running-app check, no symlink check, no age check, no "in use / locked" check at scan time for caches | No NSWorkspace / NSURLIsSymbolicLinkKey / date refs in cache tasks. Those appear only in Logs / UniversalBinaries | [O] by absence. Exception: Photos uses access time (§5.5) |
| CMFileAccessPredicate (directories pass, files need `NSFileHandle fileHandleForUpdatingAtPath` ≠ nil) is **not used by caches** | Used only by the CMLogsScanTask factories (@0x10744, @0x10c78, @0x1129c). Impl @0x13328 / @0x133e0 | [O] |
| Protected apps / "aggressor" bundle IDs | KBS has `isAppProtected(withBundleId:)` and `isAggressorBundleID`, but the caches path does not call them | [O] absent in caches tasks |

## 4. Auto-selection defaults

| Source | Default |
|---|---|
| ~/Library/Caches/*, DARWIN_USER_CACHE_DIR/*, container Caches/*, /Library/Caches/*, coresymbolicationd, deep-search children | **selected** (`isResultAutoselectable` YES) [O] |
| Electron `<App>/Cache` | **selected** [O] |
| App Store purgeables | **selected** [O] |
| Dropbox `.dropbox.cache` contents | **selected** [O] |
| Photos Desktop old entries | **selected** [O] |
| Gradle caches | shown, **not selected** [O] |
| Spotify storage | shown, **not selected** [O] |
| Telegram (3 variants), WeChat, QQLive, QQMusic, Youku, Adobe Media Cache, System Migration cache | shown, **not selected** [O] |
| CMCacheGroupModel created by the context | `isAutoselected: NO`. The effective state is derived from the children [I] |

## 5. Special handlers

### 5.1 Electron @0xae18
- Iterate `CMSystemInfo.userApplications`. For each app: `isElectronApplication` (category FUN_0000aa7c) checks that `<app.path>/Contents/Frameworks/Electron Framework.framework` exists [O].
- Then `_containsCacheForApplication:` @0xb3b0 checks that the cache URL exists [O].
- Then `kb.isIgnoreItem(cacheURL.path)` must be false [O].
- Size with fileSizer → `CMCacheGroupModel(app.bundleID, YES)` with one `CMFileModel(cacheURL, size, YES)` [O].
- The cache URL uses `app.name` (`<UserLibrary or containerPath/Library>/Application Support/<name>/Cache`) @0xb264 [O]. Whether `name` is the display name or the bundle name is [?].

### 5.2 Dropbox @0x9f2c
- `CMDropbox.dropbox` @SOU 0x10688 reads `~/.dropbox/info.json`. `bundleIdentifier = "com.getdropbox.dropbox"` and `cacheFolderName = ".dropbox.cache"` (@SOU 0x105bc) [O].
- `fetchAccounts` @SOU 0x10740 parses the JSON. Each top-level value is a dict with `path`, `root_path` and `host`, which becomes a CMDropboxAccount (@SOU 0x10088). If there are no accounts, it uses `defaultAccount` = `~/Dropbox/` (@SOU 0x10358, @0xa780) [O].
- For each account, cache = `account.folder/.dropbox.cache`. Skip it if the KB ignores it. Otherwise traverse its contents (`traverseContentAtPath:handler:`). Filter each entry with OR(KB-ignore, .DS_Store, size==0). Each entry becomes a CMFolderModel or CMFileModel with size, autoselected YES, inside a `CMFileURLSequenceModel(group=cacheURL, YES)` (FUN_0000a20c, FUN_0000a4a8) [O].
- Whether traversal descends into directories after a dir has been added with its full size is [?]: the handler returns 0 in both cases.
- `knownNames = {"placeholder_cache"}` is set in init @0x9d0c, but scan does not use it [O/?].

### 5.3 Spotify (Swift, `CMSpotify.persistentStorageLocation` @0x3aa0c → FUN_0003aae0; scan FUN_00041984)
- If `~/Library/Application Support/Spotify/prefs` is missing → no location, empty result [O].
- Otherwise read prefs and search for `storage.last-location="` first, then `storage.location="`, taking the text up to the next `"`. If neither key is found, fall back to `~/Library/Application Support/Spotify/PersistentCache/Storage` [O strings @0x59f20–0x59fb0, logic [I]].
- Scan: if the location and each subfolder/file pass `kb.isIgnoreItem`, sized files are added under per-subfolder sequence models inside a root sequence model. **autoselected NO** throughout. Empty subfolders are dropped [O/I].

### 5.4 App Store downloads @0x8f4c
- `CMAppStoreDownloadsManifest.init` @0x95ac: path = `darwinUserCaches/com.apple.appstore/manifest.plist` [O].
- `purgeablePaths` @0x9780: `info["purgeables"]` as an NSArray, mapping only NSString elements (FUN_00009820) [O].
- If the manifest is missing → empty result. For each existing path → byteSize → `CMFileModel(fileURL, size, autoselected YES)` [O].
- No KB ignore check here [O].

### 5.5 Hardcoded paths (`_groups` @0xc2c4)
Every candidate URL must pass `fileExists`, `!isFileRestrictedAtPath`, and `!kb.isIgnoreItem(path)`. It is then sized and added as a CMFolderModel. Photos uses CMFileModel. (@0xbb54, @0xbf0c) [O]

| Group id | Path (template) | Logic | Default |
|---|---|---|---|
| `ru.keepcoder.Telegram` | `~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/*/account-*/postbox/media` | Enumerate the root. At enumerator `level == 2`, if the name starts with `account-`, add `<dir>/postbox/media`. Do not descend further (@0xc48c) | NO |
| `org.telegram.desktop` | `~/Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/{cache,media_cache}` | @0xc6dc, @0xc7e4 | NO |
| `com.tdesktop.Telegram` | `~/Library/Application Support/Telegram Desktop/tdata/user_data/{cache,media_cache}` | @0xc848 | NO |
| `com.tencent.xinWeChat` | `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9/<dir>/Message/MessageTemp` | Immediate subdirectories only (enumerator option 1 = skip descendants, NSURLIsDirectoryKey). Add the path if it exists (@0xc8ac) | NO |
| `com.tencent.tenvideo` | `~/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video` | @0xcb5c | NO |
| `com.tencent.QQMusicMac` | `~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic` | @0xcb74 | NO |
| `com.youku.mac` | `~/Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE` | @0xcb8c | NO |
| `Adobe Premier Pro Media Cache` | `~/Library/Application Support/Adobe/Common/Media Cache Files` | @0xcba4 | NO |
| `System Migration Cache` | `/Library/SystemMigration/History/<first entry with prefix "Migration-">/QuarantineRoot/private/var/db/dyld` | @0xcbbc. The format `"/%@/QuarantineRoot/private/var/db/dyld"` is appended to the history dir. The `%@` argument is the matched entry [I] | NO |
| `com.apple.Photos` | `~/Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0/*` | List the dir (option 4 = skip hidden). Keep the entry with the **latest lastAccessDate**. Every other entry is a file item (@0xccc0) | YES |

### 5.6 Gradle
A plain CMCacheScanTask over `~/.gradle/caches` with autoselect NO, put into group "Gradle" through groupedTasks [O].

### 5.7 coresymbolicationd
The single item is `/System/Library/Caches/com.apple.coresymbolicationd`. It is the whole directory, sized through the privileged helper when it is unreadable and the helper is authorized [O].

## 6. Removal

- No cache-specific removal task exists in JCM [O: no symbols]. JCM imports `FilesRemovalTask(value:fileRemover:urlResolver:dependenciesFetcher:throwErrorIfDependenciesUnresolved:)`, `FileRemover`, `PrivilegedFileRemover(remover:privilegedAgent:authorizeAgentBlock:)` and `ConfigDependentFileRemover` (debug builds use `DebugFileRemover`) [O syms].
- `CleaningCore.FileRemover.remove(at:)` @CC 0x9c20 calls `-[NSFileManager removeFileAndHandleLockAtPath:error:]`. This is a **permanent delete** that also clears lock flags [O].
- `MoveToTrashFileRemover` (`trashItemAtURL:`) exists in CleaningCore, but JCM does not import it [O]. So caches are **deleted, not trashed** [I].
- The privileged fallback is the helper (`PrivilegedFileRemover`) for root-owned items such as `/Library/Caches` and coresymbolicationd [I].
- Running apps are handled at **clean time**, not scan time. JCM imports `RunningApplicationsDependenciesResolver`, `ApplicationDependency(bundleID,isFulfilled)` and KBS `bundleIDsForQuitting(fileURL:)` (witness +0x60) [O syms]. That these apply to cache groups is [I].

## 7. Cache scan identifiers (CFStrings resolved from SJS __cfstring)

`CMSystemJunkScanIdentifierUserCachesCompound`, `...SystemCachesCompound`, `...Cache` (abstract base, @0x6720), `...UserCache`, `...DarwinUserCache`, `...SandboxContainersCache`, `...SystemCache`, `...CoreSymbolicationdCache`, `...ElectronAppsCache`, `...HardcodedPathCache`, `...DropboxCache`, `...SpotifyCache`, `...AppStoreDownloadsCache`, `...GradleCache`. [O]

Not part of these compounds: `...XcodeModuleCaches`, `...XcodeCoreSimulatorCaches` and `...DocumentationCache` belong to the Xcode junk tasks [O].

## 8. Reimplementation notes

- Resolve paths like this: home = `getpwuid(getuid())->pw_dir`; darwin cache = `confstr(_CS_DARWIN_USER_CACHE_DIR)`, then remove `"<own bundle id>/"` if sandboxed.
- Item = each child of a caches dir, sized recursively. Group = bundle ID (folder name or container name).
- Replace the KB with your own: an ignore list (paths and names), a group-ID ignore, and a "deep search" folder-name set that lists children individually.
- Always skip `.DS_Store` and 0-byte or unreadable entries.
- Default-select everything except Gradle, Spotify, the chat/media app caches and System Migration.
- Delete permanently. Prompt to quit the owning app at clean time.
