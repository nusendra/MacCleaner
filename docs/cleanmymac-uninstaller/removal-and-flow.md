# CleanMyMac 5 (MAS 5.7.1): how the Applications module removes apps

Source: static analysis only, arm64 slices. Ghidra pseudocode, Swift field metadata (`__swift5_fieldmd`), lazy-stub maps, and the en.lproj strings.
Address prefixes:
- AM = ApplicationsModule
- AMD = ApplicationsModuleDomain
- AT = ApplicationsTerminator
- US = UninstallerScanning
- SU = SharedUtils
- SOU = SharedObjcUtils
- ASRS = ApplicationSelfRemoverService
- CC = CleaningCore

Tags: **[O]** observed in code or data. **[I]** inferred. **[?]** unresolved.

Working files are in `$S/map/*.ann.c` (stub-annotated decompilations), `$S/uninst/*.fields` (type and field dumps) and `$S/uninst/strings/`.

---

## 0. TL;DR

- **Everything is deleted permanently. Nothing goes to the Trash.** The removal stack is built in AM `FUN_00011ccc`: CC `FileRemover(fileManager:)`, wrapped in `PrivilegedFileRemover(remover:privilegedAgent:authorizeAgentBlock:)` when a privileged performer exists, then in `ConfigDependentFileRemover(from: moduleConfig)`. `FileRemover.remove(at:)` calls `removeFileAndHandleLockAtPath:error:` (see caches.md). `MoveToTrashFileRemover` exists in CleaningCore, but only **OrganizeModule** imports it. ApplicationsModule, ApplicationsModuleDomain, UninstallerScanning and ApplicationSelfRemoverService never reference it, and none of them contains a trash or recycle string [O, `nm -m` across all frameworks].
- Every resource of a selected app becomes a **RemovalModel(node, remover, dependencies)**. The remover is picked by resource type (§1.3). Every remover is wrapped in `ConfigDependentRemover(throwIfFailCleanEnabled: true, debugRemover: DebugApplicationResourceRemover, realRemover: <specific>, removeAction: FUN_0001ba18)` [O AM `FUN_0003bbc8`].
- Running apps are not killed automatically. An `ApplicationDependency` per app bundle ID opens the **Terminator** sheet: Quit calls `terminate()`. After **5 s** a Force Quit button appears for that row, which calls `forceTerminate()`. Ignore continues without quitting [O AT `terminateAll@3194`, `FUN_0000368c`, `FUN_00004fb4`].
- **Mac App Store apps:** the app bundle gets `ExcludedBundleRemover`, which always throws "…cannot be removed with CleanMyMac due to Apple's restrictions for Mac App Store applications." The user is told to Reveal in Finder and trash it manually. The app's other files are still removed [O AM `FUN_0003bf38`, `FUN_0001b440`, `FUN_000319e8`].
- **CleanMyMac itself:** handled by `ApplicationBundleSelfRemover`, which calls `ApplicationSelfRemover.remove()`. That function invalidates the engine, unregisters login items, uninstalls the updater, uninstalls the privileged agent (2 s timeout), deletes the main bundle, deletes the logs directory, then calls `exit(0)` [O ASRS `remove@18a0`].

---

## 1. Removal

### 1.1 Remover stack (AM `FUN_00011ccc`, `ApplicationsScanningModelFactory`)
```
fileRemover  = FileRemover(fileManager: FileManagerProvider.shared)            // CC, permanent delete
if performerService != nil:
    fileRemover = PrivilegedFileRemover(remover: fileRemover, privilegedAgent: performer, authorizeAgentBlock: FUN_0001357c)
fileRemover  = ConfigDependentFileRemover(from: moduleConfig)                   // debug/"fake clean" switch
factory      = ApplicationRemovalTaskFactory(privilegedAgent, fileManager, fileRemover,
                    lazy unusedDiskImagesRemoval = UnusedDiskImagesRemoval(fileRemover),
                    moduleConfig, applicationSelfRemoverService)
```
[O: the calls and the factory fields]. In the MAS build the privileged helper may be missing. Receipt removal then fails with "A Privileged Agent isn't available." (AM `FUN_0001a890`, string @0x989c0) [O]. Root-owned files then fail with an ordinary delete error [I].

### 1.2 Building tasks per selected app (AM `FUN_0003acfc`, which is `ApplicationRemovalTaskFactory.makeTasks(resources, deps, isFromAppStore)`)
Callers: `FUN_000404fc` and `FUN_00043cf0` pass `app.isFromAppStore` as the third argument [O].

1. `FUN_0003aee8`: find the resource with `type == 4` (the app bundle) whose `bundleIdentifier == moduleConfig.mainBundleIdentifier` and whose `value == NSBundle.main.bundlePath` [O].
2. **Not CleanMyMac:**
   - If `!isFromAppStore`, call `FUN_0003b870`. It adds an `ApplicationDependency(bundleID)` (the "must be quit" dependency) for every resource that has a `bundleIdentifier`, then builds a RemovalModel per resource through `FUN_0003bbc8` [O].
   - If `isFromAppStore`, call `FUN_0003bf38`. Type-4 resources get `ExcludedBundleRemover(appName, bundleID)`. All other resources go through the normal per-type remover [O].
   - Tasks are assembled by `FUN_0003a9dc` [O].
3. **CleanMyMac:**
   - `FUN_0003a950` and `FUN_0003b0c4` drop resources under `/Library/PrivilegedHelperTools/` (string @0x991b0) and type `0x80` items, because the self-remover uninstalls the helper itself [O prefix check, I purpose].
   - The rest go through `FUN_0003bbc8`. A final `ApplicationBundleSelfRemover` task (`FUN_0003c420`) is added with `TaskPriorityKind.low`, so it runs last [O].
4. Each task is a `PostWaitApplicationResourcesRemovalTask` with these fields: `applicationNode`, `includeDeselectedNode`, `dependenciesResolver`, `makeWrapped`, `cancellationControl`, `executionLock`, `executionState`, `progressProxy`.
   - The task first waits for the app's background resource scan: `WaitOutcome {resourcesReady, categoryFinished, cancelled}` and `ApplicationCleanResourcesWaitState.isWaitingForResources` [O fields]. It then runs a `RemovalTask(dependencies, taskPriority, removalTaskError)` [O fields, I sequencing].

### 1.3 Remover per `CMApplicationResource.type` (AM `FUN_0003bbc8`, type switch) [O]

| type (bit) | group (from US `resourceTypeByPath` and strings) [I] | remover (class metadata) | action [O] |
|---|---|---|---|
| `0x1` | Preferences | `ApplicationPreferencesResourceRemover` (fileRemover, fileManager, `CMCFPrefsdManager`, `CMTaskRunner`) | see 1.4.a |
| `0x100` | Login Items (legacy, LSSharedFileList) | `ApplicationStartupItemResourceRemover` (`CMLoginItemsManager`) | `removeLoginItemAtPath:error:` (AM `FUN_0001b62c`) |
| `0x8000` | Login Items (SMAppService / launchd GUI job) | `ApplicationLoginItemResourceRemover` (`CMTaskRunner`) | see 1.4.c |
| `0x800` | Installers / package receipts | `ApplicationPackageReceiptResourceRemover` (`privilegedOperationsClient`) | privileged "forget receipt" call, synchronous (`AnyPublisher.syncResult`). No helper means the error "A Privileged Agent isn't available." (AM `FUN_0001a890`) |
| `0x1000` | Dock Icon | `ApplicationDockIconResourceRemover` (fileRemover, `CMResourceFetcherHelper`, `CMTaskRunner`) | see 1.4.b |
| `0x200` | Launch agents/daemons (`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`) | `FileApplicationResourceRemover`, with an **empty** dependency list | delete the plist. Unload happens through `LaunchAgentRemovalDependency` (1.4.d) |
| `4` | Applications (`.app`, `/usr/bin`, `/usr/local/bin` → Binaries) | `FileApplicationResourceRemover`, or `ExcludedBundleRemover` (MAS) / `ApplicationBundleSelfRemover` (CleanMyMac) | `fileRemover.remove(URL(fileURLWithPath: value))` (AM `FUN_0001c554`) |
| everything else (`0x20` Supporting Files, `8` Logs, `0x80` Plugins/PDFServices, `0x10000` kexts, `0x20000` Container, `0x4000` Other, crashes, user data, help, cookies…) | | `FileApplicationResourceRemover` | permanent delete |

The debug remover `DebugApplicationResourceRemover` only logs (category "ResourceRemover", AM `FUN_0001c2e8`). `ConfigDependentRemover` chooses debug or real from the module or debug config [O, I trigger].

### 1.4 Specific actions
a. **Preferences** (AM `FUN_0001abd0`):
- If the path does not exist, do nothing.
- If the extension is `lockfile`, just delete it.
- Otherwise, take the domain as the path itself (when it is a directory) or the path minus its extension, and run `/usr/bin/defaults delete <domain>`.
- Then call `CMCFPrefsdManager.setNeedsRelaunch(true)`. That runs `/usr/bin/killall -SIGTERM -u <user> cfprefsd`, at most once every 10 s, deferred with `dispatch_after` (SOU `setNeedsRelaunch:@6b0c`, `_forceRelaunchCFPrefsD@6c68`).
- Finally, delete the file through `fileRemover` [O].

b. **Dock icon** (AM `FUN_00018600`):
1. `record = CMResourceFetcherHelper.dockIconRecordForItemAtPath(path)`. If none is found, throw.
2. `/usr/bin/defaults export com.apple.dock $TMPDIR/com.apple.dock.tmp.<UUID>.plist`.
3. Load the plist and remove the matching tile from `persistent-apps` or `persistent-others`.
4. Write the plist back, then run `/usr/bin/defaults import com.apple.dock <tmp>`.
5. On success, run `/usr/bin/killall Dock` [O strings "export", "import", "com.apple.dock", "/usr/bin/killall", "Dock"; US `_withDockPersistentObjects:@6824`].

c. **SMAppService login item** (AM `FUN_00019f00`, `FUN_00019ffc`, `FUN_0001a508`):
1. Get the uid with `/usr/bin/env id -u $USER`, output trimmed.
2. Run `/usr/bin/env launchctl bootout gui/<uid>/<label>`.
3. A non-zero status throws "Failed to unload LoginItem at path …" [O].

d. **Launch agent dependency** (`LaunchAgentRemovalDependency{isFulfilled, bundleID, launchAgentUrl, launchdManager}`, AM `FUN_0001c8dc`):
1. For each dependency that is not yet fulfilled, call `CMLaunchdManager.unloadAgentAtPath(plist)`.
2. That runs `/bin/launchctl unload <plist>`, but only when the agent is loaded, and then `/bin/launchctl stop <label>` (SOU `_unloadAgentAtPath:shouldDisable:@7c70`).
3. The result is stored in `isFulfilled`. On failure the UI shows: `Launch Agent with bundle ID "%@" failed to unload.` [O].

e. **Unused DMG files / installers**: `UnusedDiskImagesRemoval(fileRemover)`, permanent delete [O fields].

### 1.5 Order of operations (one app) [O pieces, I overall sequence]
1. Wait for the app's resources to finish loading (PostWait).
2. Resolve dependencies:
   - `ApplicationDependency` (app must not be running; shows the Terminator)
   - `LaunchAgentRemovalDependency` (unload agents)
3. Run the per-resource removers in parallel or queued by priority. The only ordering that can be confirmed is that the self-remover task has low priority, so it runs last.
4. Unresolved dependencies give the task error "%@ could not be uninstalled for the following reasons:" (`UnresolvedDependenciesDependentTaskErrorMapper.uninstaller`, AM `0002b714`).
5. The final screen shows "Job done! … successfully uninstalled" or "Removal failed… Some application files were not removed. Please make sure you quit all of the related applications and try again." Leftover strings are analogous.

---

## 2. Quitting apps (ApplicationsTerminator + SU ApplicationTerminator)

- `ApplicationTerminator(workspace:, appTerminationAPI: NonSandboxApplicationTerminatorAPI)`. The MAS main binary also uses the NonSandbox API [O strings in the main exe].
  - `runningApplications`, `quitApplication(at bundleID)`: `NSRunningApplication.runningApplications(withBundleIdentifier:)` then `.terminate()` on each.
  - `forceQuitApplication(with bundleID)`: `.forceTerminate()` on each.
  - `listenForTermination(of:)`: a Combine publisher driven by KVO on `isTerminated` [O SU `166b4`/`16868`/`169c8`/`16fbc`/`16fc0`].
- `TerminatorViewModel{applications, subtitle, terminateAllEnabled, onAllApplicationsTerminated, onIgnore, bundleIDs, terminator, tracker}`.
  - Each row is a `RunningApplicationViewModel{isQuitAvailable, isQuitting, isForceQuitAvailable, onApplicationQuit, onApplicationForceQuit, model: MultiInstancesRunningApplication([NSRunningApplication])}`. Several instances of the same bundle ID are grouped into one row.
  - **Quit / Quit All** (`terminateAll@3194`, per row `FUN_0000368c`): set `isQuitting`, call `terminator.quitApplication(app)` on each instance, then `asyncAfter(now + 5.0 s)` sets `isForceQuitAvailable = true` (`FUN_00004fb4`). There is **no automatic force kill**. **Force Quit** (`FUN_00004ab8`) calls `forceQuitApplication(with: bundleID)`.
  - A row disappears once all its instances report `isTerminated`. When the list is empty, `onAllApplicationsTerminated` fires and cleanup continues [O, I flow].
  - **Ignore** / **Ignore and Continue** calls `onIgnore`. The app's removal then proceeds, or its dependency stays unresolved [I].
  - Texts: title "Some applications should be quit.", subtitle "Please quit the following applications to clean all of their related items:", buttons Quit, Quit All, Force Quit, Ignore, Ignore and Continue. The Updater uses "Please quit the following applications to update them:".
- `ApplicationCleanResourcesWaitState{lock, isWaitingSubject, _isWaitingForResources}` (AMD `68d0`–`6b2c`) is held in `ApplicationsTaskInfo.cleanResourcesWaitState`. It is true while a clean task waits for the app's background resource scan. Set and cleared in AM `FUN_00003ee0`, `FUN_0001f844`, `FUN_00023d4c`. The UI shows a waiting state [O setters, I UI].

---

## 3. Special uninstall paths

- **No vendor uninstallers or launchers are executed.** Steam, Battle.net and JetBrains Toolbox are only scan sources. US has `SteamApplicationFilter`, `BlizzardApplicationFilter`, `JetBrainsApplicationFilter` and the `*UninstallerApplicationsMapper` types.
- `CMSteamApplicationLauncher` detects `~/Applications/<game>.app` stubs whose `Contents/MacOS/run.sh` contains `open steam://run/` (US `isLauncherURL:@16a18`). `CMJetBrainsApplicationLauncher` detects launcher apps whose `Info.plist` has `JetBrainsToolboxApp` (US `@3e18`). These are added as **resources to delete** along with the game or IDE folder [O detection, I use].
- Resource fetchers: `fetchAllResourcesForSteamApplication:` (uses `steamapps`, `libraryfolders.vdf`, `appid`, `installdir`), `…ForBlizzardApplication:` (`Battle.net.config`, `DefaultInstallPath`, `net.battle.bootstrapper`), `…ForMobileApplication:` (iOS/iPad apps on Apple silicon; container and app bundle) [O strings].
- There are no "steam://uninstall" or vendor-uninstaller strings [O].
- **Audio plugins**: `UninstallerAudioPlugin` and `AudioPluginLoader` cover these formats: VST3, VST, MAS, Component, Driver, CLAP, LADSPA, LV2, AAX, RTAS, TDM. Roots are root, user and Avid plugin dirs. Plugins in a protected system path cannot be removed. The message reads: "This plugin is located in a protected system path and cannot be removed via CleanMyMac. You may reveal it in Finder and move to Trash manually." [O].
- **App Store apps**: the bundle is excluded (§0). The UI marks the app bundle not selectable (`FUN_00039b54`: a type-4 resource is selectable when `isRemovable && !isFromAppStore`). The cleanup popover offers a "Reveal in Finder" button [O].
- **Apps with their own uninstaller app**: no special handling was found [O absence].
- **Self-removal**:
  - Confirmation sheet: "Uninstalling CleanMyMac application". Body: "CleanMyMac is the application you are working with at the moment. It will be quit and completely removed after you click the Uninstall button. Would you like to uninstall CleanMyMac?" Buttons: Uninstall / Don't Uninstall.
  - `ApplicationSelfRemover.remove()` (ASRS `18a0`) runs these log steps in order:
    1. "Start CMM remove."
    2. "Invalidating panther": the engine-invalidate closure.
    3. "Unregistering all login items": `cleanMyMacLoginItemsManager`.
    4. "Uninstalling updater": optional `updaterRemover`.
    5. "Uninstalling agent": `deauthorizePrivilegedAgentAndWait(shouldUninstall: true, waitTimeout: 2.0)`.
    6. "Removing main bundle": `fileRemover.remove(bundleURL)`. The errors are `noMainBundle` and `failedToRemoveMainBundle`.
    7. `FileRemover.remove(logsDirectory)`, then `exit(0)` [O].

## 4. "Reset" an app
There is no separate Reset action or code path [O: no reset symbols other than cache resets]. Reset is implicit: the user selects the app's resources but not its bundle. `PostWaitApplicationResourcesRemovalTask.includeDeselectedNode` then controls whether the deselected app node is part of the task [O field, I semantics].

For protected or system apps the bundle resource is created with `removable = !isRestricted && !KB.isAppProtectedWithBundleId` (US `fetchAllResourcesForApplication:addAppBundleToResourceList:@7958`). The UI text is: "This is a protected system application file and it cannot be removed. However, you may remove related files to reset the application." In a reset, everything except the bundle is removed: prefs (`defaults delete` plus cfprefsd restart), containers, caches, support, logs, login items and agents.

## 5. Leftovers
- `LeftoversFetcher{systemInfo, workspace, knowledgeBase (buildForLeftovers), fileManager, fileSystemDataAccessor, associatedBundleIDsProvider (Info.plist AssociatedBundleIdentifiers), sharedApplicationTemplate, userApplicationTemplate}`. It produces `LeftoverCandidate{bundleID, name, sourcePath}` and then `LeftoverUninstallerApplication` [O fields]. It runs as a background scan: "Looking for App Leftovers…".
- Groups in `LeftoversScanResult`:
  - **Leftover Files**: "Preference and configuration files of previously uninstalled applications…"
  - **Installers / Unused DMG Files**
- Removal uses the same removal factory, so the same per-type removers apply (`LeftoversTilesMapper` holds `applicationRemovalTaskFactory`) [O].
- Default selection: tiles have `isAutoSelected`. Both `LeftoversResourcesLoadingBridge.applyAutoSelection` and `SimpleAutoSelectableStrategy` are used. The leftovers and installers tiles show **Remove**, which implies they are preselected. The Uninstaller and Unused tiles show **Review**, which implies apps are never preselected [I from tile buttons and Smart Care usage; exact predicate [?] lives in ModuleCore smart selection].

## 6. Safety rules
| rule | evidence |
|---|---|
| Apple or system apps: `UninstallerScanResult.systemApplications` is a separate list. `UninstallerKnowledgeBase.isSystemApplicationsIgnored`, `isAppProtectedWithBundleId`, and `isIgnoreOrSystemItemFileWithPath` come from the encrypted KB `info.cmmkb`. `ModuleConfig.Uninstaller.ignoredAppBundleIDs` / `uninstallerIgnoredAppBundleIDs` | AMD `13d58`–`146d8` [O] |
| Restricted (SIP) bundles are not removable (`isRestricted`) | US `@7958` [O] |
| "Suspicious" = `UninstallerApplicationCore.isAggressor` (KB `isAggressorBundleID`) | AMD `18790` [O] |
| Running apps must be quit first (`ApplicationDependency`), or the user picks Ignore | §2 |
| MAS apps: bundle excluded, manual Trash | §0 |
| Sandbox container items: `isInsideContainer` (path under `CMPaths.sandboxContainer`, type ≠ `0x20000`), `isInsideRootContainer` (parent dir equals container root). Without Full Disk Access, items inside the root container use `isRemovable` (`FUN_00034820`). A container root is selectable only when it has children (`FUN_00039b54`) | [O] |
| MAS sandbox access: builder takes `homeFolderSandboxAccessProvider` and `applicationsFolderSandboxAccessProvider`. Prompts: "Please grant access to your Home Folder to continue." / "…Applications Folder…" with a "Grant Access" button (security-scoped bookmarks) | AM builder init signature, main app strings [O] |
| Read-only volume or immutable file: no explicit check. A delete failure surfaces as a removal error. `FileRemover` clears lock flags | [I] |
| Protected plugin paths are not removable | strings [O] |
| Confirmations: only the self-uninstall dialog and the generic ModuleCore alerts ("Do you want to stop all currently running tasks?", "…go back and reset your selection?", "…start over?"). Ordinary app uninstall does **not** show a yes/no dialog; the footer button "Uninstall" starts it | [O strings, I absence] |

## 7. Module UX
- **Intro**:
  - Title "Applications". Subtitle "Take control of your applications. Uninstall, update or remove old application leftovers."
  - Three category tiles: App Uninstaller, App Updater, File Leftovers.
  - Custom flows exist for each: Uninstaller, App Leftovers, App Updater. `ApplicationsModuleConfig.Kind {module, customFlow, smartCare}`.
- **Scanning**: "Scanning application files…" / "Looking for applications, updates, and leftovers." with "Looking in %@" showing the current path. App resources and leftovers keep loading in the background after the list appears.
- **Results tiles**:
  - "Consider removing some applications" [Uninstall]
  - Unused Applications: "…haven't been used for over 6 months" [Review]
  - 32-bit Applications
  - "%@ of App Leftovers Found" [Remove]
  - "%@ of Installation Files Found" [Remove]
  - App Updates [Update]
  - "macOS Updates Are Available" [View Update]
- **Data manager (app list)**:
  - Filters:
    - All Applications
    - Unused: `isUnusedForSixMonths`, meaning `lastUsedDate < now − 6 months` via `Calendar.date(byAdding: .month, -6)` (AMD `18488`)
    - Suspicious
    - Selected
    - Vendors: Apple, Adobe, Google, JetBrains, MacPaw, Microsoft, Other
    - Stores: App Store, Steam, Battle.net, Setapp, Other
    - Plugins: Audio Plugins
  - Categories: Uninstaller, Leftovers (Leftover Files, Installers), Updater.
  - Search: "Search…". Empty result reads "Nothing found on "%@"".
  - Sort: Name, Size, Date, Items Count, Ascending or Descending, plus Last Opened and Last Updated (`LastOpenedSortableNode`, `LastUpdatedSortableNode`).
  - Select menu: Select All, Deselect All, Smartly, Largest, Smallest, Newest, Oldest. Context actions include "Add "%@" to Ignore List", with Undo as "Put Back".
  - Footer: "Uninstall" or "Remove", with selected size.
- **App detail**: resource groups Applications, Binaries, Container, Crashes, Dock Icon, Help, Installers, Login Items, Logs, Other, Plugins, Preferences, Supporting Files, User Data (`resource_group_*`), plus Cookies (image key). Each row has a size and a checkbox.
- **Cleaning**: "Uninstalling applications…" / "Removing leftovers…" / "Updating applications…". The Terminator sheet is shown when needed. The results screen has "Manage More Items" and an "Applications Log".
- **Updater**: same module (App Updater, `isUpdaterEnabled`, `isSystemUpdaterEnabled`). Not analyzed.

## 8. Config fields
- `ApplicationsModuleScanningConfig{uninstallerConfig, isUpdaterEnabled, isSystemUpdaterEnabled, isLeftoversEnabled, preScannedResults}`. `hasActiveTasks` is true when any of them is enabled (AMD `b028`) [O].
- `UninstallerConfig` enum: `all` | `disabled` | `customApps([URL])` [O]. Used by `uninstallAppsFlow(_ urls:, kind:, customDependenciesResolverFactory:)`, the external "uninstall these apps" entry point (AM `8d84`).
- `ModuleConfig{mainBundleIdentifier, appInfoServiceConfig, systemInfo: SystemConfig{osVersion, cpuArch, lang}, uninstaller: Uninstaller{ignoredAppBundleIDs}}`. `mainBundleIdentifier` is used to detect CleanMyMac itself [O].
- `ApplicationsScannerConfiguration{scanning, appInfoNetworkService, updaterScanningMetadata, isMASUpdaterScannerSupported, uninstallerIgnoredAppBundleIDs}` [O].
- `UninstallerScanningDebugConfig.backgroundResourcesLoadingDelay: Double?` (debug delay) [O].
- `ConfigDependentRemover.throwIfFailCleanEnabled = true`. The debug or real remover choice comes from module or debug config [O param, I source].

## Reimplementation notes
1. Delete permanently. Optionally offer Trash as an improvement, but CleanMyMac itself never trashes.
2. Classify each path into a type with `resourceTypeByPath` order (US `5d58`):
   1. `~/Library/Application Support` → `0x20`
   2. `.app`, `/usr/bin`, `/usr/local/bin` → `4`
   3. `Logs` → `8`
   4. `PDFServices` or a plugin extension → `0x80`
   5. LaunchAgents or LaunchDaemons → `0x200`
   6. kext → `0x10000`
   7. otherwise → `0x4000`
3. Before deleting:
   1. Quit the app: `terminate`, offer force-terminate after 5 s.
   2. `launchctl unload` and `stop` its agents.
   3. `launchctl bootout gui/<uid>/<label>` for SMAppService items.
   4. Remove LSSharedFileList login items.
   5. Run `defaults delete` on prefs, then `killall cfprefsd` (throttled to 10 s).
   6. Edit the Dock plist with `defaults export`/`import`, then `killall Dock`.
   7. Forget package receipts through the privileged helper.
4. Never delete MAS app bundles, SIP-restricted bundles or KB-protected bundles. Still allow deleting their data, which is the reset behavior.
