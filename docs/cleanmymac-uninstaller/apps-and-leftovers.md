# CleanMyMac 5 (MAS 5.7.1): App discovery and Leftovers detection

Static analysis of `ApplicationsService`, `UninstallerScanning`, `ApplicationsModuleDomain`, `ApplicationsModule`, `KnowledgeBaseService`.
Tags: **[O]** observed directly in decompiled code or data. **[I]** inferred from call shapes, names or strings. **[?]** uncertain.
Addresses are image offsets in the thin arm64 binaries. ApplicationsService is abbreviated `AS`, UninstallerScanning `US`, ApplicationsModuleDomain `AMD`.
CFString and Swift-literal values were decoded from the binaries; decoder scripts are in `scratchpad/ua/`.

---

## A. App discovery (ApplicationsService, ObjC)

### A.1 Pipeline
1. `CMSystemInfo.sharedInstance` → `initWithSystemApplicationsProvider:` (AS 0x732c) installs a `CMSystemInfoDispatcher` (it has separate serial queues for applications, plugins, prefPanes, scriptingAdditions, resources and systemReceipts), the provider, and `applicationBundleIdentifierPrefixesToIgnore`. That list is a constant array at AS 0x198d8 **[O]**:
   `com.parallels.winapp`, `com.parallels.ApplicationGroupBridge`, `com.vmware.proxyApp`, `com.codeweavers.CrossOverHelper`, `com.google.Chrome.app.` (Chrome PWAs), `com.setapp.teaser`.
2. `preloadData` (AS 0x73d4) runs `_findAllApplications` and `_findAllPlugins` asynchronously when they are not cached yet **[O]**. Every public getter (`allFilteredApplications`, `userApplications`, `systemApplications`, `scannedApplications`, `mobileApplications`) does a sync dispatch that triggers `_findAllApplications` if the result is not cached (AS 0x7864–0x7f0c) **[O]**. The `*ForceUpdate:` variants reset the cache first **[I]**.
3. `_findAllApplications` (AS 0x8098) **[O]**:
   - Spawns an `NSThread` named `com.macpaw.findAllApplications` with QoS 0x21 (userInteractive), runs `systemApplicationsProvider.findAllApplications`, and waits on a semaphore.
   - `scannedApplications` (ivar 0x30) = the results cast to `CMApplicationInfo` (block 0x83ec).
   - `mobileApplications` (ivar 0x50) = the results cast to `CMMobileApplicationInfo` (block 0x83fc).
   - `allFilteredApplications` (0x38) = scanned apps whose `bundleID` has **no** prefix in the ignore list (block FUN_840c, using `hasPrefix:`).
   - `systemApplications` (0x48) = filtered apps where `isSystemApp` is true (FUN_8534).
   - `userApplications` (0x40) = filtered apps where `+[CMApplicationInfo isUserAppAtPath:]` is true **or** the path ends with `/Library/Application Support/Setapp/LaunchAgents/Setapp.app` (FUN_853c).
4. `CMSystemApplicationsProvider._findAllApplications_Sandboxed` (AS 0xac6c) enumerates exactly two roots **[O]**: `/Applications` and `/System/Applications`. It does **not** search `~/Applications` and does not use Spotlight. LaunchServices is used only by `applicationByBundleID:`, below.
   `_createApplicationsArrayInPathDeep:` (AS 0xad0c) **[O]**:
   - Uses `NSFileManager enumeratorAtPath:`, which recurses, so subfolders such as `/Applications/Utilities` and vendor folders are included.
   - For each entry that is a directory with extension `app`, it calls `skipDescendents`. Apps nested inside another `.app` are therefore never listed.
   - Creates the object with `[[CMApplicationInfo alloc] initWithPath:]`. If that returns nil **and** `CMSystemArchitecture.isAppleSilicon`, it tries `[[CMMobileApplicationInfo alloc] initWithURL:]` (iOS/iPadOS wrapper apps).
   - No de-duplication is done **[O]**. Equality is `bundleID` equal **and** `path` equal, and `hash` uses `bundleID` and `path` (AS 0x1c38/0x1dac) **[I]**.
5. Lookups:
   - `applicationByPath:` (AS 0x8778) returns the first scanned app whose `path` is equal (`cmm_first`), otherwise `[[CMApplicationInfo alloc] initWithPath:]` **[O]**.
   - `applicationByBundleID:` (AS 0x8a50) returns the first app with an equal `bundleID`, otherwise `NSWorkspace URLForApplicationWithBundleIdentifier:` followed by `initWithURL:` **[O]**.
6. `isApplicationBundleIdentifierIgnored:` (AS 0x85dc) takes a **path**. It returns true when `CMBundleValidator isValidApplicationAtPath:` fails, or when the bundle's `CFBundleIdentifier` has an ignored prefix **[O]**.

### A.2 Bundle validation (`CMBundleValidator`, AS 0xcc6c–0xcf10) **[O]**
`_validateOfBundleWithPath:extension:` passes when **all** of these hold:
- the path extension contains the expected extension (case-insensitive `rangeOfString`)
- `<path>/Contents/MacOS` exists
- `<path>/Contents/Info.plist` exists

Expected extensions by validator:

| Validator | Extension |
|---|---|
| app, Steam app | `app` |
| plugin | `plugin` |
| prefPane | `prefPane` |
| scripting addition | `osax` |
| widget | contains `wdgt`; only the extension is checked |

`CMMobileApplicationBundleValidator` (AS 0xda08) requires the `app` extension plus `Wrapper/BundleMetadata.plist` and `Wrapper/iTunesMetadata.plist`.

### A.3 `CMApplicationInfo` properties (lazy, cached, guarded by `@synchronized` and a bit-flag word at +8)

| Property | Computation | Evidence |
|---|---|---|
| init | nil unless `isValidWithPath:` (the bundle validator) passes | 0x1a08 [O] |
| `bundleID` | `Info.plist[CFBundleIdentifier]` trimmed of whitespace; empty → nil | 0x21fc [O] |
| `name` | `CFBundleName` if it is an NSString, else the last path component without extension | 0x2358 [O] |
| `displayName` | `NSFileManager displayNameAtPath:` | 0x22c4 [O] |
| `version` | `CFBundleShortVersionString`, else `CFBundleVersion` | 0x2ef8 [O] |
| `minOSVersion` | `LSMinimumSystemVersion` | 0x2f8c [O] |
| `isSystemApp` | `path hasPrefix:@"/System/Applications"` | 0x2770 [O] |
| `isRestricted` | `[fileManager isFileRestricted: infoPlistPath]` (a FileManager category outside these binaries; probably the SIP `SF_RESTRICTED` flag) | 0x26c0 [O]/[I] |
| `isSandboxed` | `SecStaticCodeCheckValidityWithErrors` against requirement `entitlement["com.apple.security.app-sandbox"] exists` | 0x25dc [O] |
| `isFromAppStore` | `<path>/Contents/_MASReceipt/receipt` is reachable | 0x2ffc/0x33e8 [O] |
| `store` | 2 if `isSetappApp`; else 1 if from the App Store; else 0 | 0x3134 [O] |
| `isSetappApp` | `bundleID hasSuffix:@"-setapp"` | 0x27fc [O] |
| `isSetappMainApp` | bundleID contains `com.setapp.DesktopClient` | 0x2888 [O] |
| `vendor` | `CMApplicationVendorProvider vendorForBundleID:` | 0x3084 [O] |
| `lastUsedDate` | `[fileManager lastAccessDateAtPath:path]`, falling back to `[NSDate date]` (so a missing date counts as "now") | 0x2954 [O] |
| `usedDates` | `MDItemCopyAttribute(MDItemCreate(path), kMDItemUsedDates)` as an NSArray | 0x2c4c [O] |
| `securityApplicationGroupIdentifiers` | `SecCodeCopySigningInformation` with flag 4 (entitlements) → `com.apple.security.application-groups` | 0x2d10 [O] |
| `privilegedExecutables` | keys of `Info.plist[SMPrivilegedExecutables]` | 0x2e60 [O] |
| `sandboxContainerPath` | `~/Library/Containers/<bundleID>/Data`, using `CMPaths` | 0x2508 [I] |
| `binaryPath` | `/Contents/MacOS/<CFBundleExecutable>` | 0x2448 [I] |
| `isRunning` | some `NSWorkspace.runningApplications` entry has `bundleURL.path` equal to `path` | 0x2ac0 [O] |
| `isInLoginItems` / `isInSMLoginItems` | path is in `validLoginItemsList`, or `SMCopyAllJobDictionaries` has a `Label` equal to a helper's `CFBundleIdentifier` (helpers in `Contents/Library/LoginItems`) | 0x3994 [O] |
| `isAgent` | `LSUIElement` is true | 0x3c14 [O] |
| `isSupportAppleScript` | `OSAScriptingEnabled` or `OSAScriptingDefinition` | 0x31bc [I] |
| `isSupportDeepLinks` | `CFBundleURLTypes` | 0x330c [I] |
| `archs` / `is32BitsOnly` | `NSBundle executableArchitectures` | 0x34a8/0x3540 [I] |
| `isCodesigned` / `isValidSignature` | `_CodeSignature` present plus a SecStaticCode check; exceptions are treated as signed | 0x35d8/0x3860 [I] |
| `signedWithAgressorCountryCertificate` | `CMCodeSigning(url).countriesFromCertificatesChain` contains `"ru"` | 0x2a14 [O] |

Bug to note: `isRestricted` and `isSystemApp` cache their results in the **same** byte (+0xe), so whichever is read second returns the first one's value **[O]**. A reimplementation should keep them as separate fields.

Init by bundle ID: `initWithBundleID:appName:` (AS 0x548c/0x5568) **[O]** sets only `bundleID` and `name`, with no path or validation. Leftover "apps" are built this way.

### A.4 `CMCodeSigning` (AS 0xd464–0xd854)
- `_fetchSigningInfoIfNeeded`: `SecStaticCodeCreateWithPath` then `SecCodeCopySigningInformation(flags=2 = kSecCSSigningInformation)` **[O]**.
- `teamId` = `kSecCodeInfoTeamIdentifier` **[O]**.
- `bundleId` = `kSecCodeInfoIdentifier` **[O]**.
- `certificatesChain` = `SecCertificateCopyCommonName` for each `kSecCodeInfoCertificates` entry **[O]**.
- `countriesFromCertificatesChain` returns a set of country codes (the decompile is truncated; probably the subject `C=` field) **[I]**.

### A.5 `CMApplicationVendorProvider` (AS 0xc9f4)
For vendors 1…6 in order, the first case-insensitive `hasPrefix` match on the bundle ID wins. 0 means no vendor **[O]** (tables at 0x19908/0x18570):

| Value | Vendor | Bundle ID prefixes |
|---|---|---|
| 1 | Apple | `com.apple`, `developer.apple.` |
| 2 | Microsoft | `com.microsoft.`, `com.skype.`, `com.followanalytics.adventureworks.msdc365` |
| 3 | Adobe | `com.adobe`, `adobe.` |
| 4 | Google | `com.google.` |
| 5 | MacPaw | `com.macpaw`, `com.setapp`, `cx.c3.xee3`, `cx.c3.theunarchiver`, `cx.c3.thearchivebrowser` |
| 6 | JetBrains | `com.jetbrains`, `org.jetbrains`, `com.kotlinconf.iosapp` |

The names are inferred from the prefixes **[I]**.

### A.6 User app vs. ignored path (regexes, case-insensitive; AS 0x5324 / 0x522c)
`isUserAppAtPath:` returns **NOT** a match of the regex below. `%@` is the tilde-expanded `~/Library` **[O]**:
```
^(/net)|^(/tmp)|^(/var)|^(/cores)|^(/private)|^(/opt(?!/homebrew-cask/Caskroom))|^(/dev)|^(/sbin)|^(/bin)|^(/etc)|^(/usr)|^(%@)|^(/Library)|^(/System)(?!.*Finder\.app)|^(/Developer)|^(/Applications/Developer Tools)|^(/Volumes)|.+(\.app/).+|.+(\.pvm).*|.+(\.vmwarevm).*|.+/(.*\.)(?![0-9]+[a-zA-Z]*)(?!localized).+/.+\.app
```
- Result: everything under `/System/Applications` (except Finder) and any nested `.app` is **not** a user app.
- `shouldIgnoreAppAtPath:` returns true when the path matches `.+(\.pvm).*|.+(\.vmwarevm).*|.+(\.backupdb).*` **or** `CMDropboxFilter isItemFilteredAtPath:` is true **[O]**.

### A.7 Mobile (iOS-on-Apple-silicon) apps (`CMMobileApplicationInfo`, AS 0x5724–0x67cc) **[O]**
- Info.plist is read from `<app>/WrappedBundle/Info.plist`.
- `isFromAppStore` is always true. `store` is always 1.
- `lastUsedDate` uses `lastAccessDateAtPath` with no fallback.
- `sandboxContainerPath`:
  1. Look up `CMApplicationsContainerStorage.allBundleIDsAppropriateToContainers[bundleID]`.
  2. If missing, use `~/Library/Containers/<bundleID>`.
  3. Append `Data`.
- `CMApplicationsContainerStorage` (AS 0x6c3c) builds `bundleID → containerURL` once, on serial queue `CMApplicationsContainerStorage.allBundleIDs`. For each URL in `~/Library/Containers`, it reads `<url>/.com.apple.containermanagerd.metadata.plist` → `MCMMetadataIdentifier` (non-empty). This is needed because iOS app containers are named with UUIDs.

### A.8 Other system item providers **[O]**
| Provider | What it collects |
|---|---|
| `CMSystemPrefPanesProvider` (0xbd54) | Contents of `userPrefPanesURL` plus `allUsersPrefPanesURL` (`~/Library/PreferencePanes`, `/Library/PreferencePanes`) [I paths], wrapped in `CMPrefPaneInfo initWithURL:`. Validity: extension `prefPane`. |
| `CMSystemScriptingAdditionsProvider` (0xc4f8) | User plus all-users `ScriptingAdditions` directories, `osax` bundles. |
| `CMSystemPluginsProvider.findAvailablePlugins` (0xb104) | For each pair (localized category name, path constant imported from another framework), enumerates `path` and `~/path` recursively. An item is a plugin if its extension is in {`plugin, webplugin, component, bundle, mdimporter, qlgenerator, mailbundle, service, workflow, osax`} (0x198f0) **or** `NSWorkspace isFilePackageAtPath:` is true; the enumerator then skips its descendants. `name` = file name without extension. Categories: QuickTime, Safari/Internet Plug-Ins, QuickLook, Finder, Spotlight, InputManagers, iTunes, Address Book, Screen Savers, Mail (`CMPaths.mailPluginsURL`), Services, Scripting Additions, Color Pickers (`/Library/ColorPickers`, extension `colorpicker`). |
| `CMSystemPreferencesProvider` | `userPreferences` (`~/Library/Preferences`), `localPreferences` (`/Library/Preferences`), `userSandboxContainers` (`~/Library/Containers`): shallow listings with option 4 = skip hidden files. |
| `CMSystemReceiptsProvider` | `/private/var/db/receipts` (`CMPaths.systemReceiptsURL`). |
| `CMSystemInfo.allPreferencesNames` (0x9684) | Lowercased base name of each `.plist` file → URL. |

---

## C. Leftovers: files of apps that are no longer installed (US `LeftoversFetcher`)

Entry point: `LeftoversFetcher.fetchLeftovers() -> [CMApplicationInfo]` (US 0x1f97c). Its helper is FUN_0001fc04.
Fetcher fields (from use):

| Offset | Field |
|---|---|
| +0x10 | `CMSystemInfo` |
| +0x18 | `Workspace` existential |
| +0x40 | leftovers knowledge base (`UninstallerKnowledgeBase`, built via `UninstallerKnowledgeBaseFactory.buildForLeftovers(isSystemApplicationsIgnored:)` @ AMD 0x13c10) |
| +0x48 | `NSFileManager` |

Inferred from call sites **[I]**.

### C.1 Algorithm
```
installedApps = systemInfo.allFilteredApplications            // /Applications + /System/Applications, minus ignored prefixes
              + systemInfo.plugins + systemInfo.scriptingAdditions + systemInfo.prefPanes
              + audio plugins (AudioPluginsDirectoryProvider)  // FUN_00021130 / FUN_00021464  [O]
installedIDs  = installedApps.compactMap { $0.bundleID?.lowercased() }   // FUN_000200e8  [O]

candidates  = containerCandidates(installedIDs)                // FUN_00020294  [O]
candidates += preferenceCandidates(installedIDs)               // FUN_00020924 → FUN_0001fed0  [O]
candidates  = uniqued(candidates, by: bundleID)                // FUN_0001fc04 + Set.insert FUN_00037730; first wins (containers before prefs)  [O]/[I]

result = []
for c in candidates where !kb.isAppIgnored(bundleId: c.bundleID) {          // [O] 0x1f9d0
    let app = CMApplicationInfo(bundleID: c.bundleID, appName: c.name)        // no path validation
    app.path = c.path                                                         // the orphaned file or container path [O]/[I]
    result.append(app)
}
```
`LeftoverCandidate` (a type named in US strings) is a 0x30-byte struct holding 3 Strings: `bundleID`, `name`, `path` **[O]**/**[I]**.

### C.2 Sources enumerated (only these two; shallow listings)
1. **Sandbox containers**: `systemInfo.userSandboxContainers`, i.e. a shallow listing of `~/Library/Containers` without hidden files (FUN_00020294) **[O]**. For each container URL:
   - Read the original app bundle path. **[O]** for the strings, **[I]** for the nesting:
     - First source: `<container>/.com.apple.containermanagerd.metadata.plist` → `MCMMetadataInfo` → `SandboxProfileDataValidationInfo` → `SandboxProfileDataValidationParametersKey` → `application_bundle` (FUN_00021678).
     - Fallback: `<container>/Container.plist` with the same key path (FUN_00021a80).
   - If a path was found **and** `fileExistsAtPath(path)` → the app is installed → skip **[O]**.
   - Otherwise check `Workspace.urlForApplication(withBundleIdentifier:)` (LaunchServices). If an app is found → skip **[I]**.
   - Otherwise build a candidate with `makeCandidate(containerURL)` (C.3).
2. **Preference files**: `systemInfo.userPreferences`, i.e. a shallow listing of `~/Library/Preferences` (FUN_0001fed0) **[O]**.
   - Keep only extension `plist` or `xml` (static array at US 0x62640) **[O]**.
   - Turn the kept URLs into a Set, then `makeCandidate(url)` for each (FUN_00020924) **[O]**.
   - Nothing else is enumerated for discovery: no Application Support, Caches, Group Containers or LaunchAgents. Those folders are only searched **afterwards**, when the leftover app's resources are loaded (C.5).

### C.3 `makeCandidate(url)` (FUN_00020b94) decides "belongs to no installed app"
1. `id = url.lastPathComponent.deletingPathExtension`. Reject it unless `id.lowercased()` contains `"."`, i.e. it looks like reverse-DNS (FUN_00022f00) **[O]**.
2. Reject if `Workspace.urlForApplication(withBundleIdentifier: id)` returns an app, meaning LaunchServices knows it **[O]** (call to `Workspace.urlForApplication` + `==`).
3. Build the set of **ID variants** (FUN_0001f5d8, FUN_0001f0b4, FUN_0001f36c) **[O]** strings, **[I]** exact control flow:
   - the original `id`
   - if the first dot component is exactly **10 letters/digits** (a Team ID such as `ABCDE12345.com.foo`), the ID with that component removed
   - if it starts with `group.` or `maccatalyst.`, the ID with that prefix removed
   - parent ID by dropping the last component, but only when there are more than 3 components and the last component is in the helper-suffix list (US 0x622b0, 22 items): `updater, helper, agent, service, launcher, preferences, preference, accounts, settings, config, mail, calendars, contacts, keychains, extension, widget, menu, fileprovider, findersync, macos, mac, ios`. The last component also counts if it *ends with* `extension` or `service` and is longer than that word + 3 (US 0x62440).
   - plus `kb.bundleIDsForFileURL(url)`: KB mapping of a file to owner bundle IDs (`KnowledgeBaseScannerService.bundleIDsForApplication(fileURL:)`) **[O]**/**[I]**.
4. **Installed match** (FUN_00023138) **[O]**: for each installed ID and each variant, lowercase both and strip spaces and `-`. If `variant.hasPrefix(installed)` **or** `installed.hasPrefix(variant)` → the file belongs to an installed app → reject. This is a prefix match in both directions, so `com.foo.app.helper` matches installed `com.foo.app`, and `com.foo` matches installed `com.foo.app`.
5. `name = kb.applicationNameFor(id)`, a KB lookup that may be nil **[O]**.
6. **Name-based installed check** (FUN_00021dfc) **[O]**. Build names to try:
   - `id.pathExtension`, i.e. the last dot component (`com.foo.Bar` → `Bar`), or the whole `id` if there is none
   - the KB `name`, if there is one

   For each name, check `fileExists("/Applications/<name>.app")` and `fileExists(expandTilde("~/Applications/<name>.app"))`. These are `LeftoversFetcher.sharedApplicationTemplate` / `userApplicationTemplate` (US 0x1d600/0x1d61c). If either exists → reject. **This is the only place `~/Applications` is considered.**
7. Reject if `kb.isIgnoreOrSystemItemFileWithPath(url.path)` (AMD 0x146d8 → FUN_0001459c) **[O]**. It is true if any of these KB checks hits:
   - two custom-ignore lookups, (cat 1, type 4) and (cat 1001, type 0)
   - the KB path-ignore check
   - the "system item at path" check

   **[I]** for which witness is which.
8. Otherwise return `LeftoverCandidate(bundleID: id, name: name ?? id, path: url.path)` **[O]**/**[I]**.

### C.4 Exclusions summary
| Exclusion | Where it applies | Evidence |
|---|---|---|
| Not reverse-DNS-like (no `.`) | dropped | C.3 step 1 [O] |
| LaunchServices knows the bundle ID | dropped | C.3 step 2 [O] |
| Prefix-match against installed app, plugin, osax, prefPane or audio-plugin IDs | dropped | C.3 step 4 [O] |
| `/Applications/<Name>.app` or `~/Applications/<Name>.app` exists | dropped | C.3 step 6 [O] |
| KB "ignore or system item" path | dropped | C.3 step 7 [O] |
| KB `isAppIgnoredWithBundleId` | dropped at the end | AMD 0x13dec [O] |

`isAppIgnoredWithBundleId` is true if any of these hits: custom ignore (cat 0, type 3), custom ignore (cat 1000, type 13), or the KB ignore-by-identifier witness.

No hard-coded `com.apple.*` filter exists in the leftovers code. Apple items are expected to be filtered by:
- the KB system or ignore lists
- step 2 (Apple apps are registered with LaunchServices)

**[I]**

### C.5 Turning candidates into UI items
- `LeftoverUninstallerApplicationMapper.mapToApplications(from:)` (US 0x29708) **[O]** wraps each `CMApplicationInfo` in `LeftoverUninstallerApplication` with:
  - `appInfo` set to that object
  - `isSystem = false`, `isAggressor = false` (two zero bytes at +0x18)
  - an empty resources `Set`
  - an `NSLock`
  - `loaded = false`
- `UninstallerScanTaskFactory.leftoversDiscoveryTask()` (US 0x305cc) uses `LeftoverUninstallerApplicationMapper` + `EmptyApplicationFilter`, so nothing more is filtered **[O]**.
- `makeLeftoversResourcesLoadingModel(leftovers:)` (US 0x319f0) builds an `ApplicationCategoryResourcesLoadingModel` keyed by `bundleID` **[O]**. It runs the normal per-app resource fetchers on each leftover, so the files shown under a leftover are found the same way as for an installed app (by bundleID/name). Those fetchers cover Application Support, Caches, Preferences, Containers, Group Containers, Logs, Saved Application State, Cookies, LaunchAgents/Daemons, crash reports and so on (see the `CM*Fetcher` classes and the strings in US) **[I]**.
- Grouping: **one leftover "app" per distinct candidate bundle ID**. A container and a prefs plist with the same name collapse into one entry because of the uniquing step. Different IDs from the same vendor are **not** merged **[O]**/**[I]**.

---

## B. Special loaders, filters, task factory, app types (US)

### B.1 Steam (`CMSteamApplicationLoader`)
- **Library roots** [O] (`_loadSteamLibraryURLs` @17ae4, `_loadAdditionLibraries` @17c0c):
  - `<AppSupport>/Steam/steamapps`, using `applicationSupportDirectoryWithAppName:"Steam"`.
  - Plus every `libraryfolders.<n>.path` in `<AppSupport>/Steam/config/libraryfolders.vdf`, with `/steamapps` appended. `contentstatsid` is skipped and duplicates are removed.
  - The VDF is converted to JSON with regexes (`makeJSONFromVDF:` @1764c).
- **Games** [O] (`_loadApplications` @17f38): each non-hidden `<lib>/common/*` folder becomes a `CMSteamApplicationInfo` (`initWithURL:` @15e6c).
  - `identifier` = digits read from `steam_appid.txt` (@16464).
  - `mainAppURL` = the first `*.app` in the folder (@162c0); its icon is used.
- **Manifests** [O] (@181b8, @18a6c): each `<lib>/*.acf` is parsed for `"appid"` and `"installdir"`. A manifest joins the game whose folder name equals `installdir`.
- **Launchers** [O] (`loadLaunchers` @185fc):
  - Taken from `CMSystemInfo.userApplications`: apps whose `Contents/MacOS/run.sh` contains `open steam://run/<id>`.
  - A launcher is matched to a game by id or by name.
  - An unmatched launcher becomes its own Steam app.
- **`loadApplications`** @1701c [O]: attaches manifests (resource type 0x4000), launchers and the game folder (type 4) as pre-collected resources. Type semantics are [?].
- **`isApplicationURL:`** @178f4 [O]: a `.app` whose path contains a Steam library path. Used to filter Steam launchers and games out of the "user apps" list.

### B.2 JetBrains Toolbox (`CMJetBrainsToolboxApplicationsLoader`)
- **Root** [O]: `<AppSupport>/JetBrains/Toolbox/apps`.
- **Apps** [O]: `.app` items found within 3 levels, wrapped in `CMApplicationInfoContainer` (@4a44).
- **Launchers** [O] (@4bf0/@3e18): user apps whose Info.plist has `JetBrainsToolboxApp` = the real app path. A launcher matches the app whose URL equals that path.
- Unmatched launchers become standalone containers [O].

### B.3 Blizzard / Battle.net (`CMBlizzardApplicationLoader`)
- **Install directory** [O] (@390c): `Client.Install.DefaultInstallPath` from `<AppSupport>/Battle.net/Battle.net.config` (JSON).
- **Games** [O]: each child folder that contains a `.app` with bundle ID `net.battle.bootstrapper` (`isBlizzardAppFolder:` @2214).
- **Main app** [O] (@2c48), first match wins:
  1. `Versions/*/*.app`
  2. `x86_64/*.app`, excluding `com.blizzard.blizzarderror`
  3. the first non-bootstrapper `.app` in the folder or in `_retail_/`
- **Inner apps** [O] (@25ec): taken from root, `_retail_`, `Utils`, `InspectorReporter`, `Support`, `BlizzardBrowser`, `x86_64`, `Versions/*`.
- **`isApplicationURL:`** @350c [O].

### B.4 Audio plugins (`AudioPluginLoader` @25090, `AudioPluginsDirectoryProvider`, `AudioPluginFormat`)
Roots:
- `/Library/Audio/Plug-Ins` [I] (@39b14)
- `~/Library/Audio/Plug-Ins` [O] (@39df8)
- `/Library/Application Support/Avid/Audio/Plug-Ins` [O] (@3a278)

Formats (folder → extension) [O] (switch tables @23af0/@23bc4/@23cd4):

| # | Format | Folder | Extension |
|---|---|---|---|
| 0 | VST3 | `VST3` | `vst3` |
| 1 | VST | `VST` | `vst` |
| 2 | MAS | `MAS` | `bundle` |
| 3 | Component | `Components` | `component` |
| 4 | Driver | `HAL` | `driver` |
| 5 | CLAP | `CLAP` | `clap` |
| 6 | LADSPA | `LADSPA` | `so` |
| 7 | LV2 | `LV2` | `dylib` |
| 8 | AAX | `AAX` | `aaxplugin` |
| 9 | RTAS | `RTAS` | `dpm` |
| 10 | TDM | `TDM` | `dpm` |

Each entry becomes `AudioPluginInfo` (a `CMApplicationInfo` subclass with a `format`), via `audioPluginInfo(fromURL:)` @24e04. The format is guessed from the extension and the parent folder; format 0xb (unknown) gives nil [O]/[I].

### B.5 Filters (`shouldIgnore(application:)`)
- `CompoundApplicationFilter` @2d740: OR of its member filters [O].
- `BundleIdentifierFilter` / `ApplicationNameFilter` (shared @2d8e4) → `kb.isApplicationIgnoredWithApplication:` (AMD FUN_14374). This is true when any of the following holds [O]:
  - bundleID is in the KB `ignoredAppBundleIDs` set
  - the path is custom-ignored (1001, 0)
  - the path is KB path-ignored
  - the name is custom-ignored (2, 0xc)
- `PluginNameFilter` @2dd08 → `kb.isPluginIgnoredWithPlugin:` [O].
- `SteamApplicationFilter` @2dd64: Steam `isLauncherURL || isApplicationURL` [O].
- `BlizzardApplicationFilter` @2d980: Blizzard `isApplicationURL` [O].
- `JetBrainsApplicationFilter` @2db54: JetBrains `isLauncherURL` [O].
- `EmptyApplicationFilter` @1bb30: never filters [O].

Presets [O]:

| Preset | Filters |
|---|---|
| user | Steam + Blizzard + JetBrains + BundleId (@2d5ec) |
| system | BundleId (@2d4bc) |
| steam / blizzard / jetBrains | ApplicationName (@2954c) |
| mobile | BundleId (@29cb0) |
| audioPlugins | ApplicationName + PluginName (@29428) |

### B.6 `UninstallerScanTaskFactory` tasks (source → filter → mapper, kind 0 user / 1 system / 2 other) [O]

| Task | Source | Filter | Mapper | Kind |
|---|---|---|---|---|
| user @2f920 | `systemInfo.userApplications` | user preset | generic (FUN_29a24) | 0 |
| system @2fc08 | `systemInfo.systemApplications` | system preset | generic | 1 |
| steam @2fe24 | Steam loader | ApplicationName | Steam mapper | 2 |
| blizzard @30000 | Blizzard loader | ApplicationName | Blizzard mapper | 2 |
| jetBrains @301dc | JetBrains loader | ApplicationName | JetBrains mapper | 2 |
| mobile @303b4 | `systemInfo.mobileApplications` | BundleId | mobile mapper | 2 |
| leftovers @305cc | `LeftoversFetcher.fetchLeftovers()` | Empty | Leftover mapper | 2 |
| audioPlugins @30734 | `loadPlugins()` | ApplicationName + PluginName | audio mapper | 2 |
| `applications(by:)` @2f758 | `applicationByPath:` | BundleId | generic | 2 |

`applicationContainerAccessProbeTask` @2f438 checks whether the sandbox can read `~/Library/Containers` (privacy or Full Disk Access probe). It probes container subpaths such as `Library/Preferences` and `Library/Application Support` of known Apple apps (`com.apple.Photos`, `Safari`, `MobileSMS`, `AppStore`) [I].

### B.7 App model
- `UninstallerApplicationCore` [O] holds:
  - `appInfo`
  - `isAggressor` (+0x18), `isSystem` (+0x19)
  - `NSLock`
  - a `resources` Set
  - `isResourceScanComplete`
- `isPlugin` is true only for `UninstallerAudioPlugin` [O].
- Subclasses: Mobile, Steam, Blizzard, JetBrains, Leftover, AudioPlugin, InfoContainer. All use `init(appInfo:isSystem:isAggressor:)` [O].
- **Generic and mobile mapper** (FUN_29a24) [O]:
  - drops apps with no bundleID
  - `isAggressor = kb.isAggressorBundleID(id) || appInfo.signedWithAgressorCountryCertificate` (certificate country `ru`)
  - `isSystem = appInfo.isRestricted` (SIP-restricted Info.plist; see the cache bug in A.3)
- **Duplicate bundle IDs** are collapsed (FUN_2a268) [I]: the copy with the newest `lastUsedDate` is kept. The other copies' paths become type-4 resources of the kept app (FUN_2a77c). `com.setapp.DesktopClient` has special handling [?].
- **Steam, Blizzard, JetBrains, Leftover**: both flags false. Loader-collected resources are pre-filled; leftovers start empty [O].
- **Audio plugin**: `isAggressor` as for generic apps, `isSystem = false` [O].

---

## D. UI metadata and leftover result model (AMD / ApplicationsModule)

### D.1 Leftover result model
- `LeftoversScanResult` [O] (`init(leftovers:diskImages:)` AMD @0x2000):
  - `leftovers: LeftoversSubcategoryScanResult<LeftoverUninstallerApplication>`
  - `diskImages: LeftoversSubcategoryScanResult<UnusedDiskImagesModel>`
- The UI shows two subcategories: "app leftovers" (`app-leftovers_leftovers-item`) and "installers / DMG files" (`app-leftovers_installers-dmg-files`) [O].
- `LeftoversSubcategoryScanResult<A> { items: [A], resourcesLoading: ApplicationCategoryResourcesLoadingState }`. `hasItems` is `!items.isEmpty` (@0x13184) [O].
- The list appears first. Each leftover's files load in the background afterwards, shown as a placeholder row and then a "resources loading completed" event (C.5) [O].
- `ApplicationsScanResult(uninstaller:updater:leftovers:)`. Leftovers can be turned off with `ApplicationsModuleScanningConfig.isLeftoversEnabled` [O].
- Default selection: there is no leftover-specific rule. The generic ModuleCore auto-selection applies [?].

### D.2 KB variants (AMD @0x13bc8 `build` → FUN_17568; @0x13c10 `buildForLeftovers` → FUN_17690)
Both builders create the same `UninstallerKnowledgeBase` class [O]. They differ in three ways:
- **Primary scanner service.** The uninstaller uses `serviceBuilder.build(for: 1, scannerGroupID: 0x2e)`. Leftovers use `build(for: 2, …)`, which means different KB ignore and system lists. The secondary service `build(0, 2, 0x2e)` is shared by both [O]. What the IDs mean is [I].
- **`ignoredAppBundleIDs`.** The uninstaller passes the caller's set. Leftovers always pass an empty set [O].
- **`isSystemApplicationsIgnored`.** Both keep this preference. When it is on, `FUN_14080` treats an app as ignored if the KB says the bundle ID is a system item **or** `appInfo.isRestricted`. This is how Apple/SIP apps get hidden [O].

### D.3 Computed flags (AMD extension on `UninstallerApplicationType`)
- **`isSuspicious`** @0x18790 returns `isAggressor` [O].
  - `isAggressor` is set when the app is mapped: `kb.isAggressorBundleID` or the signing certificate country is `ru` (B.7) [O].
- **`is32Bit`** @0x18734 returns `appInfo.is32BitsOnly` [O].
- **`isUnusedForSixMonths`** @0x18488 [O]:
  - Always false for plugins.
  - Otherwise `lastUsedDate < Calendar.current.date(byAdding: .month, value: -6, to: now)`.
  - An app with no date falls back to "now" (A.3), so it is never counted as unused.
- **`lastUsedDate` source.** `FileManager.lastAccessDateAtPath:` lives in FileManagerService. It is probably Spotlight `kMDItemLastUsedDate` [I]. `usedDates` reads `kMDItemUsedDates` [O].
- **`ApplicationsFetcherScanResult.unused`** is a list of `UnusedApp{bundleID?, name}` for export [O].

### D.4 App-list filters and groups (ApplicationsModule). Every predicate first excludes plugins [O].

| Group | Option | Predicate | Evidence |
|---|---|---|---|
| Primary | All Apps | `!isPlugin` | FUN_61628 [O] |
| Primary | Unused | `isUnusedForSixMonths` | FUN_6166c [I] |
| Primary | Suspicious | `isSuspicious` | FUN_61678 [I] |
| Primary | (4th option) | node state byte `!= 2` (selection or update state) | FUN_616f0 [?] |
| Stores | App Store | `store == 1` | FUN_61770 [O] |
| Stores | Setapp | `store == 2` | FUN_617f0 [O] |
| Stores | Steam | `store == 3` (overridden by `CMSteamApplicationInfo`) | FUN_61870 [O] |
| Stores | Blizzard | `store == 4` | FUN_618f0 [O] |
| Stores | Other | `store == 0` | FUN_61970 [O] |
| Vendors | Apple | `vendor == 1` | FUN_619f0 [O] |
| Vendors | Microsoft | `vendor == 2` | FUN_61bf0 [O] |
| Vendors | Adobe | `vendor == 3` | FUN_61a70 [O] |
| Vendors | Google | `vendor == 4` | FUN_61af0 [O] |
| Vendors | MacPaw | `vendor == 5` | FUN_61b70 [O] |
| Vendors | JetBrains | `vendor == 6` | FUN_61c70 [O] |
| Vendors | Other | `vendor == 0` | FUN_61cf0 [O] |

- **Overview tiles:** All Apps, Unused Apps, 32-bit Apps, Leftovers, Unused Disk Images [O].
- **Sorting:** name and size; `LastOpened` (`lastUsedDate`) and `LastUpdated` [O]/[I].
- **App size:** the sum of the app's resources via `ResourceSizeProvider`, probably physical/allocated size [I].

---

## E. Reimplementation checklist (condensed)
1. Find apps:
   - Recursively walk `/Applications` and `/System/Applications`, stopping at each `.app`.
   - A bundle is valid only if it has `Contents/MacOS` and `Contents/Info.plist`.
   - On Apple silicon, also accept iOS wrapper apps that have `Wrapper/BundleMetadata.plist` and `Wrapper/iTunesMetadata.plist`.
   - Drop the 6 ignored bundle ID prefixes.
2. Split the apps into two lists:
   - **System:** path starts with `/System/Applications`.
   - **User:** fails the A.6 regex, or is Setapp's launcher.
   - Then add Steam, JetBrains, Blizzard, mobile and audio-plugin items, and apply the B.5 filter presets.
3. Mark each app's flags:
   - `isSystem` = `isRestricted` (SIP).
   - `isAggressor` = KB list, or certificate country `ru`.
   - When the "ignore system apps" preference is on, hide items that are KB-system or restricted.
4. Find leftovers (C.1–C.3):
   - Candidates are `~/Library/Containers/*` whose recorded `application_bundle` is missing, and `~/Library/Preferences/*.plist|xml`.
   - Each candidate must have a reverse-DNS name.
   - Drop it if any of these is true:
     - LaunchServices knows the bundle ID.
     - It prefix-matches an installed ID in either direction, after lowercasing and removing spaces and `-`.
     - A variant matches after stripping a team-ID prefix, `group.` / `maccatalyst.`, or a helper suffix.
     - `/Applications/<Name>.app` or `~/Applications/<Name>.app` exists.
     - It is on a KB ignore or system list.
   - Make one leftover per remaining bundle ID, then load its files with the normal per-app resource fetchers.
5. UI metadata:
   - "Unused" = last used more than 6 months ago.
   - Vendor: prefix tables in A.5.
   - Store: 0–4.
   - "Suspicious" = `isAggressor`.
   - Also mark 32-bit apps.
