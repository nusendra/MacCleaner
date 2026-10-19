# CleanMyMac 5 (MAS 5.7.1): System Junk scan and clean engine, module flow

Clean-room behavioural spec from static analysis only. Tags: **[O]** observed directly in code or data, **[I]** inferred from code structure, **[?]** uncertain.
Addresses are in the thin arm64 binaries under `$S/bin`. Annotated decompiles, with stub thunks resolved to imported symbols, are at `$S/map/*.ann.c`. The stub maps were built by `$S/map/mk.py` and `$S/map/ann.py`.

---

## 0. Architecture at a glance

```
JunkCleanupModuleBuilder.build()                      (JunkCleanupModule @81dfc)
 ├─ ScanningModuleCoordinator / JunkCleanupModuleCoordinator (ModuleCore)
 │    intro → [sandbox access gate] → scanning → results(tiles) → review(DataManager) → cleaning → cleanResults
 ├─ CommonModuleScanner(scannerFactory = JunkCleanupScannerFactory)
 │    └─ ProcessingQueue (ScanningCore) + ProcessingQueueWatcher(timeouts) + ScannerNFRHelper(telemetry)
 │         tasks = LegacyScanTaskWrapper<ObjC CMxxxScanTask> from SystemJunkScanTasksFactory, Trash/Mail/AI factories
 ├─ JunkCleanup model (FUN_00010a20): JunkCleanupRootNode + mappers + ignore/undo + result updaters
 └─ CommonModuleCleaner(tasksProcessorProvider = MinimumValueDurationTasksProcessor(2.0s))
      └─ TasksProcessor → ProcessingQueue(maxConcurrent=1) → FilesRemovalTask / specialised removal tasks
           └─ ConfigDependentFileRemover(from: PrivilegedFileRemover?(FileRemover))
```

---

## 1. Scanning engine

### 1.1 Scanner IDs, configuration and gating

* A scanner ID is `Tagged<JunkCleanupModuleConfig, String>`. It is a camelCase string such as `userLogs` **[I]**. The value is built by a once-initializer through `FUN_0002a964`. The symbol names are `userLogs`, `brokenPreferences`, `userCaches`, `documentVersions`, `xcodeJunk`, `mail`, `trashes`, `mountedTrashes`, `mailTrashes`, `aiJunkFiles`, `aiLocalModels`, `deletedUsers`, `brokenStartupItems`, `systemLogs`, `backups`, `applicationLanguages`, `systemCaches` and `universalBinaries`. **[O]** These are the `Tagged::*::unsafeMutableAddressor` symbols at 0x2a3c8–0x2ab04.
* `Tagged.allForEnvironment(isSandbox:)` @0x2ab20 **[O]**:
  * Always included, in this order: `brokenPreferences, userLogs, documentVersions, userCaches, xcodeJunk, mail, trashes, mountedTrashes, mailTrashes`, then `aiJunkFiles, aiLocalModels`.
  * Only when `!isSandbox`, these are appended: `deletedUsers, brokenStartupItems, systemLogs, backups, applicationLanguages, systemCaches, universalBinaries`.
* Group subsets, used by the custom flows **[O]**:
  * `systemJunkGroupForEnvironment(isSandbox:)` @0x29d88 returns `[brokenPreferences, userLogs, documentVersions, userCaches, xcodeJunk]`. In a non-sandbox build it adds `[deletedUsers, brokenStartupItems, systemLogs, backups, applicationLanguages, systemCaches, universalBinaries]`.
  * `trashBinsGroupForEnvironment` @0x2a234 returns `[trashes, mailTrashes, mountedTrashes]`.
  * `mailGroup` @0x29cb4 and `aiClutterGroup` @0x29b8c also exist.
* `ModuleJunkCleanupScanningConfig.scanners` @0x2b59c (via FUN_0002ca20) computes `Set(allForEnvironment(ProcessInfo.isSandbox)) − SharedPreferences.junkCleanupModuleDisabledScanTasks`. That preference is the user's Settings toggles. **[O]**
* `hasActiveTasks` @0x2b5d0 is `!scanners.isEmpty` **[O]**. When it is false the flow fails, and `JunkCleanupModuleCoordinator.failedRun` @0x71b0 shows an alert with the text "You have disabled all %@ module items from scanning." and a "Go to Settings" button. That button calls `openScanningSettings`. **[O]/[I]**
* `JunkCleanupModuleConfig` @0x84cf0–0x85484 holds `scanConfig`, `kind` and `customDependenciesResolverFactory` **[O]**. The `Kind` enum has these cases:
  * `custom(flowID)`, tag 0. The constructor is `custom(flowID:scanners:)`, so a custom flow passes an explicit `Set`.
  * `full`, tag 1. It uses the default `ModuleJunkCleanupScanningConfig`.
  * `smartCare`, tag 2.

### 1.2 The tasks that are created, in order (`JunkCleanupScannerFactory` pipeline `FUN_0001f574`)

`ScannerNFRHelper.pipelineStarted()` runs first. Then four sub-builders run in sequence, and then `ProcessingQueueWatcher.attach(to: queue)` is called. **[O]**
Each task is added only if `scanConfig.scanners.contains(id)`. That check is `FUN_0002258c`, which is `Set.contains`. Each added task follows the same pattern: create a knowledge base, create the task, call `ScannerNFRHelper.register(task, nfrType:)`, then `ProcessingQueue.addTask(descriptor:task:priority:0, progressValueTransform:, completion:)`.

| # | Gate ID | Factory call (SystemJunkScanTasksFactory unless noted) | ObjC task class (SystemJunkScanning) | Result model |
|---|---|---|---|---|
| 1 | userLogs | `userLogs(knowledgeBase:)` @0x3a288 | CMUserLogsScanTask | [LogsModel] |
| 2 | brokenPreferences | `brokenPreferences(knowledgeBase:)` @0x3a310 | CMBrokenPreferencesScanTask | [BrokenPreferencesModel] |
| 3 | userCaches | `userCache(knowledgeBase:privilegedOperationsPerformer:)` @0x3a478 | compound user-cache task (FUN_00042e20) | [CacheModel] |
| 4 | documentVersions | `documentsVersions(knowledgeBase:)` @0x3a37c **+ watcher override** | CMDocumentVersionsScanTask | [DocumentVersionsApplicationModel] |
| 5–15 | xcodeJunk (one gate, 11 tasks) | xcodeDerivedData, iOSDeviceSupport, macOSDeviceSupport, tvOSDeviceSupport, watchOSDeviceSupport, moduleDocumentation, moduleCache, coreSimulatorCache, iosDeviceLogs, xcodeArchives, xcodeSimulators, simulatorRuntimes **+ watcher override** | CMXcode*ScanTask, CMXcodeDownloadedRuntimesScanTask | XcodeJunk* models |
| 16 | trashes | `TrashScanTasksFactory.makeSystemTrashScanTask()` (FUN_0002138c) | — | |
| 17 | mountedTrashes | `makeMountedVolumesTrashScanTasks()`, which gives one task per mounted volume | — | |
| 18 | mailTrashes | `makeMailTrashScanTasks()`, which gives N tasks | — | |
| 19 | mail | `MailJunkScanTasksFactory.mailAppAttachments(knowledgeBase:)` (FUN_00021bb0) | — | |
| 20 | aiJunkFiles | `AIJunkScanTasksFactory.makeAgentFootprintScanTask(onToolError:)` (FUN_00021ef8) | AgentFootprintScanTask | |
| 21 | aiLocalModels | `LocalModelScanTasksFactory.makeLocalModelsScanTask(onStoreError:)` | LocalModelsScanTask | |

Evidence: `FUN_0001f5e4` @0x1f5e4 (annotated lines 22310–23056), plus FUN_0002138c, FUN_00021bb0 and FUN_00021ef8 **[O]**.

**The MAS build cannot create these tasks:** `deletedUsers`, `makeUniversalBinaries`, `brokenStartupItems`, `systemLogs`, `mobileBackups`, `applicationLanguages` and `systemCache`. The factory methods exist in SystemJunkScanning (@0x3a120–0x3a3a0), but JunkCleanupModule.dylib does **not import** them. Its undefined-symbol list has only the 16 methods in the table above. **[O]** Their IDs exist only so the non-sandbox `allForEnvironment` list stays complete.

The knowledge base passed in comes from `knowledgeBaseServiceBuilder` and the `systemJunk`, `mail` and `aiClutter` KnowledgeBaseFactory objects (the model fields) **[O]**. Category IDs are passed as ints: 0xf, 5, 8, 0x1e and 0x27 **[?]**.

### 1.3 ScanningCore queue, watchdog and progress

* **ProcessingQueue** (ScanningCore) wraps an `OperationQueue`, held at `self+0x10` **[O]** (`maxConcurrentOperationCount` getter and setter @0x1d7ac forward to it). The junk scanner never sets the value, so scanning runs at the OperationQueue default concurrency (system-determined parallelism) **[I]**. Its API is `addTask(descriptor:task:priority:progressValueTransform:completion:)`, `run(completion:)` and `runSync()`, plus the hooks `onTaskAdded`, `onTaskStarted`, `onTaskFinished`, `onPartialResult`, `onQueueStart` and `onQueueComplete`. `QueueResult` has `{status, value}`. **[O]**
* **TaskPriorityKind** is an Int: `low = -1000`, `high = 1000` (@0x28664 and @0x28678), and `normal` is presumably 0 **[O]/[I]**. Junk adds every task with priority 0 **[O]**.
* **DependentTask** has `init(_:name:dependencies:throwErrorIfDependenciesUnresolved:)`. It waits for its dependency tasks. If `throwErrorIfDependenciesUnresolved` is set, a failed dependency raises an "unresolved dependencies" error, which `UnresolvedDependenciesDependentTaskErrorMapper` maps **[O]** (symbols).
* **ProcessingQueueWatcher / TaskWatcher** is the watchdog:
  * `ProcessingQueueWatcherConfiguration.default` @0x181dc sets `defaultTimeout = 60 s` and `staleProgressThreshold = 10 s` **[O]**. The watcher is built with `.default` and `Date.init` as the date provider (JunkCleanupModule line ~21951) **[O]**.
  * Per-task overrides use `TaskWatcherConfiguration(timeout: 300 s, staleProgressThreshold: 60 s, timeoutAction:)`. They apply to **documentsVersions** and **simulatorRuntimes** (doubles `0x4072c00000000000 = 300.0` and `0x404e000000000000 = 60.0`, lines 22615 and 23003) **[O]**.
  * The `timeoutAction` (FUN_00028c34) **cancels the task** through a witness on the task protocol, then calls `ScannerNFRHelper.handleTaskCancelledAfterTimeout` **[O]**. With the default config no `timeoutAction` is set, so a timeout is only reported **[I]**.
  * Problems are `TimeoutProblem(taskDescriptor, timeout, elapsedTime)` and `StaleProblem(taskDescriptor, lastProgressTime, staleDuration, lastProgressValue)`, wrapped in `ProblematicTaskInfo{detectedAt, resolvedAt, isResolved, isTaskFinished}` and published through `problematicTasksPublisher` **[O]**.
  * TaskWatcher uses a `DispatchSourceTimer` on a global queue, with a deadline of `now + configuration.timeout` (FUN_0001a068) **[O]**. A task is stale when its progress has not changed for `staleProgressThreshold` **[I]**.
* **Progress model:**
  * `CompoundProgress.addProgress(_:weight:id:)` combines child progress values, with `CompoundProgressSnapshot{itemsCount,totalWeight}` **[O]**.
  * `CountableProgress(estimatedUnitsCount)` with `addUnits(count:)`, and `PercentagesProgress`, are also available.
  * The UI receives `ScanProgress{title, subtitle, fraction}` **[O]**.
  * The per-task `progressValueTransform` (FUN_0002382c) maps a task to its display string, which is the current task name for the subtitle **[I]**.
  * A scan cannot be paused in Junk. The controllable states `idle|scanning|paused|stopping|finished` exist in ModuleCore **[O]** (enum).

---

## 2. Result tree

### 2.1 Node types (Swift field metadata, `$S/map/JCM.fields`) **[O]**

* `JunkCleanupRootNode {category, totalSizer, systemJunkNode, mailJunkNode, trashJunkNode, aiClutterNode}`. Its init is @0x8a260, and the root is created in FUN_00010a20 with `FUN_000705c0(0,0,0,0)`.
* `JunkCleanupCategoryNode {category, sizer, totalSizer, selection, footerInfo, analyticsInfo, analyticsInfoName, sortingOptions, footerFactory, isAutoSelected, groupedInfo}`. There are four categories: System Junk, Mail Attachments, Trash Bins and AI Clutter.
* `JunkCleanupGroupNode {selectionControl, sizer, totalSizer, groupedInfo, groupItemInfo, analyticsInfo, analyticsName, id, model, groupId, cleaner, imageSource, isAutoSelected}`. There is one group per scanner/group ID. The group-ID enum is `mountedTrashes, mailTrashes, deletedUsers, universalBinaries, brokenLoginItems, brokenPreferences, userLogs, systemLogs, applicationLanguages, mobileBackups, documentsVersions, userCache, systemCache, xcodeJunk, mailApp, macOSTrashes, aiJunkFiles, aiLocalModels`.
* `JunkCleanupItemNode {sizer, totalSizer, detailsItemInfo, isAutoSelected, canBeSelected, id, model, url, cleaner, ignoreInfo, imageSource}` is the leaf or intermediate item, for example app → files. A second node type with `{selection, sizer, totalSizer, footerInfo, analyticsInfo, model, groupedInfo, sortingOptions, categoryContentSelectors}` is a sub-group container **[I]**.
* `JunkCleanupTileNode` is a summary tile on the results screen. Tiles come from `JunkCleanupTilesMapper` and `TilesStore`, and each has the action **Clean** or **Review** (`tiles_action_clean` / `tiles_action_review`) **[O]**.
* The mappers are `SystemJunkNodeMapper`, `XcodeJunkNodeMapper`, `TrashJunkNodeMapper`, `MailJunkNodeMapper`, `AIClutterNodeMapper` and `JunkCleanupItemsNodeMapper` **[O]**. Each one maps a scan-result model to Group and Item nodes **[I]**.
* `JunkCleanupSystemJunkScanTaskInfo.info(for:)` @0x379f8 returns `{name, image, analyticsName}` for each scanner ID. The analytics names are "User Logs", "System Logs", "Backups", "User Caches", "System Caches", "Universal Binaries", "Xcode Junk", "Trashes", "Mail Trashes", "Mounted Trashes", "Agents Junk", "Local Models" and "Unknown" **[O]**. The display titles are in the Localizable.strings `system_junk_*_group_title` keys, for example "User Cache Files" **[O]**.

### 2.2 Sizes **[O]** (FileManagerService `CMByteSizer`, invoked through `FileSizingService` / `fileSizer`)

* `byteSizeAtURL` @0x25e8 → `_originalItemSizeAtPath:withCancellationFlag:` @0x28ac. This computes the **allocated (on-disk) size**:
  1. Try Spotlight: `MDItemCreate` + `kMDItemPhysicalSize`. Use it if it is non-zero.
  2. Otherwise walk the tree with `fts_open(path, FTS_PHYSICAL|FTS_NOCHDIR)`, so symlinks are not followed. For every entry, sum `st_blocks` (512-byte units). If `st_size ≥ 2^41`, use `ceil(st_size/512)` instead. Directories count as well (FTS_DP case). The walk checks the cancellation flag on each entry. Errors other than ENOENT are logged and skipped.
  3. Round the total up to a multiple of `getbsize()`, in 512-byte units, and return it in bytes.
* **Hard links and clones are not deduplicated** in this path. A hard-linked file is counted every time it appears, and an APFS clone counts at full allocated size. Only `itemSizeWithFTSEntry:` @0x27b8 returns 0 when `st_nlink > 1`, and it is not on this path. **[O]**
* `logicalByteSizeAtPath:` @0x2704 is plain `stat().st_size`, with no recursion. It is used for single files where a logical size is wanted **[O]**. An optional time-measured wrapper logs measurements that take more than 5 s **[O]**.
* In the tree, `sizer` is a `SimpleSizer` (keypath accessor) or `SelectableSizer` (NodesCore). A parent's size is the sum of its children's sizes. `totalSizer` is the total regardless of selection, and `sizer` counts only the selected items **[I]**. LegacyScanningCore keeps autoselected sizes in parallel (`_addAutoselectedSizeRecursively:`) **[O]**.

### 2.3 Auto-selection (the "safe" / "review" split)

* `JunkCleanupAutoSelectableStrategy` has the cases `disabled | smartSelect | full` **[O]**. It is stored in the model at `+0x10`.
* The strategy is chosen by FUN_00010664 **[O]**. The mapping of its 0/1 return value onto the enum is **[I]**:
  * `Kind.full` (the main Cleanup module scan) gives **0, disabled**. Explicit auto-select is not applied, so every node keeps its scan-time `isAutoSelected` default.
  * `Kind.smartCare` gives **1, smartSelect**.
  * `Kind.custom(flowID)` gives smartSelect if `flowID ∈ {"trashBinCleanup", "eneyCleanupModuleScan", "mailAttachmentsCleanup"}`, and disabled otherwise. The flow IDs were decoded from the literals at 0x9228, 0x9f940 and 0x9f960.
* FUN_00072d34 @0x72d34 applies the strategy after mapping. If it is smartSelect, it calls `selectionControl.select(.smartSelect)` on every child of each category. The `full` case presumably selects everything **[I]**.
* Per-item defaults come from the scan models' `isAutoselected` flag: CacheFileModel, LogsModel, BrokenPreferencesModel, DocumentVersionFileModel, MobileBackup (`autoselected`, `latest`), UniversalBinaryModel, XcodeSimulatorModel, XcodeDownloadedRuntimeModel and CMCacheScanTask `isResultAutoselectable` **[O]** (symbols). The decision rules live in the scan tasks and knowledge base; see the per-scanner specs.
* UI meaning:
  * Auto-selected items are cleaned by the **Clean** tile action.
  * Groups whose items are not auto-selected (for example Document Versions, Deleted Users, iOS Backups and local AI models) offer **Review**. A confirmation alert is shown when the selection includes the latest iOS backups, and another for AI local models.
  * `JunkCleanupRootNode.selectionConfirmation` exists for these alerts.
  * This split is **[I]**. The strings are **[O]**.

---

## 3. Cleaning

### 3.1 Processors **[O]**

* `CommonModuleCleaner(dependenciesResolvers:progressTransformer:beforeCleanClosure:afterCleanClosure:tasksProcessorProvider:)` takes `tasksProcessorProvider = FUN_000109dc`. That provider returns `MinimumValueDurationTasksProcessor(minimumDuration: 2.0, dependenciesResolvers:)`, from the constant `0x4000000000000000`.
* `TasksProcessor` (CleaningCore):
  * It owns a `ProcessingQueue` and sets **`maxConcurrentOperationCount = 1`** (TasksProcessor.init @0x125ac, line 17449). Cleaning is therefore **serial**.
  * It exposes `taskStatePublisher` (`CleanQueueState{tasksState, tasksStateByTaskId}`, with task state `idle|started|finished`), `taskTitlePublisher`, `pause`, `resume` and `cancel`.
  * Tasks are added through `addTask(info: CleanTaskInfo{taskID,name}, task)`.
* `MinimumValueDurationTasksProcessor` wraps every task. Its wrapper fields are `minimumDuration, maximumSleepDuration, progressCancellable, progressSubject, innerTask, name, processingQueue`. The wrapper:
  1. Runs the inner task.
  2. Then, while `elapsed < minimumDuration` and the task is not cancelled, sleeps `min(remaining, 0.05 s)` (`NSThread.sleepForTimeInterval`, FUN_00011500 area, lines 16420–16450).
  3. Meanwhile a 0.1 s `Timer.publish` drives `progress = min(elapsed/minimumDuration, 1, innerProgress)` (lines 16613 and 16705).
  * **Every cleaning task therefore takes at least 2 s.** This is an artificial minimum.
* `MinimumTotalDurationTasksProcessor(minimumTotalDuration:preparationDelay:)` is not used by Junk. When used, it delays the completion by `minimumTotalDuration − elapsed` on a global queue (@0x103ac, line 15919). The `init(dependenciesResolvers:)` initializers of both subclasses are unimplemented traps.

### 3.2 Removers **[O]**

The remover chain is built in FUN_00010a20, for the whole module:

```
base   = FileRemover(fileManager: FileManagerProvider.shared)
if privilegedAgent != nil:  base = PrivilegedFileRemover(remover: base, privilegedAgent: agent, authorizeAgentBlock: FUN_00011158)
remover = ConfigDependentFileRemover(from: base)
```

* **FileRemover.remove(at:)** @0x9c20 calls `fileManager.removeFileAndHandleLockAtPath:error:`. That is FileManagerService → `FileRemoval.ProtectedFileRemover`, which clears the lock (`tryToUnlockFileIfNeeded(atPath:recursively:)`) and then deletes **permanently**. It refuses paths in a `ProtectedFolderSet` (`protectedFolderRemovalAttempt`) **[I]**.
* **MoveToTrashFileRemover** @0x9d5c calls `NSFileManager.defaultManager trashItemAtURL:resultingItemURL:error:`. JunkCleanupModule **never** references it. **Junk never moves items to the Trash; it deletes them.** **[O]**
* **DebugFileRemover** @0x9d80 only sleeps `(random(0..<99)+1)/1000` s and deletes nothing.
* **ConfigDependentRemover / ConfigDependentFileRemover** (@0x9704, init @0x9e68):
  * It holds `debugRemover = DebugFileRemover()`, `realRemover = base` and `throwIfFailCleanEnabled = true`.
  * On each `remove`, it reads `Config.shared.isDebugRemovalEnabled`. If false, it uses `realRemover`. If true, it first calls `Config.throwsErrorIfFailCleanEnabled(typeName(realRemover))`, which throws `DebugFailCleanError(reason)` when `isDebugFailCleanEnabled` is set, and then uses `debugRemover`.
  * It logs success with `logInfo` and failure with `logError` in the category "FileRemover", with the user name hidden in paths.
  * `Config.configure(isDebugRemovalEnabled:isDebugFailCleanEnabled:)` is a debug switch. Production uses `false/false` **[I]**.
* **PrivilegedFileRemover.remove** @0xa66c:
  1. Try the base remover. On success, return.
  2. On failure, if `url.hasSymlinkInPathAncestors`, throw `FileRemoverError.symlinkDetected(url)` and log a warning.
  3. Otherwise call `authorizeAgentBlock()`. If it returns false, throw `NotAuthorizedPrivilegedAgentError(path)`.
  4. Otherwise call `privilegedAgent.remove(url)` synchronously (`AnyPublisher.syncResult`). If that fails, throw `FileRemoverError.permissionDenied(url)` or the underlying error.
* Specialised removers, also wrapped in `ConfigDependentRemover`, are each created by their own FUN **[O]** (symbols):
  * `BrokenPreferencesRemover(fileManager, prefsdManager, fileRemover)` also syncs cfprefsd **[I]**.
  * `LogsRemover(privilegedAgent, fileRemover, fileManager, authorizeAgentBlock)`.
  * `BrokenStartupItemRemover(performerService)`, which is non-sandbox only.
  * `XcodeSimulatorRemover()` and `XcodeSimulatorRuntimeRemover()`, which use `simctl` / `xcrun` through CMXcrunTaskFactory **[I]**.
  * Removal tasks: `FilesRemovalTask`, `DocumentsVersionsRemovalTask`, `BrokenPreferencesRemovalTask`, `LogsRemovalTask`, `UniversalBinaryRemovalTask`, `BrokenLoginItemsRemovalTask`, `MailJunkRemovalTask`, `XcodeSimulatorRemovalTask` and `XcodeSimulatorRuntimeRemovalTask`.

### 3.3 FilesRemovalTask **[O]** (execute @0xf918)

* It is built with `FilesRemovalTask(value: [Node], fileRemover:, urlResolver: (Node)->[URL], dependenciesFetcher:, throwErrorIfDependenciesUnresolved:)`.
* For each node, for each URL that `urlResolver` returns:
  * If the controllable is cancelled, the node gets `.failure(ControllableCancelledError(node))`.
  * Otherwise it runs `try fileRemover.remove(at:)`. On error the node gets `.failure(FileRemovalTaskError(path: url.path, underlyingError))`.
  * After each node, `CountableProgress.addUnits(1)` runs.
* The output is `[Result<Node, Error>]`, so a partial failure is recorded per node.
* Dependencies come from `DependentCleanTaskType.mapToCleanResultsUnlessCancelledWithDependencies`. When a dependency is unresolved, the task produces `DependencyNotFulfilledForNodeError(reasonForFailure, unresolvedDependencies)`. The UI strings are `errorDescriptionRemoval*Dependency`.

### 3.4 Results and how they update the tree **[O]**

* `CleanQueueResult(items: [CleanTaskOperationResult{taskInfo, result: Result<[Result<Node,Error>],Error>}])`.
* `outcome` @0x316c uses the enum order `success=0, partialSuccess=1, empty=2, failure=3`:
  * No items gives `empty`.
  * A task whose own result is `.failure`, or whose node results are **all** failed, counts as a failed task.
  * If any node failed: `failedTasks == totalTasks` gives `failure`, and otherwise `partialSuccess`.
  * If no node failed: `failedTasks == total` gives `failure`, `failedTasks == 0` gives `success`, and otherwise `partialSuccess`.
  * `hasFailedResults` is true for `{partialSuccess, failure}`. `hasRemovedItems` is true for `{success, partialSuccess}`.
* `CleanQueueResultReferencableNodesUpdater.default(registry:)` and `CleanQueueResultNodesUpdater.update(node:from:)` (@0x5690 and @0x3a24) remove the successfully cleaned nodes from their parents.
* The cascade then walks upward. A parent left with no children is removed when the cascade filter allows it. The default filter (FUN_000044d0) allows removal when the node is not a `CleanableNodeType` or cannot perform cleaning itself.
* Failed nodes stay in the tree and keep their selection. They feed "Review Remaining Items" (`coordinatorDidRequestReviewRemainingItems`) **[I]**.
* `CleanupAwareNode.willUpdateAfterCleanup` and `didUpdateAfterCleanup(isActive:result:)` notify nodes. `CleanQueueResultTilesUpdater` updates the tiles, and `JunkCleanupCleanQueueResultNodesUpdater` and `IgnoreUpdater` do the module-specific updates.
* UI:
  * On full success: "Cleanup complete! … successfully cleaned".
  * On failure or partial success: "Cleanup failed..." with "Some items were not removed. Please make sure you quit all of the related applications and try again." The per-item error popovers use `errorDescriptionFileWasNotAuthorized`, `…FileWriteNoPermission`, `…FileGeneric` and `…StoppedGeneric`.
  * The view log is `cleanupViewLogTitle`.

---

## 4. Permissions in the MAS build

* Entitlements are app sandbox, `files.user-selected.read-write` and `files.bookmarks.app-scope`, with no temporary exceptions. Access to `~/Library` therefore comes **only from an app-scoped security-scoped bookmark of the user's Home folder** **[O]**/[I].
* `JunkCleanupModuleBuilder` receives `homeFolderSandboxAccessProvider: FileSystemAccessProviderType?` and builds `MainFlowStartCompositeCondition([MainFlowStartConditionSandboxAccess(sandboxAccessProviders:)…])`. `ScanningModuleCoordinator.init(...sandboxAccessProviders:)` gets the same providers **[O]** (build @0x81dfc).
* Before a flow starts, `CommonModuleCoordinator.askProvidersForAccessSequentially(_:completion:)` runs. When access is missing, the main app's `BookmarkService`, `SandboxResourcesAccessProvider` and `BookmarkDialogProviderService` show an `NSOpenPanel` with "Please grant access to your Home Folder to continue." and the button "Grant Access" (`module_sandbox_home_folder_access_window_text`, `module_sandbox_folder_access_button_title`) **[O]** (strings).
* The bookmark is created with `URL.bookmarkData(options:)`, stored, resolved with `resolvingBookmarkData(bookmarkDataIsStale:)`, and refreshed when stale ("Refreshing a stale bookmark for URL:"). Cancelling raises `FileSystemAccessDenied` ("Bookmark flow is cancelled by user") **[O]** (main app strings).
* Full Disk Access is tracked by `FullDiskAccessObserver`, `MPFullDiskAccessAuthorizer` (which probes `~/Library/Application Support/com.apple.TCC/TCC.db` and `~/Library/Safari/Bookmarks.plist`) and `SystemPermissionsKit.requestFullDiskAccess`. It is used for analytics, `isFDAGranted…`, and to unlock protected subpaths, and the user can be sent to System Settings. It is **not** required by the Junk start condition **[I]**.
* **Privileged operations:**
  * `SystemJunkPrivilegedOperationsPerformerAdapter` (ObjC, @0x3b224–0x3b50c) wraps an optional `PrivilegedOperationsServiceType`.
  * It exposes `isAuthorized`, which is false when the service is nil, plus `fileSizeAtURL:` and `fileExistsAtURL:`. Each is a sync publisher call that returns 0 or false when the service is nil.
  * The scan tasks that accept it are `userCache` (in MAS) and, outside MAS, systemCache, systemLogs and brokenStartupItems.
  * `PrivilegedFileRemover` and `LogsRemover` use the same agent.
  * The MAS bundle ships `PrivilegedOperationsPerformerService.framework` (mach service `com.macpaw.CleanMyMac.PrivilegedOperationsPerformerService`) but **no helper tool or launchd plist** (Contents/Library holds only the LoginItems Menu and HealthMonitor). In practice the agent is absent or unauthorized, so privileged fallbacks fail with `NotAuthorizedPrivilegedAgentError` or `permissionDenied`. Root-owned paths are never scanned or cleaned in MAS **[I]**.

---

## 5. Module UX flow

* Screens (ModuleCore coordinators) **[O]**: `IntroScreen` → `ScanningScreen` → `ScanResultsScreen` (tiles, "There are %@ of junk files on your Mac.", "Review All Junk") → `DataManagerScreen` (manual review tree) / `ReviewBeforeCleaningScreen` → `CleaningScreen` ("Cleaning %@…", Stop) → `CleanResultsScreen` (Done / View Log / Review Remaining) → `ViewLogScreen`.
* An empty scan shows `EmptyCustomFlowScanResultsScreen` ("Your Mac is pure!").
* The flow state enum is `review | cleanupResults | undefined | scanning | cleaning`, with the module state `idle | inProgress | finished` **[O]**.
* `ScanningModuleMainFlowCoordinator` handles these events: `coordinatorDidFinishedScanning`, `DidRequestCleaning(node)`, `DidRequestReview(node)`, `DidRequestReviewOfTile`, `DidRequestCleaningResults(result:items:)`, `DidRequestReviewRemainingItems`, `DidRequestRescan`, `DidRequestRestart`, `DidRequestReset`, `DidRequestBack` and `DidRequestViewLog` **[O]**.
* Alerts: Stop scan, Stop clean, Start over, Back, and a flow conflict when another module is busy (`showFlowConflictAlert`) **[O]**.
* Custom flows come from `JunkCleanupModuleCoordinator.availableCustomFlowIds()` @0x72cc: `trashBinCleanup`, `systemJunkCleanup` [I], `mailAttachmentsCleanup` and `aiClutterCleanup` [?]. `runTrashBinCustomFlow` and `runAIClutterCustomFlow` call `CommonModuleCoordinator.run(flow:forceReset:)` **[O]**. Each custom flow scans only its group subset (§1.1).
* **Ignore and undo** **[O]**:
  * Item nodes carry `ignoreInfo`.
  * `IgnoreNodesEventDispatcher` emits `willIgnore` and `didIgnore`. `IgnoreUpdater(nodesUpdater:nodeIgnoreDispatcher:registry:)` removes ignored nodes from the tree. The `*IgnoringKnowledgeBaseType` / NodeIgnorer types persist ignored items in the KnowledgeBaseService.
  * `IgnoreUndoManager(ignoreEventsDispatcher:registry:knowledgeBaseService:)` provides `listenForIgnoreActions(on:)` and `stopListeningForIgnoreActions()`. The DataManager shows "Ignored items" with an Undo action (`dataManagerIgnoredItemsUndoActionTitle`). Undo restores the node and removes the knowledge-base entry **[I]**.
* **Safe vs review:** see §2.3. The tile actions are `Clean` and `Review`. The smart-select menu offers Smart Select, Select All, Deselect All, Largest, Smallest, Newest and Oldest (`selectOptionTitle*`) **[O]**.

---

## 6. Reimplementation checklist

1. Compute the scanner set as `allForEnvironment(sandbox)` minus the user-disabled IDs. Fail with "all disabled" if the set is empty.
2. For each enabled scanner, add its tasks to a concurrent queue in the §1.2 order. Use a 60 s timeout and a 10 s stale threshold, with 300 s / 60 s plus cancel-on-timeout for document versions and simulator runtimes.
3. Size each item as Spotlight physical size, falling back to an `fts` sum of `st_blocks` rounded up to the block size. Do not follow symlinks and do not deduplicate hard links.
4. Build the tree Root → Category (4) → Group (per scanner) → Item(s). Default selection is each item's `isAutoselected` flag. Apply smart-select for SmartCare, the Trash, Mail and Eney flows.
5. Before scanning, require a security-scoped bookmark of Home.
6. Clean serially, one task at a time. Each task takes at least 2 s and makes progress updates every 0.1 s. Delete permanently (unlock first, refuse protected folders); never move items to the Trash. Record a result per node. Prune cleaned nodes and empty parents, and compute `success`, `partialSuccess`, `empty` or `failure`.
