# CleanMyMac 5 (MAS 5.7.1) — "Xcode Junk" spec (clean-room, static analysis)

Tags: **[O]** observed directly in decompiled code/disassembly, **[I]** inferred, **[?]** uncertain.
Addresses: `SystemJunkScanning` (SJS) unless noted; `SharedObjcUtils` (SOU) for `CMPaths`; `JunkCleanupModule` (JCM).

## 0. Architecture

- ObjC scan tasks in SJS (`CMXcode*ScanTask`) produce a `CMScanResult` with `CMXcodeJunkGroupModel`
  (a tree entity: value = `CMXcodeJunkItem` group, children = `CMXcodeJunkItemModel(value: CMXcodeJunkItem, size, autoselected)`).
- `SystemJunkScanTasksFactory` (Swift) wraps each task in `LegacyScanTaskWrapper<…>` and maps it to Swift models [O 0x3a568–0x3a908]:
  | factory fn | ObjC task | Swift result |
  |---|---|---|
  | `xcodeDerivedData` | CMXcodeDerivedDataScanTask | `XcodeJunkSubGroupModel?` |
  | `iOS/macOS/tvOS/watchOSDeviceSupport` | CMXcodeDeviceSupportJunkScanTask (+class ctors) | `XcodeJunkSubGroupModel?` |
  | `moduleDocumentation` | CMXcodeModuleDocumentationCachesScanTask | `XcodeJunkSubGroupModel?` |
  | `moduleCache` | CMXcodeModuleCachesScanTask | `XcodeJunkSubGroupModel?` |
  | `xcodeArchives` | CMXcodeArchivesScanTask | `XcodeJunkSubGroupModel?` |
  | `coreSimulatorCache` | CMXcodeCoreSimulatorCachesTask | `XcodeJunkCoreSimulatorCacheModel?` |
  | `iosDeviceLogs` | CMXcodeDeviceLogsScanTask | `XcodeJunkDeviceLogsModel?` |
  | `xcodeSimulators` | CMXcodeSimulatorsScanTask | `[XcodeSimulatorGroupModel]` |
  | `simulatorRuntimes` | CMXcodeDownloadedRuntimesScanTask | `[XcodeDownloadedRuntimeModel]` |
- Swift models (getters in SJS syms) [O]:
  - `XcodeJunkSubGroupModel { rootURL, items:[XcodeJunkModel] }`; `XcodeJunkModel { name, url, size, isAutoselected }`
    (mapper 0x34xxx: rootURL = group item url, items from `models` → junkItem.name / fileURL / size / isAutoselected, no filtering).
  - `XcodeJunkCoreSimulatorCacheModel`, `XcodeJunkDeviceLogsModel { url, size, isAutoselected }` (single item, from group).
  - `XcodeSimulatorGroupModel { name, devices:[XcodeSimulatorDeviceModel] }`; `XcodeSimulatorDeviceModel { udid, name, url, size, isAutoselected }`;
    mapper FUN_000359b8: `isAutoselected = !CMXcodeSimulatorModel.isAvailable` [O 0x43573 line]. `isUnused` is **not** carried into Swift [O].
  - `XcodeDownloadedRuntimeModel { guid, name, url, size, isAutoselected }` (mapper FUN_00031d28, guid = `guidIdentifier`).
- `CMXcodeJunkItem { name, url, type, guidIdentifier }`; `initWithName:url:` uses type **1000** [O 0x16bc4]. Types used:
  1 DerivedData entry, 2 Archive, 4 DeviceLogs, 5 DocCache entry, 7 CoreSimulator caches, 8 Runtime (group + items), 1000 generic.
- Every task honors a knowledge base (`XcodeJunkKnowledgeBase` in JCM, 0x3af90/0x3b13c): `shouldIgnoreURL:` and
  `shouldIgnoreSimulatorRuntime:` delegate to the user Ignore List service (category tag 0xd) — **no built-in Xcode rule** [I].
- Every directory listing uses `contentsOfDirectoryAtURL:… options:5` = SkipsSubdirectoryDescendants|SkipsHiddenFiles [O].
  Size = recursive byte size (`FileSizingService.byteSizeAtURL:cancellationFlag:`).

## 1. Paths (CMPaths in SOU; disassembly 0x1310c–0x13838) [O]

`XS = ~/Library/Developer/Xcode` (`cmm_stringByExpandingTildeInPath`, real home; 0x136a4)

| CMPaths prop | Path |
|---|---|
| derivedData | `XS/DerivedData` |
| archives | `XS/Archives` |
| moduleCache | `XS/DerivedData/ModuleCache` (legacy pre-`.noindex` name) |
| xcodeDocumentationCache | `XS/DocumentationCache` |
| llvmModuleCache | `$DARWIN_USER_CACHE_DIR/org.llvm.clang/ModuleCache` |
| llvmUserModuleCache | `$DARWIN_USER_CACHE_DIR/org.llvm.clang.<NSUserName()>/ModuleCache` |
| iOS/tvOS/watchOS/macOSDeviceSupport | `XS/iOS DeviceSupport`, `XS/tvOS DeviceSupport`, `XS/watchOS DeviceSupport`, `XS/macOS DeviceSupport` |
| iOSDeviceLogs | `XS/iOS Device Logs` |
| xcodeInstalls | `XS/Installs` (not used by Xcode junk tasks) |
| coreSimulatorURL | `~/Library/Developer/CoreSimulator` |
| coreSimulatorCachesURL | `~/Library/Developer/CoreSimulator/Caches` |
| systemCoreSimulatorURL | `/Library/Developer/CoreSimulator` |

`darwinUserCaches` (0x120a8) = `confstr(_CS_DARWIN_USER_CACHE_DIR)`; when sandboxed, the container/bundle-id suffix is stripped → real `/var/folders/…/C/` [I].
Simulator device dir = `coreSimulatorURL/Devices/<udid>` [O 0x1e504]. Runtime path = `runtimeBundlePath` from simctl JSON [O].

## 2. Per-category scan rules

### 2.1 DerivedData — `CMXcodeDerivedDataScanTask::scan` @0x1895c, id `CMSystemJunkScanIdentifierXcodeDerivedData`
- Group item `"Xcode Derived Data"` url=DerivedData, **group autoselected = YES** [O].
- Return empty if cancelled / dir missing / ignored.
- For each top-level child (non-hidden): `junkModelWithURL:` @0x18fc8:
  - skip if lastPathComponent == `"ModuleCache"` exactly (handled by Module Caches task) [O];
  - name = lastPathComponent truncated at the **last** `"-"` (`rangeOfString:@"-" options:NSBackwardsSearch`), e.g. `MyApp-abcdef…` → `MyApp` [O];
  - type 1.
- Skip if ignored; size it; **item autoselected = name ∉ {`ModuleCache.noindex`, `SymbolCache.noindex`}** (compare on lastPathComponent) [O]. Everything else (project folders, `CompilationCache.noindex`, etc.) auto-selected.
- No age / "Xcode running" / project-exists checks [O: none present].

### 2.2 Archives — `CMXcodeArchivesScanTask` @0x170f0, id `CMSystemJunkScanIdentifierXcodeArchives`
- Return empty if cancelled or `Archives` ignored. Group `"Archives"`, **autoselected NO** [O].
- `archives` @0x17630: children of `XS/Archives` (date folders) → for each, its children filtered by `_isValidArchiveAtURL:` (extension == `xcarchive` AND `<archive>/Info.plist` exists) [O 0x17aa0]; flattened.
- Title `_titleForArchiveAtURL:` @0x17b88 from Info.plist: `Name` + `" %@"`(ApplicationProperties.CFBundleShortVersionString) + `" (%@)"`(ApplicationProperties.CFBundleVersion) + `" - %@"`(CreationDate formatted dateStyle=Medium, timeStyle=Short) [O]. Type 2.
- Every archive item **autoselected NO**; no "keep newest"/age rule [O].

### 2.3 Device Support — `CMXcodeDeviceSupportJunkScanTask::scan` @0x19bfc
- Instances [O 0x1a414–0x1a600]: iOS (`"iOS Device Support"`), tvOS, watchOS, macOS; identifiers: iOS/tvOS/watchOS all use `CMSystemJunkScanIdentifierXcodeiOSDeviceSupport`, macOS uses `…XcodeMacOSDeviceSupport` [O].
- Root must exist & not ignored. Group autoselected **NO**.
- Each child (version folder e.g. `17.0 (21A329)` or `iPhone15,2 17.0 (21A329)`): item name = lastPathComponent, type 1000, **autoselected NO** [O].
- **No "keep latest version" logic, no version comparison** [O].

### 2.4 Documentation cache — `CMXcodeModuleDocumentationCachesScanTask` @0x1a88c, id `CMSystemJunkScanIdentifierDocumentationCache`
- Root `XS/DocumentationCache` must exist & not ignored. Group `"Xcode Documentation Cache"`, autoselected NO.
- Items = **grandchildren**: children of each child of root (map+flatten) [O]. Name = `"iOS %@"` with lastPathComponent [O 0x1adfc]. Type 5. Autoselected NO.

### 2.5 Module caches — `CMXcodeModuleCachesScanTask` @0x1c640, id `CMSystemJunkScanIdentifierXcodeModuleCaches`
- Three fixed items [O]: `org.llvm.clang` → llvmModuleCache; `org.llvm.clang.<user>` → llvmUserModuleCache; `com.apple.dt.xcode` → `XS/DerivedData/ModuleCache`.
- Group `"Module Caches"` url=moduleCache, autoselected NO. Each item included only if not ignored and exists; autoselected NO. Empty result if no items.

### 2.6 CoreSimulator caches — `CMXcodeCoreSimulatorCachesTask` @0x18244
- Single item `"Xcode Caches"` (type 7) = `~/Library/Developer/CoreSimulator/Caches` (whole dir), must exist & not ignored; **autoselected NO** [O].

### 2.7 iOS device logs — `CMXcodeDeviceLogsScanTask` @0x19464
- Single item `"iOS Device Logs"` (type 4) = `XS/iOS Device Logs`, **autoselected YES** [O].

### 2.8 Simulators — `CMXcodeSimulatorsScanTask::scan` @0x1d128, id `CMSystemJunkScanIdentifierXcodeSimulators`
Preconditions (else empty result) [O]:
1. `~/Library/Developer/CoreSimulator` exists and not ignored.
2. `CMXcodeSimulatorControl.isUpToDate` @0x1f248 (guards against Xcode "first launch / install components" state):
   - `sysBuild` = `/System/Library/CoreServices/SystemVersion.plist` → `ProductBuildVersion`.
   - `devBuild`: run `/usr/bin/xcode-select -p` (via CMProcess, trimmed stdout, must be reachable) → `<dev>`; read `<dev>/../version.plist` → `ProductBuildVersion` (i.e. `Xcode.app/Contents/version.plist`).
   - For each name in `["CoreSim","MobileDevice"]`: file `NSTemporaryDirectory()/com.apple.dt.Xcode.InstallCheckCache_<name>_<sysBuild>_<devBuild>` must be reachable. Up-to-date only if **both** exist (and both builds non-nil).
3. Run `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl list devices --json` (direct exec, not via xcrun) [O NSConstantArray 0x71e48]. Error → error result; empty stdout → empty result; JSON parse error → error result; missing `devices` dict → empty.

Grouping `_performScanWithDevicesInfo:` @0x1d4f4 [O]:
- For each key `K` of `devices`:
  - if `K` hasPrefix `com.apple.CoreSimulator.SimRuntime.` → group name = `K`, `isUnused = NO`;
  - else → group name = `"CMXcodeSimulatorsScanTaskUnusedGroupIdentifier"`, `isUnused = YES` (all non-runtime-domain keys merge into one group).
  - Group created once per name unless `knowledgeBase.shouldIgnoreSimulatorRuntime(name)`; if ignored, its devices are skipped.
  - **"Unused" = the devices-dict key is not a CoreSimulator runtime identifier** (legacy human-readable keys like `iOS 12.0`, i.e. runtime no longer installed/recognised). It is not based on last-boot date or usage [O].
  - runtimeVersion = `stringByRemovingRuntimeInformation(K)` @0x1e0c4: strip prefix, then replace first `-` with space and subsequent `-` with `.` (`iOS-17-0` → `iOS 17.0`) [O].
- Per device dict `modelWithSimulatorInfo:…` @0x1e504: requires `udid`, `name`, `state` strings (else skipped).
  `isAvailable` = `isAvailable` bool if present, else `availability == "(available)"`. `availabilityError` → NSError(domain `CMXcodeSimulatorModelDomain`, code 101).
  state: `Booted`=2, `Creating`=1, else 0 [O `_CMGetXcodeSimulatorModelState`]. url = `coreSimulatorURL/Devices/<udid>`; size = dir size.
  **autoselected = !isAvailable** [O]. Device kept only if url exists and not ignored.
- No booted-state exclusion found in scanner (state stored only) [O/?: UI may use it].

### 2.9 Downloaded runtimes — `CMXcodeDownloadedRuntimesScanTask::scan` @0x1b300, id `CMSystemJunkScanIdentifierXcodeDownloadedRuntimes`
Preconditions [O]: `/Library/Developer/CoreSimulator` exists & not ignored; fetcher available (FUN_00049f20): macOS ≥ 13 (`__isPlatformVersionAtLeast(macOS,13,0,0)`) AND `/bin/sh -c "/usr/bin/xcode-select -p"` exit status 0.
Fetcher `CMSimulatorRuntimesFetcher` (FUN_0001bc70) [O]:
- exec `simctl runtime list -j` (simctl full path as above; log label `"simctl runtime list -j"`).
- timeout `dispatch_time(0, 60 s)`, `terminateOnTimeout = YES`; "still waiting" log every 10 s (ivar 10.0); cancels with scan progress.
- non-zero/failed → `[]`; stdout not UTF‑8 → `[]`; not JSON → `[]`.
- JSON top-level dict (UUID → runtime dict); each value → `CMSimulatorRuntimeModel` requiring `identifier`, `deletable`, `runtimeBundlePath` (nil if any missing).
- Keep only `deletable == true` (FUN_0004a014 filter → FUN_0001c3a8).
Items: url = `runtimeBundlePath`; must exist & not ignored; name = lastPathComponent (e.g. `iOS 17.0.simruntime`), type 8, guid = `identifier`, **autoselected NO**. Group `"Xcode Simulator Runtimes"` url=/Library/Developer/CoreSimulator, autoselected NO. Empty result if no children.
No "in use by a simulator"/version comparison logic [O].

## 3. Auto-selection summary

| Category | Default |
|---|---|
| DerivedData entries | YES, except `ModuleCache.noindex`, `SymbolCache.noindex` |
| iOS Device Logs | YES |
| Simulators | YES only if unavailable (`isAvailable == false`) |
| Archives, DeviceSupport (all OS), Documentation cache, Module caches, CoreSimulator Caches, Runtimes | NO |

(JCM may layer a global auto-select strategy; scanner flags are passed through unchanged by mappers [O].)

## 4. Removal

- Simulator devices: `XcodeSimulatorRemover.remove(uuid:)` @0x39d28 → exec `simctl delete <udid>` (array `["delete", uuid]`), `terminateOnTimeout=YES`, `executeWithProgress:nil`; throws on launch failure or non-nil error [O]. Wrapped by JCM `ConfigDependentXcodeSimulatorRemover` (debug "[SIMULATE]: Remove simulator", logs "Removed/Failed to remove simulator with UUID: ") and `XcodeSimulatorRemovalTask` [O strings].
- Runtimes: `XcodeSimulatorRuntimeRemover.remove(uuid:)` @0x39f1c → `simctl runtime delete <identifier>` (`["runtime","delete",guid]`) [O]; via `XcodeSimulatorRuntimeRemovalTask`.
- All other categories: plain file deletion of the item URL via CleaningCore `FileRemover` (FileManager remove, **not** Trash; JCM does not reference `MoveToTrashFileRemover`) [I]. Root dirs (DerivedData, Archives…) are group containers; selected children are deleted, CoreSimulator `Caches` and `iOS Device Logs` are deleted as whole directories [I].
- App-dependency guard: JCM node builders register `com.apple.dt.Xcode` (Xcode junk) and `com.apple.iphonesimulator` (Simulators node) as application dependencies → user asked to quit them before cleaning [I strong; JCM FUN_00061f48, FUN_00065dc4].
- `CMXcrunTaskFactory.xcrunTaskWithArguments:` (`/usr/bin/xcrun`) exists but is unused by these paths; all simctl calls exec the CoreSimulator `simctl` binary directly (reachability-checked, error if missing) [O].

## 5. Presentation (JCM)

- Top group "Xcode Junk" (`system_junk_xcode_junk_group_title`, scan id `CMSystemJunkScanIdentifierXcodeJunk`, help id `system-junk_xcode-derived-data`) [O strings].
- Subgroups created in order (FUN_00062520) [O]: `Derived Data`, `iOS Device Support`, `macOS Device Support`, `tvOS Device Support`, `watchOS Device Support`, `Xcode Documentation Cache`, `Module Caches`, `Archives`; plus `Xcode Caches` (CoreSimulator caches), `iOS Device Logs`, `Simulators` (one child node per `XcodeSimulatorGroupModel`, each with device leaf nodes), `Xcode Simulator Runtimes` (runtime leaf nodes).
- Simulator group titles derived from runtime id (strip `com.apple.CoreSimulator.SimRuntime.`, localized key `XcodeJunk_SimulatorRuntime`) [I]; unused group title is the `…UnusedGroupIdentifier` sentinel mapped to a localized "unused" label [?].
- Per-category settings toggles (NFRTaskType): xcodeDerivedData, xcodeArchives, xcodeIOS/TVOS/WatchOS/MacOSDeviceSupport, xcodeModuleCache, xcodeModuleDocumentation, xcodeCoreSimulatorCache, xcodeIOSDeviceLogs, xcodeSimulators, xcodeSimulatorRuntimes [O imports].

## 6. Reimplementation checklist
1. Resolve paths above (real home, not container).
2. DerivedData: list children, drop `ModuleCache`, name=prefix before last `-`, select all but `*.noindex` Module/Symbol caches.
3. Archives: `Archives/*/*.xcarchive` with Info.plist; title from plist; unselected.
4. DeviceSupport ×4: each version dir an unselected item.
5. DocCache: `DocumentationCache/*/*` items "iOS <name>".
6. ModuleCaches: 3 fixed dirs if exist.
7. CoreSimulator/Caches, iOS Device Logs: single items (logs selected).
8. Simulators: gate on InstallCheckCache files; `simctl list devices --json`; group by runtime key; non-runtime keys → "unused"; preselect unavailable; delete with `simctl delete <udid>`.
9. Runtimes: macOS ≥13 & xcode-select ok; `simctl runtime list -j` (60 s timeout); keep `deletable`; bundle path must exist; delete with `simctl runtime delete <identifier>`.
10. Require Xcode / Simulator.app to be quit before cleaning.
