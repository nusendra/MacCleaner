# CleanMyMac 5 (MAS 5.7.1) – System Junk › Logs: behavioral spec

Static analysis only. Tags: **[O]** observed in code/data, **[I]** inferred, **[?]** unknown.
Addresses are image offsets. Unless prefixed, they are in `SystemJunkScanning`. Other prefixes: `SOU:` SharedObjcUtils, `LSC:` LegacyScanningCore, `JCM:` JunkCleanupModule, `CC:` CleaningCore.

---

## 0. Architecture at a glance

```
JunkCleanupModule (Swift)
  Tagged.userLogs   -> SystemJunkScanTasksFactory.userLogs(kb)        @3a288
  Tagged.systemLogs -> SystemJunkScanTasksFactory.systemLogs(kb, perf) @3a1f8   (NOT in sandbox build, see §6)
        |
        v  LegacyScanTaskWrapper<[LogsModel]>  (mapper FUN_0002d75c / FUN_0002d1c4)
CMUserLogsScanTask  (compound "CMSystemJunkScanIdentifierUserLogsCompound")   @11548
   ├─ CMLogsScanTask.userLogs        id ...UserLogs        provider CMUserLogsProvider
   ├─ CMLogsScanTask.sandboxLogs     id ...SandboxLogs     provider CMSandboxLogsProvider
   └─ CMLogsScanTask.quarantineLogs  id ...QuarantineLogs  provider CMQuarantineLogsProvider
CMSystemLogsScanTask (compound "CMSystemJunkScanIdentifierSystemLogsCompound") @113f0
   ├─ CMLogsScanTask.systemLogs      id ...LocalLogs       provider CMLocalLogsProvider
   ├─ CMLogsScanTask.appleLogs       id ...AppleLogs       provider CMAppleLogsProvider
   ├─ CMLogsScanTask.privateLogs     id ...DiagnosticLogs (sic) provider CMPrivateLogsProvider
   └─ CMLogsScanTask.diagnosticLogs  id ...DiagnosticLogs  provider CMDiagnosticLogsProvider   (only if allowPotentiallyUnsafe)
Removal: LogsRemover.removeLog(LogsModel) @385bc
```

## 1. Generic CMLogsScanTask algorithm [O]

`CMLogsScanTask::scan @fc78` with block `FUN_0000fe24`, `_entityAtURL: @10024`, `_logModelAtURL: @10344`, `_filterWithURL: @103dc`, `_fileSizeAtURL: @10468`.

1. `roots = provider.scanningPathsWithError()`. If it returns an error or the scan is cancelled, the result is empty.
2. For each root URL:
   - if `predicate.shouldIgnoreObject(root)`, skip it.
   - **Regular file:** emit one `CMLogModel(CMMLogItem(url), size = fileSize(url), autoselected = YES)`.
   - **Directory:** emit one `CMLogModel(CMMLogItem(dir), size 0, autoselected = YES)`. Its children come from a **recursive** `enumeratorAtPath:`. Sub-directories are skipped (only files become children), and each file child must also pass `!predicate.shouldIgnoreObject(child)`. If the directory ends up with **0 children, it is dropped**. The parent's size comes from its children [I].
3. Sizing: if `privilegedOperationsPerformer.isAuthorized`, use `performer.fileSizeAtURL:`. Otherwise use `CMByteSizer byteSizeAtURL:`. Only the private and diagnostic tasks are given a performer.
4. Every model is created with `autoselected = 1` (`@10344`, `@10024`).

### Predicate semantics (LegacyScanningCore) [O]
| Predicate | `shouldIgnoreObject` returns TRUE when | evidence |
|---|---|---|
| `CMFileNamePredicate.dsStore` | lastPathComponent == `.DS_Store` | LSC:1b44 / 1a0c |
| `CMFileSizePredicate(limit L)` | byteSize(path) **> L** | LSC:1c74 (`cmp; cset hi`) |
| `CMFileIsReachablePredicate` | file **is reachable/exists** (`checkResourceIsReachable`) | LSC:1814 |
| `CMFileIgnorePredicate(kb)` | `kb.isIgnoreItem(lastPathComponent / name / path)` | LSC:1550 |
| `CMFileAccessPredicate` | not a directory **and** `NSFileHandle fileHandleForUpdatingAtPath:` returns nil (not opened read-write) | `@13328`, `@133e0` |
| Compound type 0 NOT / 1 AND / 2 OR | NOT inverts. AND ignores only if every sub-predicate ignores. OR ignores if any sub-predicate ignores | LSC:dcc, 1034, 1080 |

## 2. Per-category table (reimplementation-ready)

`~` is the **real** user home. `CMPaths.userHome` (SOU:10ebc) uses `getpwuid()->pw_dir` when `APP_SANDBOX_CONTAINER_ID` is set, and `cmm_stringByExpandingTildeInPath` (SOU:5c68) does the same check [O].

| Category / factory (addr) | Scan id | Provider → roots (addr) | Root enumeration | Ignore predicate (OR of …) | Privileged sizing | LogType (§4) | In MAS build |
|---|---|---|---|---|---|---|---|
| userLogs `@10900` | `CMSystemJunkScanIdentifierUserLogs` | CMUserLogsProvider `@1307c` → children of `~/Library/Logs` (SOU userLogs @11d68 = userHome + `Library/Logs`) | each direct child (file or dir) of the folder becomes one item, recursive inside | dsStore; **NOT(size > 10240)** (so ≤10 KiB is ignored); KB ignore; not writable | no | crash if the name is `DiagnosticReports`/`CrashReporter`/`HangReporter`, else default | **yes** |
| sandboxLogs `@10abc` | `…SandboxLogs` | CMSandboxLogsProvider `@12bf8` / `FUN_00012ce4` → for each `~/Library/Containers/<X>`: children of `<X>/Data/Library/Logs` (flatMap) | same | same as userLogs (10 KiB) | no | default | **yes** |
| quarantineLogs `@10c78` | `…QuarantineLogs` | CMQuarantineLogsProvider `@12b28` → `CMQuarantine.downloadsLogsURLs @47aa0` = [`~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`, `~/Library/Preferences/com.apple.LaunchServices.QuarantineEvents`] | the 2 files | **NOT(exists AND size>0)**; KB ignore; not writable | no | quarantineLog | **yes** |
| systemLogs (local) `@10744` | `…LocalLogs` | CMLocalLogsProvider `@1255c` → children of `/Library/Logs` (SOU localLogs @11db4) | children, recursive | dsStore; ≤10 KiB; KB; not writable | no | crash for `DiagnosticReports` etc., else default | no |
| appleLogs `@1129c` | `…AppleLogs` | CMAppleLogsProvider `@12e6c` → [`/var/log/asl/`] (SOU aslLogs @11dcc) | one directory item, recursive | KB; not writable (**no size or .DS_Store filter**) | no | aslLog | no |
| privateLogs `@11034` | `…DiagnosticLogs` (reuses the diagnostic id; this looks like a bug) | CMPrivateLogsProvider `@12758` → base `/private/var/log` (SOU privateLogs @11de4). Roots = base + each of **11 known names** (`_knownPaths @12a40`, array @0x71de8), for example `system.log`, `install.log`, `wifi.log`, `fsck_apfs.log`, `fsck_hfs.log`, `daily.out`/`weekly.out`/`monthly.out`, `cups`, `DiagnosticMessages`. Plus each child of base whose name matches one of **2 regexes** (`knownPatterns @129c8`, @0x71dd0, case-insensitive): rotated archives `system.log.\d.gz`, `wifi.log.\d.bz2` | known names are listed blindly, then filtered | **NOT(exists AND size>10240)**; KB; not writable | **yes** | privateLog (path prefix `/private/var/log`) | no |
| diagnosticLogs `@10e78` | `…DiagnosticLogs` | CMDiagnosticLogsProvider `@123e4` → [`/private/var/db/diagnostics`] (SOU diagnosticsLogs @11e14) | one directory, recursive | KB; not writable | **yes** | unifiedLog | no (only when `allowPotentiallyUnsafe`, see §3) |

Notes:
- Only the providers return roots. Recursion is always the generic directory walk in §1 [O].
- `CMPaths.diagnosticsMessagesLogs` = `/private/var/log/DiagnosticMessages` (SOU @11e2c) is not used by any provider. That path is reached through the private known-names list instead [O].
- `CMXcodeDeviceLogsScanTask` (`@19464`, "iOS Device Logs") belongs to Xcode Junk and is out of scope.

## 3. Exclusions and safety

- **Size threshold:** items ≤ 10 240 bytes are skipped for the user, sandbox, local and private categories. The check applies to the root and to every file inside a directory. ASL and diagnostics have no size floor. Quarantine needs only size > 0 [O, constants `0x2800` and `0`].
- **Age threshold:** none. No date or modification-time predicate exists in any logs factory [O].
- **Open or locked files:** there is no "currently open" check. The only test is `CMFileAccessPredicate`, which ignores files that cannot be opened for read-write (permissions, SIP, immutable). Directories always pass that test [O].
- **Protected system logs:** for private logs, only the 11 known names and 2 rotated-archive patterns are eligible. Everything else in `/private/var/log` is never touched [O]. `.log` and `.txt` files are **truncated, not deleted** (§5), so live system/app log files keep their inode [O].
- **"Potentially unsafe":** `CMSystemLogsScanTask.systemLogsWithKnowledgeBase:privilegedOperationsPerformer:` `@113e8` always passes `allowPotentiallyUnsafeOperaionts = NO`. The only effect of that flag is to add `diagnosticLogsScanTask`, which wipes the unified-logging store `/private/var/db/diagnostics` [O]. The factory `SystemJunkScanTasksFactory.systemLogs @3a1f8` calls the 2-argument variant [O], so diagnostics are never scanned in shipping code. The reason (destroying `log show` history and tracev3 store integrity) is [I].
- **User ignore list:** `CMFileIgnorePredicate` delegates to `CMLogsKnowledgeBase` (ObjC protocol; `isIgnoreItem:`). JCM implements it as `LogsKnowledgeBaseWrapper isIgnoreItem:` JCM:3ab9c → `FUN_0003aba8`. That function first queries the KB service with the wrapper's scanner group/category (witness +0x10). If the item is not ignored, it queries again with a static category list (witness +0x38, static array with values 1 and 1000) [O structure / I semantics]. The KB is the KnowledgeBaseService *custom ignore items* store (strings `isCustomItemIgnored(for:categoryType:item:)`, `userLogs`, `systemLogs`) [I].

## 4. Model and naming

`CMMLogItem initWithURL:… @11808`, `_fetchType @11c18`, `name @11a48`, `displayName @11b30`.
- `rawName` = lastPathComponent of the path with its "real" extension removed. `identifier` = rawName [O].
- `type` is checked in this order [O]:
  1. rawName ∈ {CrashReporter, HangReporter, DiagnosticReports} → 2 crashLog
  2. url ∈ downloadsLogsURLs → 3 quarantineLog
  3. url == `/private/var/db/diagnostics` → 5 unifiedLog
  4. url == `/var/log/asl/` → 4 aslLog
  5. path hasPrefix `/private/var/log` → 1 privateLog
  6. otherwise 0 default
- Swift `LogsModel.LogType` cases: `default, privateLog, crashLog, quarantineLog, aslLog, unifiedLog` (reflection strings) [O].
- `name` and `displayName`: for types 4 and 5, use rawName. Otherwise treat rawName as a bundle id and resolve the app via `NSWorkspace absolutePathForAppBundleWithIdentifier:` to get the app's (display) name, falling back to rawName [O]. Example: `~/Library/Logs/com.foo.Bar/` is shown as "Bar".
- Mapper `FUN_0002d1c4` builds `LogsModel{type, name = displayName, url, additionalFiles = [child URLs], identifier, size, isAutoselected}` from each top-level `CMLogModel`. A type > 5 traps [O].

## 5. Auto-selection

Every log item in every category is created with `autoselected = YES` (`initWithValue:size:autoselected:1`), and the mapper copies that value [O]. No per-category opt-out was found in the scanning layer. A UI or smart-select override in ModuleCore is [?].

## 6. Removal: `LogsRemover.removeLog @385bc`

Dispatch by `LogsModel.type` (acts on `model.url` only) [O]:

| type | action |
|---|---|
| 0–3 (default, private, crash, quarantine) | `FUN_00038940`: if `fileExists(url.path)` and `url.pathExtension.lowercased() ∈ {"log","txt"}`, then **truncate** with `FileManagerProvider.truncateFile(at:)` (`FUN_00038e40`). On failure, retry through the privileged agent: FileSystem protocol witness +0x18, presumed truncate [I]. Otherwise **delete** with `fileRemover.remove(at:)` (`FUN_00039114`). On failure, retry through the privileged agent: FileSystem witness +0x10, presumed remove [I]. A missing file counts as success. |
| 4 aslLog | requires `privilegedAgent` (otherwise throws `emptyPrivilegedAgent`) and `authorizeAgentBlock()`. If authorization is refused, throws `notAuthorizedPrivilegedAgent` and logs "LogsRemover". Then calls `LogsPrivilegedOperationsClientType` requirement #2 (witness +0x10) [O dispatch, I meaning: privileged ASL wipe]. |
| 5 unifiedLog | same gate, then `LogsPrivilegedOperationsClientType` requirement #1 (witness +0x8) [O dispatch, I meaning: privileged unified-log purge]. The protocol has exactly 2 requirements (POPS descriptor @48ec) [O]. |

- Errors: `RemoverError {couldNotRemove, emptyPrivilegedAgent, notAuthorizedPrivilegedAgent}` [O, reflection strings plus `*err = 0/1/2`].
- `fileRemover` is CleaningCore `FileRemover.remove(at:)` CC:9c20 → `removeFileAndHandleLockAtPath:error:`. This is a **permanent delete** (clears the lock flag), **not Trash** [O selector, I semantics]. JCM wraps it in `PrivilegedFileRemover` and `ConfigDependentFileRemover`, and wraps logs in `ConfigDependentLogsRemover(throwIfFailCleanEnabled:debugRemover:realRemover:)`. This looks like a debug/QA dry-run switch [I].
- Directories (for example `~/Library/Logs/SomeApp/`) have no `.log` extension, so the **whole folder is deleted**, including small or unreadable files the scan had filtered out. Whether the UI removes individual `additionalFiles` children on partial selection is [?].
- Quarantine: the two **SQLite DB files are deleted whole**. Their extensions are `QuarantineEventsV2` and `QuarantineEvents`, not log/txt [O]. No rows are deleted, and `-wal`/`-shm` side files are not targeted [O]. `CMQuarantine.entries` (`SELECT * FROM LSQuarantineEvent`, FMDB, 11 `LSQuarantine*` columns → `CMQuarantineEntry`) and `removeQuarantineAtPath:` (`removexattr("com.apple.quarantine", XATTR_NOFOLLOW)`) exist, but **no callers exist in any framework** (the selector string appears only in SystemJunkScanning) [O]. Quarantine **xattrs are not removed** by Logs cleanup.
- Privileges: user, sandbox and quarantine logs need only user rights (plus TCC/Full Disk Access for `~/Library/Containers`) [I]. ASL and unified always need the helper. Private and local logs need it only when the unprivileged delete or truncate fails [O].

## 7. Identifiers, grouping and presentation

- CFString ids (value == name) [O]: `CMSystemJunkScanIdentifierUserLogs`, `…SandboxLogs`, `…QuarantineLogs`, `…LocalLogs`, `…AppleLogs`, `…DiagnosticLogs` (used by **both** private and diagnostic), `…UserLogsCompound`, `…SystemLogsCompound`.
- JCM tags: `Tagged.userLogs` ↔ `UserLogsCompound` (JCM:2a684); `Tagged.systemLogs` ↔ `SystemLogsCompound` (JCM:2a6b4) [O].
- Titles: localization key `system-junk_user-log-files` (default "User Logs") and `system-junk_system-log-files` (default "System Logs"), from `JunkCleanupSystemJunkScanTaskInfo.info` JCM:379f8 [O].
- **Sandbox gating:** `Tagged.systemJunkGroupForEnvironment(isSandbox:)` JCM:29d88 always includes `userLogs`. `systemLogs` is in the second group, which is replaced by `[]` when `isSandbox` [O]. JCM imports only `SystemJunkScanTasksFactory.userLogs(knowledgeBase:)`, not `systemLogs` [O]. **The MAS build therefore scans and cleans only User Logs (user + sandbox + quarantine).**
- Within a group, items are the top-level `LogsModel`s (one per log file or per app log folder), and folder children are carried in `additionalFiles` [O]. Sort order and UI sub-grouping are [?].

## 8. Minimal reimplementation pseudo-code

```
SMALL = 10240
def walk(root, ignore):
    if ignore(root): return None
    if isfile(root): return Item(root, size(root), auto=True)
    kids = [f for f in rglob_files(root) if not ignore(f)]
    return Item(root, sum(size(k) for k in kids), auto=True, children=kids) if kids else None

user_ignore = lambda p: name(p)==".DS_Store" or size(p)<=SMALL or user_ignored(p) or not rw_openable(p)
roots_user       = ls("~/Library/Logs")
roots_sandbox    = flat(ls(c/"Data/Library/Logs") for c in ls("~/Library/Containers"))
roots_quarantine = ["~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2",
                    "~/Library/Preferences/com.apple.LaunchServices.QuarantineEvents"]
quar_ignore = lambda p: not(exists(p) and size(p)>0) or user_ignored(p) or not rw_openable(p)
# non-sandbox only: /Library/Logs/*, /var/log/asl/, /private/var/log/{known names + rotated regexes}

def remove(item):
    if item.type in (ASL, UNIFIED): helper_required()
    elif exists(item.url):
        if ext(item.url).lower() in ("log","txt"): truncate(item.url)   # fallback: helper
        else: delete_permanently(item.url)                             # fallback: helper
```
