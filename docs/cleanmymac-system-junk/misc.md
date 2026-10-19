# CleanMyMac 5 (MAS 5.7.1) – System Junk: misc scanners spec

Source: static analysis of `SystemJunkScanning`, `JunkCleanupModule`, `TrashJunkScanning`, and the path strings in `SharedObjcUtils` (arm64 slices). Addresses are image offsets in the named binary (SJS = SystemJunkScanning, JCM = JunkCleanupModule, TJS = TrashJunkScanning).
Tags: **[O]** observed directly in the decompile/strings · **[I]** inferred · **[?]** uncertain.

Conventions shared by every scanner:
- Each scan task is ObjC (`CM*ScanTask`) and returns a `CMScanResult` tree of `CMTreeEntity`/`CMFileModel` nodes. Each node has `(value, size, autoselected)`. Every scanner sizes items with `FileSizingService.byteSize(at:cancellationFlag:)` and honours pause and cancel on every item [O].
- The "KnowledgeBase" wrappers in JCM sit on a generic ignore-list store. Each list is keyed by a category id: the call shape is `(kind, 0xd, value)`, where `kind` is 1, 2, 3 or 0x3e9 depending on the wrapper. `isIgnoreItem`/`shouldIgnoreURL` = (user ignore list for the path/string) OR (static shipped ignore list, `DAT_000c0208`) [O for structure, JCM 0x3a758/0x3a87c/0x3af9c; I for the semantics of individual category ids].
- Items that the KB ignores are dropped silently. A reimplementation should expose a user ignore list per category.

---

## A. Language files (`applicationLanguages`)

**Entry point:** `CMApplicationLanguagesScanTask::scan` (SJS 0x2154). The source list is `CMApplicationsServiceProvider.shared.userApplications` (FUN_00002300) [O].

**App filter** `_shouldScanApplication:` (SJS 0x2474) [O]. All of these must hold:
1. `!fileManager.isFileProtectedByRootlessAtPath(app.path)`. This is the SIP check: Apple system apps under `/System/Applications` are skipped.
2. `!app.isRestricted`. Exact meaning unknown [?]; probably apps whose bundle is not writable or is restricted by policy.
3. `!KB.isBundleIdIgnored(bundleID)` and `!KB.isPathIgnored(path)`. JCM 0x39d98/0x39d90 checks the user path list, then the category-0x3e9 list [O].
- There is no explicit "Apple-signed" or "App Store" exclusion in this task [O]. Code-signature safety is handled per lproj (see below).

**Finding languages:** `CMLanguagesUtilities::languagesForApplicationAtPath:progress:` (SJS 0x36bc) [O]:
- If the bundle extension is `wdgt`, scan the bundle root directly as a "Resources" dir.
- Otherwise walk the whole bundle with `fts_open(FTS_NOCHDIR|FTS_NOSTAT|FTS_PHYSICAL)`:
  - A directory named `*.lproj` that is not inside a scanned Resources dir is skipped (`FTS_SKIP`).
  - A directory whose lowercased name is `resources` triggers `scanResourcesForLanguages:` on it. This covers the main bundle and also nested frameworks, plugins and helper apps.
- `scanResourcesForLanguages:` (0x39d8) lists the **immediate** children of Resources (`CMFTSConfiguration skippingSymlinks:1 recursive:0`) and handles each `*.lproj` directory:
  - Language code = `shortLanguageNameFromDirectoryTwoLetters` (0x3ee4). It takes the name before `.lproj` and passes it through `CFLocaleCreateCanonicalLanguageIdentifierFromString`, so `English` becomes `en` and `German` becomes `de`.
  - Fixups: `ua`→`uk`, `jp`→`ja`. If canonicalisation fails, the raw name is used.
  - Languages for which `KB.isLanguageIgnored` is true (the **kept** languages) are not collected, but they are counted.
  - **Safety rule [I, from the counter logic at 0x3b48]:** if every lproj in this Resources folder is a removable language (lprojCount == distinctRemovable.count > 0), the folder's results are discarded. In other words, a Resources dir is only trimmed if at least one kept language remains in it.
- Result: `{langCode: [lprojPath…]}` merged across all Resources dirs.

**Which languages are kept** (`isLanguageIgnored:`, JCM 0x3a09c → FUN_00039e94) [O]:
1. **Always protected** (FUN_000806c8, case-insensitive): `en`, anything starting with `en-`, `english`, `base`, `default`, `empty`, `.`. So `Base.lproj` and all English variants are never removed.
2. **User's preferred languages:** `LanguagePreferences(userDefaults: .standard)` lazily reads `AppleLanguages` from NSUserDefaults (FUN_00080540, key literal `AppleLanguages`). It builds a dict `isoCode → LanguageRecord{isoCode, name, shouldBeKept=true, mainLanguage, isProtected}` (FUN_0007fbf0). The lookup key is the language prefix before `-` [I]. If the record exists and `shouldBeKept` is set, the language is kept.
3. A user ignore list of languages (category 2) [O].
- Per app: `isLanguageIgnored:forApplication:` (0x3a0fc) checks the key `"<lang>/<appName>"` in category 3 [O].

**Per-file filter** in `_applicationLanguagesForApplication:` (0x272c) [O]. An lproj path is a candidate only if all of these hold:
- `!app.isCodesignedLprojFileWithPath(lproj)`. The implementation is in ApplicationsService and is not in the inputs [I]. It is backed by `CMCodeResourcesInfo` (SJS 0x15070/0x15174), which loads `<bundle>/Contents/_CodeSignature/CodeResources` (bundle = path minus 2 components) and collects every key of `files` and `files2` whose entry is **not** `optional=true`. A non-optional sealed lproj is never deleted, because deleting it would break the signature. Localized resources are normally sealed with `optional`, so they stay deletable.
- `!hasNonStringsFilesAt(lproj)` (0x2628): the lproj is removed **only if every entry (recursive enumerator) ends in `.strings` or `.stringsdict`**. Any nib, storyboard, image, sub-bundle or directory entry makes the lproj kept.
- Size is greater than 0 (sized via the file sizer).

**Models and grouping** [O]:
- During the scan: `CMLocalizedApplicationModel(app, autoselected:0)` → `CMLocalizationLanguageModel(lang, 0)` → `CMFileModel(lprojURL, size, autoselected:1)`. Apps with no languages are dropped.
- `_groupedLanguageItemsFromApplicationItems:` (0x2ca8) inverts this to **language → app → files**: `CMApplicationLanguageModel(lang, autoselected:1)` → `CMLocalizedApplicationFilesModel(app, 1)` → files. The UI groups by language.
- **Default selection:** all files are autoselected [O].

**Removal:** a plain file delete of the `.lproj` directories through the generic remover (no special remover type exists in JCM) [I].

---

## B. Universal binaries (`universalBinaries`)

**Entry point:** `CMUniversalBinariesScanTask::scan` (SJS 0x156d8). Apps come from `CMSystemInfo.userApplications` [O].

**App filter** `_shouldScanApplication:` (0x15afc) [O]:
- Not SIP-protected and not `isRestricted`.
- `!KB.shouldIgnoreApplication(app)` (JCM 0x3af18 → 0x3ad04): the path is in a user list or the category-0x3e9 list, or the bundleID is in a user list or the static list.

**Per app** `_universalBinariesForApplication:` (0x15c84) [O]:
1. Skip if the app bundle has `NSFileImmutable` (locked).
2. On arm64 (`CMLipo.targetCpuArm64` is hard-coded to 1 in this build) or under Rosetta (`sysctl.proc_translated`), skip CleanMyMac itself (bundle ID compared case-insensitively with `NSBundle.mainBundle`).
3. Skip apps set to **"Open using Rosetta"**. `CMApplicationLaunchServices` (0x43ae0/0x43c5c) reads `~/Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist` keys `Architectures for arm64` and `Architectures for x86_64`. If the bundle ID is listed under either key (case-insensitive), the app is skipped.
4. `compatibleArchitecture = CMLipo.compatibleArchitectureForBinaryAtPath(app.binaryPath)` (0x46108/0x46e8c):
   - For a fat main binary: on arm64 or Rosetta take the first slice named `arm64`, otherwise `x86_64`.
   - For a thin binary: use its own architecture.
   - If nothing is found, skip the app.
   - `CMArchitecture` only recognises `arm64` (cputype 0x100000c, subtype&0xffffff==0) and `x86_64` (0x1000007, subtype 3). The `arm64e`, `x86_64h`, `i386` and `ppc` slices map to nil (0x473f0).
5. Enumerate the bundle recursively (keys isSymlink, isDirectory, isExecutable):
   - Skip descending into `*.lproj`.
   - Consider only files **without an extension** that have the executable bit, are not symlinks or directories, and whose name is not in `knownNotExecutables = [.DS_Store, PkgInfo, CodeResources]` (NSConstantArray at 0x71e00).
   - Every file named `CodeResources` creates a `CMCodeResourcesInfo`.
6. **Signature safety:** an executable is dropped if it lies under the bundlePath of any CodeResources and appears in that CodeResources' non-optional `files`/`files2` set. Sealed nested binaries (whose hash is in an outer seal) are never thinned. Main and nested Mach-O binaries signed with an embedded signature are not listed in CodeResources, so they remain eligible. Each Mach-O slice carries its own signature, so removing other slices keeps the remaining slice valid [I].
7. For each candidate: `CMLipo.getUnnecessaryThinFiles(path, [compatibleArch])` (0x46314):
   - Read the fat header (`0xcafebabe` or `0xcafebabf` for fat64).
   - If the file is not fat (reader error domain `CMBinaryReader`, code 2), return an empty result when the thin arch is compatible, otherwise an error.
   - If no slice matches the compatible arch (cputype equal and subtype&0xffffff equal), the result is an error and **the whole app is abandoned**.
   - Otherwise return the slices that do not match. If there are any, add `CMUniversalBinaryModel(fileURL, sum(slice.size), autoselected:1, compatibleArchitecture)`.
8. The app node `CMApplicationUniversalBinariesModel` is created with `autoSelected` (ivar initialised to **0**), so the app/category level is not preselected while the children are [O]. The effective default is not selected [I].

**Removal:** `UniversalBinaryThinner.thinBinary` (SJS 0x394a8) [O]:
- Calls `CMLipo.removeUnnecessaryThinFilesFromBinaryAtPath:compatibleArchitecture:` (0x467b8). This keeps **only the first slice whose arch name equals the compatible arch** and rewrites the binary as a **fat file with one slice** (the fat header and fat64 flag are preserved).
- `CMBinaryWriter.rewriteFatBinaryFile` (0x45014) works as follows:
  1. `stat` the original.
  2. `unlink` and then create `"<path>.lipo"` with `O_CREAT|O_EXCL|O_WRONLY`, and `fchmod` it to the original mode.
  3. Sort the slices by alignment and write the fat header, the fat_arch entries and the aligned slice data.
  4. `removeItemAtPath(original)` then `moveItem(tmp→original)` (0x45f40).
- No codesign or re-sign step exists in the binary (there is no `codesign` string) [O].
- If the in-app attempt fails, it retries through the privileged helper (`PrivilegedOperationsPerformerService`, client type `Lipo`). Logged messages: "Couldn't remove thin by app/helper tool for file:" [O].
- The original file owner and xattrs are not explicitly preserved [I].

---

## C. Broken preferences (`brokenPreferences`)

**Entry point:** `CMBrokenPreferencesScanTask::scan` (SJS 0x4244).
- **Location:** `CMPaths.userPreferences`, i.e. `~/Library/Preferences`. It is listed non-recursively, skipping hidden files (options 5) [O]. There is no scan of `/Library/Preferences` or of ByHost subfolders, because subdirectories are not descended [O].

**Per URL** [O]:
- Skip if `KB.shouldIgnoreURL`.
- `_isPreferenceFileBrokenWithPlistPath:` (0x4840) returns broken only if **all** of these hold:
  - The file exists, its name does not start with `.`, and its extension (lowercased) is `plist`.
  - The path does not contain `.lockfile`.
  - The size is greater than 0. Empty plists are **not** broken.
  - It is not `NSFileImmutable`. Immutable files log "Failed to read pref file" and are not broken.
  - A `CFReadStream` opens on it.
  - Then `CFPropertyListCreateWithStream(..., kCFPropertyListMutableContainersAndLeaves)` returns NULL (a parse failure), **or** `CFPropertyListIsValid(plist, format)` is false.
- A stream that fails to open counts as not broken.

**Model:** `CMBrokenPreferencesModel(name = filename up to the last '.', url, size, autoselected:1)` (0x46d4) [O]. The default is **selected**.

**Removal:** `BrokenPreferencesRemover.removePreferences` (SJS 0x37c74) [O]:
1. If the path exists and its extension is not `lockfile`, run `/usr/bin/defaults delete <path>` through the task runner and log OK or Error. When the item is not a directory, a path-component transform is applied to the argument first [?] (the decompile shows `stringByDeletingLastPathComponent`; this is likely the path with the extension removed).
2. `prefsdManager.setNeedsRelaunch(true)`. `CMCFPrefsdManager` relaunches `cfprefsd` afterwards so the cache drops the domain [I].
3. Delete the file with `fileRemover.remove(url)`.

---

## D. Broken startup items (`brokenStartupItems`)

**Entry point:** `CMBrokenStartupItemsScanTask scanTaskWithKnowledgeBase:privilegedOperationsPerformer:` (SJS 0x621c). This is a compound task (`CMSystemJunkScanIdentifierBrokenStartupItems`) made of a login-items task and a launchd-agents task [O]. `CMStartupItemModel(name, type 0 = login item / 1 = launchd, url, size, configuration, isAutoselected)` (0x6340).

**D1. Login items** (`CMBrokenLoginItemsScanTask::scan`, 0x5b20) [O]:
- Source: `CMLoginItemsManager.sharedInstance.loginItemInfos`, a list of dicts with `kCMLoginItemInfoURLKey` and `kCMLoginItemInfoNameKey`. These are the user's shared-file-list login items; the implementation is outside the inputs.
- **Broken** means one of:
  - The URL is nil and `!KB.isIgnoreItem(name)`. The size is 0.
  - The URL is non-nil, `!fileExists(url.path)` and `!KB.shouldIgnoreURL(url)`.
- Name: the info name, else `displayNameAtPath`, else the last path component without its extension.
- Autoselected = **1**.
- **Removal:** `CMLoginItemsManager.removeLoginItemAtPath:error:` (BrokenStartupItemRemover FUN_000374c0) [O].

**D2. Launchd agents/daemons** (`CMBrokenLaunchdAgentsItemsScanTask`, 0x4fbc) [O]:
- Source: `CMSystemInfo.allLaunchFiles`. The paths are defined in SharedObjcUtils: `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`. `/System/Library/Launch*` strings also exist, but SIP makes them irrelevant [I].
- For each file: it must be readable and `!KB.shouldIgnoreURL`. Load it with `NSDictionary(contentsOfFile:)`.
- `_isLaunchdAgentBrokenWithConfiguration:` (0x53dc):
  1. `exe = Program`, else `ProgramArguments[0]`.
  2. If `WorkingDirectory` is set and `exe` does not start with `/`, then `exe = WorkingDirectory/exe`.
  3. Standardise the path and expand `~`. If the result is nil (no program at all, or the plist is unparseable), it is **broken**.
  4. If the path is read-restricted somewhere up its parent chain, use the privileged helper's `fileExistsAtURL`. If the helper is **not authorized**, the item is not broken (benefit of the doubt).
  5. If the executable exists, it is not broken.
  6. Otherwise it is broken unless `_isAgentInPathOwnedByAnyApp` (0x56d8) holds: the executable's lastPathComponent equals one of the `privilegedExecutables` (SMJobBless helpers) of any scanned app. This protects helpers that get installed lazily.
- Model: type 1, name = plist file name, configuration = the dict, autoselected **1**.
- **Removal:** `removeAgentAtPath:` in-app [O]. The in-app removal is presumably `launchctl` unload plus delete [?]. If that fails, it falls back to the privileged helper (client type `BrokenStartupItems`) [O].

---

## E. Document versions (`documentVersions`)

**Spec builder** `initWithKnowledgeBase:` (SJS 0xda04) [O]: only 4 apps and 4 UTIs are covered:

| App | Bundle ID | UTI |
|---|---|---|
| Sketch | com.bohemiancoding.sketch3 | com.bohemiancoding.sketch.drawing.single |
| Pages | com.apple.iwork.pages | com.apple.iwork.pages.sffpages |
| Keynote | com.apple.iwork.keynote | com.apple.iwork.keynote.sffkey |
| Numbers | com.apple.iwork.numbers | com.apple.iwork.numbers.numbers |

**Finding documents** [O]:
- `CMMetadataSearchController.searchFilesWithTypes(spec.fileTypes, filter: CMDropboxFilter)`. This is a **Spotlight** (NSMetadataQuery) search by content type, with Dropbox paths excluded [I for the filter semantics].
- Results are grouped by UTI → bundle ID (0xe790).
- For each bundle ID, skip it if `KB.isIgnoreItem(bundleID)`. Skip each document path if `KB.isIgnoreItem(path)`.

**Finding versions** `_findVersionsForFileAtURL:` (0xeab4) [O]:
- `NSFileVersion.otherVersionsOfItemAtURL(url)` filtered to entries with a non-nil `modificationDate`. These are the generation-store copies in `/.DocumentRevisions-V100`, accessed only through the API.
- The current version is never in this list.
- Size comes from `revisionSizeWithFileSizer` (a category on NSFileVersion, outside the inputs). Versions with size 0 are dropped.

**Selection rule** `CMDocumentVersionsSelectionRule.selectionIndexesForObjects:` (0xf094) [O]:
- Sort the versions by `modificationDate` **descending**.
- Index 0 (the newest previous version) and the last index (the oldest version) are never selected.
- An intermediate version *i* is selected iff `|date[i] − date[i−1]| < 14400 s` (4 h, constant at 0x541e8). This thins bursts of autosaves and keeps one version per ~4 h gap plus both ends.

**Models** [O]:
- `CMDocumentApplication(bundleID, name, autoselected 0)` → `CMDocumentVersionFile(url, 0)` → `CMFileVersionModel(NSFileVersion, size, autoselected = rule)`.
- Empty nodes are pruned.

**Removal:** `NSFileVersion.removeAndReturnError` for each selected version (JCM FUN_00018d18, `DocumentsVersionsRemovalTask` / `FileVersionRemoverType`) [O].

---

## F. iOS / mobile backups

**Location:** `CMPaths.mobileBackupsURL` = `~/Library/Application Support/MobileSync/Backup/` (SharedObjcUtils string). Its children are listed with options 7 (no recursion, skip packages, skip hidden). Children where `KB.isIgnoreItem(lastPathComponent)` are filtered out (FUN_00013e80) [O].

**Per backup dir** (`CMMobileBackupsTask::scan`, SJS 0x13710) [O]:
- Read `Info.plist` and its `Device Name` and `Product Type` keys.
- **No Device Name** means a broken backup. It is collected unless `KB.isIgnoreItem("BrokenBackups")` or `KB.shouldIgnoreBrokenBackups` (JCM 0x3a9fc, the literal "Broken Backups").
- Otherwise build `CMMobileBackupDevice(name, productType)`:
  - `uniqueID` = `"<name> (<productType>)"` when a product type exists, else the name [I for the exact format].
  - Skip the device if `KB.isIgnoreItem(uniqueID)` or `KB.shouldIgnoreDeviceID`.
  - Group by device; equality uses `deviceFullName`.

**Per device group** (FUN_00013f04) [O]:
- Date = `Status.plist["Date"]`, falling back to `Info.plist["Last Backup Date"]`.
- Sort by `date` descending.
- Index 0 gets `latest=1, autoselected=0`. Every older backup gets `latest=0, autoselected=1`. Each is a `CMMobileBackup(url, size, …)` inside `CMMobileBackupGroup(device)`.
- Broken backups go into one device-less group with `autoselected=1, latest=0`.

**UI safety** [O]: selecting the latest backup triggers a confirmation (JCM `MobileBackupsModel.selectionConfirmation`, string id `latest-ios-backup`).

**Removal:** plain directory delete (no special remover) [I].

---

## G. Deleted users

`CMDeletedUsersScanTask::_scan` (SJS 0xd3b0) [O]:
- **Location:** `CMPaths.deletedUsersURL` = `/Users/Deleted Users`. List it non-recursively, skipping hidden files.
- Collect only entries whose extension is `dmg`, i.e. the disk images that System Settings creates when a user is deleted with "save home folder in a disk image".
- Skip entries where `KB.shouldIgnoreURL`.
- Model: `CMFileModel(url, size, autoselected:0)`, so the default is **not selected**.
- Removal: generic file delete. Root-owned files likely need the privileged helper [I].

**Related, not part of this task** [O]: `CMHardcodedPathCacheScanTask::_systemMigrationCache` (SJS 0xcbbc) finds the first `/Library/SystemMigration/History/Migration-*` directory and offers `<that>/QuarantineRoot/private/var/db/dyld` as a cache group with autoselected 0.

---

## H. Trash (TrashJunkScanning)

**H1. System / iCloud trashes** (`CMTrashesScanTask`, TJS 0x3308) [O]:
- `includeICloudTrashes` is true in the default init.
- Trash dirs:
  - `CMPaths.systemTrash` = `~/.Trash`.
  - `CMPaths.iCloudTrashes`: `~/Library/Mobile Documents/.Trash`, `~/Library/Mobile Documents/com~apple~CloudDocs/.Trash`, `~/Library/CloudStorage/iCloud Drive/.Trash`.
  - Each `~/Library/Mobile Documents/<container>/Documents/.Trash/` that exists.
- The **top-level children** of each dir are listed (options 1: no recursion; hidden entries **included**). Each child is sized through `CMURLIterator` and becomes `CMFileModel(url, size, isCloudFile = path has a prefix in the iCloud/mobile trash list, autoselected:1)` under a single `CMFileURLSequenceModel("/" , autoselected 1)`.
- In Swift, `TrashFileModel` also exposes `isApplicationFromAppStore` [O]. Its use is not analysed here.

**H2. Mounted volume trashes** (`CMMountedTrashesScanTasksFactory.tasks`, 0x2e0c / `CMMountedTrashesScanTask`, 0x28c4) [O]:
- Take `mountedVolumeURLs(skipHiddenVolumes)`. A volume is cleanable iff its path starts with `/Volumes/` (case-insensitive, anchored) **and** IsBrowsable **and** IsLocal **and** not IsReadOnly (0x2fc4). Network volumes are therefore excluded and the boot volume is excluded.
- Path: `<volume>/.Trashes/<getuid()>`. Its top-level children are listed and become `CMFileModel(autoselected:1)` under `CMFileURLSequenceModel(volumeURL)`.

**H3. Mail trash** (`CMMailTrashScanTasksFactory`, 0x258c / `CMMailTrashScanTask`, 0x1cc0) [O]:
- Mailboxes come from `CMMailInfo.sharedMailInfo.mailboxes`. Only accounts with `accountType ∈ {IMAPAccount, AosImapAccount}` (IMAP and iCloud) that have a `trashMailBoxURL` and are `isEnabled` are used. The server keeps the authoritative copy [I]. POP and local mailboxes are never touched.
- The task enumerates `mailbox.trashes` (message files; the filter accepts `emlx`/`emlxpart`, FUN_00001f94) [O/I].
- Each message becomes `CMFileURLSequenceModel(url, size, autoselected 1)`. For message `<Messages>/<id>.emlx`, the folder `<Messages>/../Attachments/<id>/` (if it exists) is enumerated, and entries at **level 2** are added as child `CMFileModel(autoselected 1)`.
- Swift model: `MailTrashModel{name, attachments:[MailTrashAttachmentModel{url,size,additionalFiles}]}`.

**Removal for H1–H3:** a generic remover deletes the items (JCM `runTrashBinCustomFlow`, 0x7260). The details are in the coordinator [I].

---

## I. Mail attachments / MailJunk (brief)

- JCM creates `MailJunkScanTasksFactory.mailAppAttachments(knowledgeBase:)`. This lives in the separate `MailJunkScanning.framework`, which is not among the inputs [O].
- `MailJunkKnowledgeBase` (JCM 0x39a28–0x39ba0) exposes three checks [O]:
  - `isMailboxIgnored(mailbox)`: uses `mailbox.uniqueID`, list kind 1.
  - `isPathIgnored(path)`
  - `isAttachmentIgnored(name)`: list kind 2.
- The scan and selection logic for attachments was not analysed [?].

---

## Reimplementation checklist (condensed)

| Category | Locations | Broken/junk predicate | Default selected | Removal |
|---|---|---|---|---|
| Languages | lproj dirs in user apps' `Resources` dirs | not a kept language, not sealed non-optional, contains only `.strings`/`.stringsdict`, and the Resources dir keeps ≥1 kept language | yes (files) | delete lproj dir |
| Universal binaries | executables in user apps | fat with a compatible slice plus extra slices; not sealed in CodeResources; app not locked, not Rosetta-forced, not self | children yes, app node no | rewrite as a single-slice fat binary via `<path>.lipo` + replace; helper fallback; no re-sign |
| Broken prefs | `~/Library/Preferences/*.plist` (top level) | non-empty, not immutable, CFPropertyList parse fails or is invalid | yes | `defaults delete`, delete file, relaunch cfprefsd |
| Login items | LoginItems list | URL nil or target missing | yes | `removeLoginItemAtPath` |
| Launchd | Launch{Agents,Daemons} | Program/ProgramArguments[0] missing (checked via helper if restricted) and not an app's privileged helper name | yes | `removeAgentAtPath`, helper fallback |
| Doc versions | Spotlight search for Pages/Numbers/Keynote/Sketch docs | `NSFileVersion.otherVersions` | the 4 h-burst rule (keep newest and oldest) | `NSFileVersion.remove` |
| iOS backups | `~/Library/Application Support/MobileSync/Backup/*` | per device; broken = no Device Name | all but the latest; broken = yes | delete dir |
| Deleted users | `/Users/Deleted Users/*.dmg` | – | no | delete |
| Trash | `~/.Trash`, iCloud trashes, `/Volumes/*/.Trashes/<uid>`, IMAP/iCloud Mail trash and attachments | – | yes | delete |
