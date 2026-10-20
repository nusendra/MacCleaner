# CleanMyMac 5 (MAS 5.7.1): Performance › Maintenance Tasks: Reimplementation Spec

Static analysis only. Tags: **[O]** observed in code/strings · **[I]** inferred with high confidence · **[?]** unknown/guess.
Binaries: `PerformanceService` (PS), `PerformanceScanning` (PSc), `PerformanceModule` (PM), `MailboxService` (MS), `SharedObjcUtils` (SOU), `PrivilegedOperationsPerformerService` (POPS). Addresses are arm64 slice VAs.

---

## 0. Architecture

| Layer | Types |
|---|---|
| Identifier (PS) | `MaintenanceTaskIdentifier` raw order [O, reflstr]: `0 freeUpRAM, 1 periodicScripts, 2 flushDNSCache, 3 speedUpMail, 4 repairDiskPermissions, 5 reindexSpotlight, 6 thinLocalSnapshots, 7 freeUpPurgeableSpace` |
| Scan identifier (PSc) | `PerformanceTaskIdentifier` [O]: `0 freeUpRAM, 1 periodicScripts, 2 flushDNSCache, 3 speedUpMail, 4 repairDiskPermissions, 5 reindexSpotlight, 6 thinLocalSnapshots, 7 launchServicesLoginItems, 8 launchAgents, 9 freeUpPurgeableSpace` |
| Model + factory | `<X>TaskModel` (`identifier`, plus `estimatedSize` for purgeable and `scripts` for periodic) built by `<X>TaskModelFactory.make()` |
| Scan task | `MaintenanceScanTaskFactory.make<X>Task()` (PSc 0x44f4–0x4b60) wraps the model factory and emits one node. Only ThinLocalSnapshots has a real check (see §7). |
| Runner | `<X>TaskRunner: MaintenanceTaskRunnerType`, `launch(value:) throws` (synchronous, blocking). Errors are `MaintenanceTaskExecutionError`. |
| Privileged path | Runners for FlushDNS, Periodic, ReindexSpotlight and RepairDiskPermissions take `privilegedAgent: PrivilegedOperationsPerformerServiceType?` and call a `MaintenanceTaskOperationsClientType` client over XPC. **No helper ships in the MAS bundle.** No binary in `/Applications/CleanMyMac_5_MAS.app` conforms to `MaintenanceTaskOperationsClientType` (searched with grep) [O]. So the shell commands for these four tasks are **not in this build** [O]. |

### 0.1 Availability: `PerformanceMaintenanceTaskAvailability.isScanTaskAvailable(for:flow:isSandbox:isAppleSilicon:systemVersion:isAPFS:)` (PSc 0x5288) [O]
`Flow`: `0 main, 1 smartCare, 2 toolbox`. `isSandbox` comes from `NSProcessInfo.isSandbox` (SharedUtils) [I]. It is **true for the MAS build**.

| Task (id) | main | toolbox | smartCare |
|---|---|---|---|
| freeUpRAM (0) | `!isAppleSilicon` | `!isAppleSilicon` | false |
| periodicScripts (1) | `!isSandbox && systemVersion.isLessThenSystem(1400)` (OS < 14.0) | same | same |
| flushDNSCache (2) | `!isSandbox` | `!isSandbox` | `!isSandbox` |
| speedUpMail (3) | `!isSandbox` | `!isSandbox` | false |
| repairDiskPermissions (4) | `!isSandbox` | `!isSandbox` | false |
| reindexSpotlight (5) | `!isSandbox` | `!isSandbox` | false |
| thinLocalSnapshots (6) | `!isSandbox && isAPFS` | `!isSandbox && isAPFS` | false |
| loginItems/launchAgents (7,8) | true | false | `isSandbox` (sic) |
| freeUpPurgeableSpace (9) | `!isSandbox` | `!isSandbox` | `!isSandbox` |

`CMSystemVersion.isLessThenSystem:(x)` returns `currentSystemVersion < x` (SOU 0x1a324). `1400` is read as macOS 14.0 [I].
**MAS result:** the only maintenance task this build offers is **Free Up RAM, on Intel Macs only**. Every other task is hidden by availability, and the four privileged runners also throw at runtime because `privilegedAgent == nil`.

### 0.2 Privileged-runner skeleton (FlushDNS 0x5634, Periodic 0x7458, Spotlight 0x7cc4, Repair 0x89e8) [O]
```
guard let agent = privilegedAgent else { throw MaintenanceTaskExecutionError(<code 0x81: empty agent>) }
if !agent.<req@+0x10>() && !agent.<req@+0x20>() {          // both false
    logError("Not authorized privileged agent"); throw .notAuthorizedPrivilegedAgent(id) }
let client = agent.<maintenanceClient@+0x8>                 // MaintenanceTaskOperationsClientType
let ok = try client.<op>(...).syncResult()                  // AnyPublisher<Bool, Error>.syncResult()
on error: logError("<Task> script failed with error: \(err.localizedDescription)") -> throw .unknown/operation(id)
if !ok: logError("<Task> script completed with success but returned false as result") -> throw
```
The meaning of `+0x10` and `+0x20` is [?]; probably "is helper installed/connected" and "is authorized/can authorize". Client witness slots [O]: `+0x08 runPeriodicScript(String)`, `+0x10 flushDNSCache()`, `+0x18 reindexSpotlight()`, `+0x20 repairPermissions(<uid String>) -> Publisher`. The names are [I]. The slot order is [O].

`MaintenanceTaskExecutionError` cases [O reflstr]: `noMailFolder, notAuthorizedPrivilegedAgent, cancelled, timedOut, operationError, unknownError, emptyPrivilegedAgent`. Each is wrapped in `MaintenanceErrorKey{message, errorLocalizationKey, taskExecutionError}`. Bit encoding [I]: `0x00|id` means notAuthorized(id), `0x60|id` means unknown(id), and `0x8x` are the no-payload cases.

---

## 1. Free Up RAM (`FreeUpRAMTaskRunner`, `CMTimedRAMCleaner`, `CMRAMCleaner`)
- **No root needed, no helper, no command.** It is a pure in-process memory-pressure trick [O].
- `FreeUpRAMTaskRunner.launch` (0x6a1c → 0x6abc): `DispatchGroup.enter`, then `workerQueue.async { CMTimedRAMCleaner.clean(); group.leave() }` (0x6cec), then `group.wait()` with no timeout. The return value is ignored [O].
- `CMTimedRAMCleaner.clean` (0xe16c) calls `cleanWithTimeout:30.0`. Cancellation block: `NSDate().timeIntervalSince(start) >= 30` (0xe214) [O].
- `CMRAMCleaner.cleanWithCancellationBlock:` (0xdcf8): `report(before)`, then `_cleanMemory`, then `report(after)`. It **returns `after.freeBytes`** [O, disasm `ldr x0,[sp,#0x10]`]. No before/after delta is computed there.
- `_cleanMemoryWithCancellationBlock:` (0xdd50) [O]:
  1. `seed[10]`: each is `malloc(1024)` filled with `arc4random_buf`.
  2. `n = totalRAM >> 28` (number of 256 MiB chunks). `chunks = calloc(n+1, 8)`.
  3. For each `i < n`: `p = valloc(256 MiB)`. If NULL, log "Finished because of cant allocate any more." and stop. Otherwise fill it with 262,144 `memcpy(p+k*1024, seed[arc4random()%10], 1024)` calls, so every page is dirty and incompressible-ish.
     - Re-read the report. If that fails, log "...unavailablity to get RAM Report" and stop.
     - If `compressed > wired + active + inactive`, then `overflow++`. If `overflow > 1`, log "Finished because of compressed mem overflow" and stop.
     - If the cancel block returns true, log "Finished because of cancellation block" and stop.
  4. Free all chunks and seeds. Log category `"RAMCleaner"`.
- **RAM report** `_CMRAMUsageReportDataInit` (0xdfd8) [O]: `host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, count=0x26)`. Every field is a page count multiplied by `vm_page_size` (u64[]):
  `[0]` pageSize · `[1]` totalRAM (`NSProcessInfo.physicalMemory`, cached by dispatch_once [I]) · `[2]` free = free_count · `[3]` used = total − free · `[4]` pageSize×pageouts [I offset 0x28] · `[5]` wired · `[6]` active · `[7]` inactive · `[8]` compressed = compressor_page_count · `[9]` fileBacked = external_page_count · `[10]` |wired − total + active + inactive + compressed + free| (unaccounted).
- Model: `FreeUpRAMTaskModel{identifier}`. There is no size estimate [O].

## 2. Free Up Purgeable Space (`FreeUpPurgeableSpaceTaskRunner`, `PurgeableSpaceCleaner`)
- **API, not file-fill:** private CoreServices `CSDiskSpaceGetRecoveryEstimate`, `CSDiskSpaceStartRecovery` and `CSDiskSpaceCancelRecovery` [O imports]. No root.
- **Estimate** (`FreeUpPurgeableSpaceTaskModelFactory.make` 0xc124/0xc1d0): `estimatedSize = CSDiskSpaceGetRecoveryEstimate(URL(fileURLWithPath:"/"))`. Traps if negative. The model is `{identifier: 7, estimatedSize}` [O]. The UI subtitle is `"Up to %@"` [O].
- **Free** (0xc3f4) [O]:
  - `avail = "/".resourceValues([.volumeAvailableCapacityKey, .volumeTotalCapacityKey]).volumeAvailableCapacity ?? 0`
  - `target = avail + model.estimatedSize` (overflow trap)
  - `CSDiskSpaceStartRecovery(volumeURL, target, 0 /*flags*/, &uuid, internalQueue, ^(Bool done, Int64 value, CFError? err){...})`
  - Store `processUUIDReference = uuid`.
  - In the callback (0xc734): clear the uuid. If there is no error, the result is `value - avail`; the "bytes of purgeable space" freed is [I]. Otherwise fail with an error.
  - The runner wraps this in `Future` → `eraseToAnyPublisher().syncResult()`, so it blocks.
- **Cancel:** the controllable cancel observer (0x5fd4) calls `CSDiskSpaceCancelRecovery(processUUIDReference)`. It logs "Free up purgeable space was canceled mid-operation." [O]. Errors are logged as "Free up purgeable space script failed with error: …".
- The dedicated module config is `PerformanceModuleConfig.purgeableSpace()` (PM 0x34e40) [O]. Availability is `!isSandbox` in all flows.

## 3. Thin Local Snapshots (`ThinLocalSnapshotsTaskRunner`, `CMVolumeThinner`, `CMVolumeThinnerProcessesFactory`)
- No root, no helper. Runs `/usr/bin/tmutil` via `CMProcess` (NSTask wrapper) [O].
- **Scan/availability** (PSc 0x4f38): `CMVolumeThinner(volumeURL:"/").isThinningAvailable`. If false, throw `ThinLocalSnapshotsScanTaskError` and show no node [O].
  - `_isLocalSnapshotAvailable` (PS 0x1eb8): `tmutil listlocalsnapshots /`. It requires empty stderr, splits stdout on `"\n"`, and counts lines with prefix `"com.apple.TimeMachine"`. Available if the count is above 0 [O].
- **Run** (0xb2b0 → block 0xb0e0): `CMVolumeThinner(volumeURL:"/").performThinningWithRequestedSize:0x40000000 urgency:3` [O]. That executes:
  `tmutil thinlocalsnapshots / 1073741824 3` (args `[cmd, path, "%@"(NSNumber size), "%ld"(urgency)]`, 0x2374) [O].
  It runs inside `CMExecutor(progress:).executeWithDefaultValue:handler:`. `executeWithProgress:` returns an NSError or nil.
  Errors: "Failed to thin local snapshots" and "Thinning local snapshots was cancelled". The domain is `CMVolumeThinnerDomain`, with `CMVolumeThinnerTaskUnavailableErrorCode` when the volume has no path [O]. There is no explicit timeout [O].
- Requires APFS and no sandbox (§0.1).

## 4. Flush DNS Cache (`FlushDNSCacheTaskRunner`)
- **Privileged helper only** (§0.2, client slot +0x10) [O]. The command is not present in this build. In the non-MAS helper it is probably `dscacheutil -flushcache; killall -HUP mDNSResponder` [?].
- Log messages: "Flush DNS Cache script failed with error: ", and "...completed with success but returned false as result" [O]. Statistic category `flushDnsCache` [O].

## 5. Run Periodic Scripts (`PeriodicScriptsTaskRunner`)
- Model `scripts = ["daily","weekly","monthly"]` (static array, PS 0xc2d0; strings [O]).
- Runner (0x7458) [O]: run the scripts **in order**. Each one calls `client.<slot+0x8>(scriptName).syncResult()`. The first error throws, and a false result throws "Periodic scripts completed with success but returned false as result". Privileged helper only. The command is probably `periodic daily|weekly|monthly` run as root [I].
- Only available when not sandboxed **and macOS < 14** [O/I].

## 6. Reindex Spotlight (`ReindexSpotlightTaskRunner`, `ReindexSpotlightObserver`)
- **Privileged helper only** (client slot +0x18) [O]. The command is probably `mdutil -E /` [?].
- `ReindexSpotlightObserver` (PS 0xd678) is an NSObject. It is the delegate of `CMSpotlightIndexingObserver` (SOU) and calls `startObservation` on init and `stopObservation` on deinit. On `spotlightIndexingObserverDidChangeState:` it reads `.indexing` and publishes a `Bool` through `onValueChange` (CurrentValuePublished) [O]. The UI then shows `reindex_spotlight_indexing_description` while indexing is true [I].
  - **In the MAS SOU build the observer is stubbed:** `fetchIndexingStateWithCompletion:` always calls `completion(NO)` and `startObservation` is empty (SOU 0x19c90/0x19c88) [O]. The string "Cannot obtain kMDIndexingNotification constant in SANDBOX version" confirms this [O]. The full build listens to the private `kMDIndexingNotification`, which is re-posted as `CMSpotlightIndexingObserverPrivateNotification`. It also has `isFinishedReindexingForVolumeAtURL:` and `_indexingStatusForVolumeAtURL:` [O names].
- Runner completion means the helper call returned. The task does not wait for indexing to finish [O].

## 7. Repair Disk Permissions (`RepairDiskPermissionsTaskRunner`)
- **Privileged helper only** (client slot +0x20) [O]. The argument is the current user's uid: `getpwuid(getuid())->pw_uid` converted to a String (0x89e8) [O]. The command is probably `diskutil resetUserPermissions / <uid>` [I].
- The client returns a publisher. The runner does `.removeDuplicates().receive(on: UIScheduler.shared).sink(...)`: values update progress, and completion signals a semaphore [O].
- **Timeout:** `semaphore.wait(timeout: .now() + 1800 s)` (const `0x409c200000000000`) [O]. On timeout it logs "Waiting for repair disk permissions script timed out", cancels the subscription and throws `.timedOut` (localized `error_description_maintenance_timed_out`). On failure it logs "Repair disk permissions script failed".
- It is cancellable through Controllable: `sleepThreadWhilePaused`, then cancel the `AnyCancellable` [O].

## 8. Speed Up Mail (`SpeedUpMailTaskRunner`)
- **No helper.** It needs Full Disk Access to `~/Library/Mail`. UI popover: "CleanMyMac needs your permission to speed up Mail." / "Grant Access" [O].
- Steps (0x9904) [O]:
  1. `mailDir = fileManager.userLibraryDirectory + "Mail"`. If the path is missing or `!fileExists`, throw `.noMailFolder` ("Could not find mail folder", localized `error_description_maintenance_operation_error_no_mail_folder`).
  2. `CMExecutor(progress).executeWithDefaultValue:handler:` runs `CMMailInfo.sharedMailInfo.vacuumWithError:`, which executes **`VACUUM;`** via FMDB on the Envelope Index.
     - Path (MS 0x44e8/0x45c4/0x4610): `~/Library/Mail/<LastUsedVersionDirectoryName>/MailData/Envelope Index`. `LastUsedVersionDirectoryName` comes from `~/Library/Mail/PersistenceInfo.plist` (for example `V10`).
     - On failure it logs "Mail Vacuum process failed".
  3. It then runs `/usr/bin/mdimport <mailDir.path>` via `CMProcess.executeWithProgress:` to re-import Mail into Spotlight [O exe; I arg = mail dir].
- It does **not** quit Mail; there are no terminator imports in PS [O]. Whether PM asks the user to quit Mail first is [?]. Cancellation calls `CMExecutor.cancel` [O].

---

## 9. UI strings (PerformanceModule `en.lproj/Localizable.strings`) [O]
| Task | title key → text | description key |
|---|---|---|
| RAM | `free_up_ram_title` "Free Up RAM" | `free_up_ram_description` |
| Purgeable | `free_up_purgeable_space_title` "Free Up Purgeable Space"; subtitle "Up to %@" | `free_up_purgeable_space_description` |
| Snapshots | `thin_local_snapshots_title` "Thin Time Machine Snapshot" | `thin_local_snapshots_description` |
| DNS | `flush_dns_cache_title` "Flush DNS Cache" | `flush_dns_cache_description` |
| Spotlight | `reindex_spotlight_title` "Reindex Spotlight" | `reindex_spotlight_description`, `reindex_spotlight_indexing_description` |
| Permissions | `repair_disk_permissions_title` "Repair Disk Permissions" | `repair_disk_permissions_description` |
| Periodic | `periodic_scripts_title` "Run Periodic Scripts" | `periodic_scripts_description` |
| Mail | `speed_up_mail_title` "Speed Up Mail" | `speed_up_mail_description` |

- Section strings: "Maintenance Tasks", "Running maintenance tasks...", "Tasks done!" / "Tasks failed to run...", "Some tasks were not run. Please try again.", the plural "%d Tasks Selected", the tile "%d Maintenance Tasks Recommended" / "Weekly Maintenance" (`tile_weekly_maintenance_cocktail_*`), "Run Tasks", and "There are no recommended tasks.".
- Errors: `error_description_maintenance_generic` '"%@" did not run for an unknown reason.', `_timed_out`, `_operation_error_cancelled`, `_operation_error_no_mail_folder`, and `_privileged_agent_dependency` '"%@" could not be run because you didn't authorize this operation.'. There is also `UnresolvedDependenciesDependentTaskErrorMapper.runningMaintenanceTask(title:)` [O].
- **Recommended/default selection:** driven by ModuleCore `SimpleAutoSelectableStrategy` (`PerformanceModuleConfig.autoSelectableStrategy`) and the ObjC selectors `canBeAutoselected`/`isAutoSelected` [O names]. The per-task rule was not located [?].
- **"Last run" tracking:** no last-run key, string or NSDate store was found in PM/PS [O, absence]. Each run is recorded as a `StatisticsService.ExtendedStatisticEvent(value:date:category:type:itemsCount:)`. The categories are `freeUpRAM, periodicScripts, flushDnsCache, speedUpEmail, repairDiskPermissions, reindexSpotlight, thinLocalSnapshots, freeUpPurgeableSpace` [O symbols]. A reimplementation can derive "last run" from these events [I].

## 10. Out of scope (same module)
LoginItems and BackgroundItems/LaunchAgents: `LoginItemsRemover`, `BackgroundItemsRemover`, `LaunchAgentModel(+Factory)`, `LaunchAgentExecutableModel`, `LaunchAgentScanLocationsProvider`, `LaunchServicesLoginItemModel(+Factory)` (PS); `BackgroundItemsScanTaskFactory`, `LoginItemsScanTaskFactory`, `LaunchAgentsKnowledgeBase`, `LoginItemsKnowledgeBase` (PSc).

## 11. Reimplementation notes
- Non-privileged tasks can be done exactly as described: RAM (valloc/fill loop), purgeable (CSDiskSpace* via `dlsym` from CoreServices), thin snapshots (`tmutil`), and Mail (sqlite `VACUUM` on Envelope Index plus `mdimport`).
- Privileged tasks need your own root helper (SMAppService daemon or `osascript ... with administrator privileges`). The suggested commands are [I/?] and come from external knowledge, not from this binary:
  - DNS: `dscacheutil -flushcache && killall -HUP mDNSResponder`
  - Spotlight: `mdutil -E /`
  - Permissions: `diskutil resetUserPermissions / <uid>` with a 1800 s timeout
  - Periodic: `periodic daily weekly monthly` on macOS < 14 only
