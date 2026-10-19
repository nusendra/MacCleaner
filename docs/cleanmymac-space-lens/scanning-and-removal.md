# Space Lens: scanning, sizing, data model, deletion and module flow (CleanMyMac 5 MAS 5.7.1)

The sources are static analysis of the arm64 slices of `SpaceLensScanning` (SLS), `SpaceLensModule` (SLM), `SpaceLensUI` (SLU) and `FileManagerService` (FMS). Addresses are image offsets. Swift string literals were decoded as `ptr+0x20` for large strings and from immediates for small strings (`tools/swann.py`). Annotated C is in `lens/ann/*.s.c`.
Tags: **[O]** observed in code, **[I]** inferred, **[?]** unknown.

---

## 0. Architecture

```
SpaceLensModuleBuilder.build()                       SLM 0x24a98
 ├─ scan URL = pref spaceLensModuleCustomScanPath ?? VolumeInfoManager.fetchRootVolume().url
 ├─ ModuleScanningURLProvider(url:directoryProvider:)  (the intro footer volume/folder picker writes to it)
 ├─ sandboxAccessProviders = [homeFolderSandboxAccessProvider] (MAS)
 └─ SpaceLensModuleCoordinator : ScanningModuleCoordinator (identifier 6)
      intro → scan progress → results (bubbles + list) → review → clean progress → cleanup complete / log
SpaceLensScanTasksFactory(fullDiskAccessPermissionProvider:, fileManager:)       SLS 0xd00c
  .createScanTask(directory: URL, strategy: SpaceLensCloudScannerStrategy) -> SpaceLensScanTask  SLS 0xd060
SpaceLensScanTask (Swift class, ProcessingTask/Progressable/Controllable)
  result: SpaceLensFileSystemEntity (root of a fully materialised tree)
SpaceLensDeletionPlanner.units(for:shouldSpare:) -> [Unit]        SLS 0x5c38 (no other framework imports it; SLM has its own copy, §5)
```

---

## 1. Scan

### 1.1 Root [O/I]
- The root is any **user-chosen URL**: the whole startup volume, an external volume or a folder. Builder at SLM 0x24a98 [O]:
  - It reads `SharedPreferencesKeys.spaceLensModuleCustomScanPath` (a String path). If the path is set, it uses `URL(fileURLWithPath:)`.
  - Otherwise it uses `VolumeInfoManager(volumeURLProvider: VolumeURLProvider(fileManager:), volumeFilterType: …).fetchRootVolume().url`, which is `/` [I].
  - The result feeds `ModuleScanningURLProvider(url:directoryProvider:)`.
- The picker is ModuleCore `VolumeSelectionViewModel(urlProvider:analytics:homeURL:homeTitle:workspace:volumeInfoManager:savedPreferences:)` with `volumeOrFolderItems`, `refreshExternalDriveList()`, `customFolder`, and `VolumeSelectionViewController.panel(_:shouldEnable:)` (an NSOpenPanel delegate) [O syms].
  - Texts: "Choose folder...", "Choose a folder to scan", "Choose" (ModuleCore strings) [O].
  - The items are Home, mounted volumes and a custom folder. A custom folder is saved to the preference above [I].
- `SpaceLensModuleCoordinator.scan(volumeURL:)` (SLM 0xb3cc) accepts only `isFileURL`. It calls `urlProvider.update(with:)` and then `CommonModuleCoordinator.run(flow:forceReset:)` [O]. This is the external "scan this volume" entry point, for example from a disk menu.
- MAS sandbox: the builder appends `homeFolderSandboxAccessProvider` to `sandboxAccessProviders`. `ScanningModuleCoordinator` / `MainFlowStartConditionSandboxAccess` asks for it before the flow starts. That is a user grant of the home folder, kept as a security-scoped bookmark [I].
- FDA: `createScanTask` calls `fullDiskAccessPermissionProvider.fullDiskAccessStatus() == .authorized` → `isFDAGranted` [O].

### 1.2 Task construction (`createScanTask`, SLS 0xd060) [O]
```
volumeChecker = VolumeChecker(fileManager)                     // FUN_2e7c
filter = PathFilter(isFDAGranted, customIgnorePaths: [] (empty Set<String>),
                    checkForExternalVolumes: {path,depth in volumeChecker.isMountPoint(path,depth)},  // FUN_d440
                    remindersPath: isFDAGranted ? nil : NSHomeDirectory()+"/Library/Reminders")
cloud  = CloudStorageHelper(cloudRootPaths: [], strategy, fileManager)
task.fields: directory, filter, fileManager, cloudStorageHelper,
             volumeBackupSizeCacher = CMVolumeBackupSizeCacher.sharedInstance,
             fileSystemType = FileSystemType(NSWorkspace.getFileSystemInfoForPath(directory.path)…),  // FUN_36a0
             maxConcurrentScans = 4,
             controllable = AsyncControlObject(), progressable = CountableProgress(estimatedUnitsCount: 0),
             taskProgressable = TaskProgressSubject<ScanProgressValue>,
             progressTracker = ProgressTracker actor {totalScannedSize=0, delta=0, threshold=500_000_000}
```
`FileSystemType`: `undefined, hfs, apfs, ufs, msdos, exfat, ntfs, other(String)`. Its descriptions are "undefined"/"HFS"/"APFS"/"UFS"/"MS-DOS"/"ExFAT"/"NTFS"/"other: x" (FUN_358c) [O].

### 1.3 VolumeChecker (FUN_2e7c, lookup FUN_d440) [O]
- Input: `fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [])` + `URL("/Volumes")`.
- Excluded from the list: `/`, `/private/var/vm`, `/home`, `/net`.
- It stores `externalVolumes: [Int: Set<String>]`, keyed by `url.pathComponents.count`, and `maxDepthLevel` = the largest such count.
- `isMountPoint(path, depth)` = `depth <= maxDepthLevel && externalVolumes[depth]?.contains(path)`. The traversal passes `depth = parent.pathComponents.count + 1`.
- Effect: the scan **never crosses into another mounted volume** and skips `/Volumes` itself. `/private/var/vm` (swap) **is** counted.

### 1.4 Traversal (`SpaceLensScanTask`) [O unless noted]
Method: **recursive shallow listing** with `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:[.fileSizeKey, .totalFileAllocatedSizeKey, .fileResourceTypeKey], options: [])` (FUN_8134 @0x83c4, `options = 0`). There is no fts, no enumerator and no getattrlistbulk.
- `options = []` means **hidden files are included** and **package contents are traversed** (bundles are ordinary directories).

Start (FUN_6ce8 → 790c → 6fa0):
1. `cloudRootPaths` = [`~/Library/CloudStorage`, `~/Library/Mobile Documents`] + `~/Documents` and `~/Desktop` **if `fileManager.isUbiquitousItemAt(url)`** (iCloud Desktop & Documents). The directories come from `urls(for: .libraryDirectory/.documentDirectory/.desktopDirectory, in: .userDomainMask)`, using the static array [9, 12] at 0x19048 (FUN_1a08).
2. Log `Scan started in "<path>".` and `File system type: X`.
3. `estimatedUnitsCount += usedSpace(directory)` = `volumeTotalCapacity − volumeAvailableCapacity` of the volume that **contains** the directory (FUN_cc60). Log "Used space on volume: N".
   - Progress units are **bytes**, so a subfolder scan shows a fraction of the whole used volume [I].
4. `isCloud = isCloudCandidate(root)` (FUN_1e6c: `path == r || path.hasPrefix(r + "/")` for any cloud root). Then `scanDirectory(root, depth: root.pathComponents.count + 1, isCloud)`.

`scanDirectory(url, depth, isCloud)` (FUN_7a6c…7e5c, child FUN_8ea8…96b8):
1. `await controllable.waitIfPaused()` and `cancelIfNeeded()` (this throws CancellationError).
2. `(files, subdirs) = listDirectory(url, depth, isCloud)` (FUN_8134). For each child URL:
   - Call `cancelIfNeeded()`.
   - **Skip** the child if `filter.checkForExternalVolumes(path, depth)`.
   - **Skip** it if `customIgnorePaths.contains(path)` (always empty).
   - **Skip** it if `path.hasPrefix("/System/Volumes/Data/")` (the firmlink twin of `/`, which avoids double counting).
   - **Skip** it if `remindersPath != nil && path.hasPrefix(remindersPath)` (no FDA, so the TCC prompt is avoided).
   - **Skip** it if `path == "/.nofollow" || path.hasPrefix("/.nofollow/")`.
   - `resourceValues(forKeys: [fileSize, totalFileAllocatedSize, fileResourceType])` → `fileResourceType`:
     - `directory` → append to `subdirs`.
     - `regular` **or `symbolicLink`** → a file entity (§2). Symlinks are **not followed**. A symlink entity is the link itself [I].
     - Any other type (socket, fifo, char/block device, unknown) → skipped.
   - If `contentsOfDirectory` throws, log `Failed to scan directory at <p> with error: …`. The directory then becomes `{size 0, children []}` and the scan **continues** (FUN_756c/96b8). A CancellationError is rethrown.
3. `sum(files.size)` goes to the ProgressTracker (§1.5).
4. Subdirectories run in a `withThrowingTaskGroup` (FUN_98dc; on macOS ≥ 15 it uses the `isolation:` variant). The window is a **sliding window of 4**: 4 child tasks are seeded (FUN_9d24, loop counter 4), and each `group.next()` adds the next one (FUN_a20c). Priority is inherited. On error it calls `cancelAll()` + `awaitAllRemainingTasks()` and rethrows.
   - The limit applies **per directory level**. Recursion multiplies it, so overall concurrency is unbounded [I].
   - Each child task (FUN_8ea8):
     - If `!isCloud && isCloudCandidate(child)`, log "Entering cloud candidate root at: p", start a timer and set `isCloud = true`.
     - Then recurse with `depth + 1`. Afterwards, log "Cloud candidate root scanned in %.2fs: %@".
     - Build the directory entity (§2.2).
5. The children of a directory are `files ++ subdirEntities`. This is the listing order of files, followed by the order in which the subdirectories finished. There is **no sorting in the scanner** [O: no sort code]. The UI sorts by size [I].

Finish (FUN_70bc):
- If the root URL `isVolume && volumeIsEjectable == false`, and `CMVolumeBackupSizeCacher.backupSizeForVolumeAtURL(root) > 0`, then **append a purgeable pseudo-child** `{path: root.path, size: backupSize, isDirectory: false, isPurgeable: true, cloudStatus: notCloud}` to the root and add its size to progress (FUN_7ea0) [O].
- `CMVolumeBackupSizeCacher` (FMS 0x421c) is a per-volume cached item (`updateIfNeeded`, `lastSize`, `dateOfLastMeasurement`, `lastTimeToFetch`). It measures with **`CSDiskSpaceGetRecoveryEstimate(volumeURL)`** (CoreServices, FMS stub 0x154cc). This is the "purgeable/recoverable" estimate [O].
- Flush the progress delta (FUN_736c). Log "Scan finished. Total size: N" (FUN_7434).
- Result: the root `SpaceLensFileSystemEntity`.

Streaming: there are **no incremental results**. The tree is returned only at the end. During the scan only `ScanProgressValue` is published [O].

### 1.5 Progress [O]
- `ProgressTracker` actor (FUN_721c/7c18/736c): `add(bytes)` sets `total += b` and `delta += b`. When `delta > 500_000_000`, it calls `progress.addUnits(delta)` and resets `delta = 0`. The final flush adds the rest.
- `ScanProgressValue(scannedSize: UInt64, currentPath/activePath: String?)` with `.empty`. It is published through `TaskProgressSubject.update`, together with the units (granularity ≈ 500 MB) [I for exact call placement].
- Cancel/pause: `AsyncControlObject` provides `pause/resume/cancel/isPaused/isCancelled`. `cancelIfNeeded()` runs per entry and `waitIfPaused()` runs per directory.

### 1.6 Not done [O by absence]
- No hard-link or inode dedup, no APFS clone detection, no firmlink resolution other than the `/System/Volumes/Data/` prefix.
- No max depth. No size or count limits.
- No `skipsHiddenFiles`. No exclusion of `/System` (it is scanned; access may fail for SIP-protected paths and then size 0).

---

## 2. Sizing [O]
### 2.1 Files (FUN_8134)
```
alloc = totalFileAllocatedSize ?? 0 ;  logical = fileSize ?? 0
if !isCloud:
    if alloc != 0            -> size = alloc, cloud = notCloud
    elif fsType == msdos(4)  -> size = max(logical,0)          // FAT gives no allocated size
    else                     -> size = 0
else (inside a cloud root):
    strategy .dataless(1):   lstat(path); status = (st_flags & SF_DATALESS 0x40000000) ? cloudEvicted : cloudLocal
                             (lstat failure → cloudLocal); size = max(alloc,0)
    strategy .ubiquitousItem(0): FUN_236c: resourceValues [isUbiquitousItem, ubiquitousItemDownloadingStatus]
                             !ubiquitous → notCloud (falls back to the non-cloud rule);
                             status == .notDownloaded → cloudEvicted else cloudLocal; size = max(alloc,0)
```
- The size is the **allocated size**, not the logical size. Evicted placeholders therefore show ≈0. APFS clones and hard links are counted once **per path** [I].

### 2.2 Directories (FUN_9378 @0x9584)
- `size = Σ children.size`. The directory's own allocated size is **not** added.
- Flags: `isDirectory = true`.
- `cloudStatus`:
  - Outside a cloud root it is `notCloud`.
  - Inside one it is `cloudEvicted` if **every** child is `cloudEvicted` (an empty directory also counts), and `cloudLocal` otherwise.
- Purgeable: only the synthetic root child described in §1.4. There is no "System"/"Other" volume accounting in the scanner. The UI indicator shows used/free/purgeable/selected from `VolumeModel` (§6.4).

---

## 3. Data model [O]
```swift
enum CloudStatus: UInt8 { case notCloud=0, cloudEvicted=1, cloudLocal=2 }
enum SpaceLensCloudScannerStrategy: UInt8 { case ubiquitousItem=0, dataless=1 }
struct SpaceLensFileSystemEntity {           // stride 0x28
  let path: String          // +0x00 (absolute path; title = lastPathComponent in UI)
  let size: UInt64          // +0x10
  let isDirectory: Bool     // +0x18
  let isPurgeable: Bool     // +0x19
  let cloudStatus: CloudStatus // +0x1a
  var children: [SpaceLensFileSystemEntity] = []   // +0x20; mutating setChildren(_:)
  // computed, fully recursive (no caching):
  var leavesCount: Int          // purgeable→0; file→1; dir→Σ children (empty dir 0; a root that is a file → 1)
  var removableLeavesCount: Int // files with cloudStatus != .cloudEvicted (purgeable excluded)
  var cloudFilesCount: Int      // files with cloudStatus != .notCloud
  var cloudLocalFilesCount: Int // files with cloudStatus == .cloudLocal
}
struct ScanProgressValue { scannedSize: UInt64; activePath: String?; static let empty }
```
- `SpaceLensCloudScannerStrategy` selection: the builder flag `useUbiquitousScanner` → strategy `= useUbiquitousScanner ? .ubiquitousItem : .dataless` (SLM 0x24634 stores `flag ^ 1`) [O]. The main app supplies the value [?].
- The tree is complete with no depth limit. "Levels" are computed on demand in the module (`LevelInfo{currentItem, children, otherItems}` in SLU, plus `SpaceLensNavigationHistory` back/forward) [O syms]. The rule that splits children into the bubbles and "Other items" ("Smaller items" section) is in SLM/SLU and is not decoded [?].
- When view models are built (SLM FUN_1f964) [O]:
  - A purgeable entity becomes a `PurgeableSpaceItemViewModel` whose size is the live `PurgeableSpaceViewModel._purgableSize`.
  - A directory gets `containsItems = !URLResourceValues.isPackage`. **Packages are sized fully but shown as leaves** (you cannot drill into them).
  - `leavesCount` → `SpaceLensItemViewModel(path:size:leavesCount:isDirectory:containsItems:)`.

---

## 4. Cloud [O]
- Cloud roots and per-file classification are covered in §1.4 and §2.1.
- No download status beyond evicted or local. No sizes from the provider: evicted files contribute their (≈0) allocated size.
- UI:
  - The cloud icon has the tooltip "Cloud files" (`CloudStatusSpaceLensFileItemCellView`).
  - **Evicted items are protected** with the reason "This item is cloud-only. Manage it in Cloud Cleanup Module." [O string, I wiring]. The planner spares them.
- Removal alert (`SpaceLensCloudAlertPresenter`, SLM FUN_17xxx) [O strings]:
  - The trigger is that the selection contains `cloudLocal` files (`cloudLocalFilesCount > 0`, SLM FUN_8290) [I].
  - Title: "Selected files will also be removed from the cloud". Message: "Some selected files are stored in cloud storage. Removing them will permanently delete them from the cloud and all your connected devices."
  - Buttons: "Continue" / "Change Selection". Checkbox: "Don't show again this session". The suppression is in memory, keyed "spacelens-cloud-local-items", and lasts for the app session.
  - Logs: "☁️ Cloud item selected — showing cloud removal alert" / "… auto-confirmed, suppressed for this app session".
- Telemetry `CustomMetric.cloudFilesCount` [O].

---

## 5. Deletion
### 5.1 `SpaceLensDeletionPlanner` (SLS FUN_5cb8; mirrored in SLM FUN_98ec) [O]
```
enum Resolution { case wholesale(Unit), filtered([Unit]) }
struct Unit: Hashable { path: String; size: UInt64; removableLeavesCount: Int }
resolve(e, shouldSpare):
  if e.isPurgeable || e.cloudStatus == .cloudEvicted || shouldSpare(e) -> .filtered([])
  if !e.isDirectory -> .wholesale(Unit(e.path, e.size, 1))
  rs = e.children.map(resolve)
  if rs.allSatisfy(.wholesale)          // empty directory → wholesale
       -> .wholesale(Unit(e.path, e.size, e.removableLeavesCount))
  else -> .filtered(rs.flatMap { .wholesale(u) → [u]; .filtered(us) → us })
units(for:e, shouldSpare:) = resolve → wholesale ? [u] : us
```
- The planner **collapses** a fully removable subtree into one path. If one descendant must be kept (a cloud-only file, a protected item, the purgeable child), it **descends** and deletes only the removable siblings. The result therefore never deletes a spared item through its parent.
- In SLM the copy works on `URL`s and spares `cloudEvicted` (FUN_98ec). It is the `urlResolver` of each removal task (FUN_9744 / FUN_9180).

### 5.2 Remover chain (SLM ~0x10954) [O]
```
base = FileRemover(fileManager: FileManagerProvider.shared)        // removeFileAndHandleLockAtPath → permanent delete
if privilegedPerformer != nil { base = PrivilegedFileRemover(remover: base, privilegedAgent:, authorizeAgentBlock: FUN_feb8) }
remover = ConfigDependentFileRemover(from: base)                     // debug "fake clean" switch (see engine.md §3.2)
per selected node: FilesRemovalTask(value: node, fileRemover: remover,
                     urlResolver: { planner(node.entity) → [URL] },  dependenciesFetcher: { [] }, throwErrorIfDependenciesUnresolved: false)
processor: MinimumTotalDurationTasksProcessor(minimumTotalDuration: 2.0, preparationDelay: 0.5)   // SLM FUN_8c4c
```
- **Permanent delete, not Trash.** SLM/SLU contain no trash symbol or string [O].
- Task info: `SpaceLensCleanTaskInfo{taskID, name, icon = NSWorkspace.iconForFile(path)}` (FUN_94e8).
- FileManagerService's `ProtectedFileRemover` refuses protected folders (engine.md).

### 5.3 Protection (SLM FUN_15154, FUN_9230) [O]
- `isProtected(path)` is true if any of these holds:
  - `iCloudAliasPathFor(path) != nil`;
  - either of 2 KnowledgeBase checks (`KnowledgeBaseScannerService.build(for:scannerGroupID:)`) matches;
  - `isFileRestrictedAtPath`;
  - `isFileProtectedByRootlessAtPath` (SIP).
- Protected items cannot be selected. They show "This is an essential system item and it cannot be deleted." Trying an action on one logs "Requesting actions for protected item: ".
- `isSystemFolder` items stay selectable but show a confirmation checkbox: "This folder is required for the system to operate. It's not recommended to remove system folders" [O strings, I logic].
- The view model also carries the flags `isHiddenItem` and `isEphemeral`.

### 5.4 Confirmation and update [O strings / I flow]
- The results "Review and Remove" button leads to the review screen. It is titled "Review files before removal" / "Review Items Before Removal" and shows the selected items flattened ("This includes items from all selected folders.").
- Next comes the cloud alert, if one applies, then "Removing files..." and then the outcome:
  - Success: "Removal complete!" with "<size> successfully removed", plus "Done" and "Review More Items" (`canReviewRemainingItems`).
  - Failure: "Removal failed..." with "Some files were not removed. Please make sure none of your apps are using them and try again.", plus "Try again" and the "Removal Log".
- After removal, the module updates its node tree in place. Removed nodes are detached using `originalParent` and `resultsUpdater`, and `SelectableSizer`/`SimpleSizer` recompute parent sizes. There is **no rescan** [I]. Undo/ignore uses `IgnoreUndoManager` [O sym].

---

## 6. Module flow and texts
1. **Intro**: "Space Lens" — "Visualize what's taking up the most disk space and clean up your storage quickly."
   - Categories: "Visual Storage Map", "Large Folders Overview", "Hidden Files Uncovered".
   - Footer: volume/folder selector (Home, volumes, "Choose folder...").
   - The Space Lens tile uses a `UbiquitousButtonConfiguration` with colours 0x4300ca and 0xb7b9fa.
2. **Scan progress**: "Visualizing your storage space..." (`ScanProgressViewModel`). Its progress is `CountableProgress` (scanned bytes ÷ used volume bytes). It supports pause, resume and stop.
3. **Results** (`SpaceLensViewController`):
   - Bubbles: circle packing via `PackedNode<BubblePackingLayoutItem>`, `BubbleUIConfig.spaceLens`, plus an "Other items" bubble ("Various files and folders taking up space").
   - An outline list: `SpaceLensListViewController` with a "Smaller items" section.
   - A path control, back/forward history, a disk indicator ("%@ of %@ used"; tooltips Used/Free/Purgeable/Selected), Quick Look and a context menu (Reveal in Finder, Select/Deselect).
   - Tooltips: "Size: %@", "Selected: %@", "Entire folder", "Modified: %@", "System folder".
   - "Purgeable Space" item, with the tooltip "Clean Purgeable Space". It routes to `RouteParameters.purgeableSpace()` (Performance module).
   - Empty result: "Too empty to visualize..." / "Try scanning a more substantial folder to preview its contents." / "Start over".
4. **Review**: `SpaceLensReviewItemsViewController`. Its button is "Remove".
5. **Clean progress** → **Cleanup complete** / **Removal Log** (§5.4).
- NFR/analytics: `trackScanStart`, `trackScanCompletion(size:foundItems:status:reason:)`, and the metrics size, cloudFilesCount, totalItemsCountInFolder, diskSizeInGB, availableSpaceInGB and freeSpaceShare. Analytics events: "Review and Remove", "Review Selection", "Go Into Folder", "Go Up To Folder", "Click Back/Forward History", "Reveal/Hide Other Items", "Choose Folder".
- `SpaceLensModuleConfig.cleanupContext` = 0 [O].

### 6.4 Indicator [O strings]
- `SpaceLensIndicatorViewModel` builds its segments from `VolumeModel` (via `VolumeModelProvider`, which auto-updates on a timer) together with `PurgeableSpaceViewModel` (`CMVolumeBackupSizeCacher`).
- It warns in the log when used < purgeable or (used − purgeable) < selected.

---

## 7. Reimplementation checklist
- Iterate with `contentsOfDirectory(at:includingPropertiesForKeys:[fileSize,totalFileAllocatedSize,fileResourceType],options:[])`. Recurse per directory with a TaskGroup and a window of 4.
- Skip: other mount points (except `/`, `/private/var/vm`, `/home`, `/net`), `/Volumes`, the `/System/Volumes/Data/` prefix, `/.nofollow`, and `~/Library/Reminders` when there is no FDA. Do not follow symlinks; count them as files. Keep hidden files. Traverse packages.
- File size = totalFileAllocatedSize (FAT: fileSize). Directory = Σ children. No dedup.
- Cloud roots: `~/Library/CloudStorage`, `~/Library/Mobile Documents`, and iCloud Desktop/Documents. Evicted = `SF_DATALESS` (or `.notDownloaded`).
- Root volume: add a purgeable child = `CSDiskSpaceGetRecoveryEstimate`.
- Progress = bytes vs (total − available capacity), with updates about every 500 MB.
- Delete through the planner collapse rule (§5.1), as a permanent delete with lock-clearing and a protected-folder guard. Show a cloud-local warning first. Update the tree in place.
