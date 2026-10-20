# CleanMyMac 5 (MAS 5.7.1): Duplicates and Similar Images spec

Source: static analysis of `OrganizeModule` (OM) and `OrganizeScanning` (OS) arm64 slices.
Tags: **[O]** observed directly in code or data, **[I]** inferred from structure or names, **[?]** unresolved.
Addresses are for the thin binaries in `$S/bin` (OM = OrganizeModule, OS = OrganizeScanning).
Annotated pseudocode is in `$S/dup/OM.a2.c` and `$S/dup/OS.a2.c` (CF strings and stub names are resolved).

---

## 0. Architecture overview

```
OrganizeModule ("My Clutter")
 ├─ DuplicatesScanning.DuplicatesScanTask        (name "Duplicates")
 │    FileNodeEnumerator(dir) [+ PhotoLibraryEnumerator if Photos lib is under dir]
 │    → DuplicatesGroupCollector(sizeBuckets, fileHashBuckets,
 │         AggregatedNodeBucketItemCalculator{FileNode…, BundleNode…},
 │         DuplicateAutoselector(prioritizers), ContentKindEvaluator)
 │    → [DuplicateGroupModel]
 ├─ SimilarImagesScanning.SimilarImagesScanTask
 │    FileNodeEnumerator(dir) [+ PhotoLibraryEnumerator]
 │    → SimilarImagesGroupCollector(imageProcessingQueue,
 │         ImageSimilarityCalculator(threshold: 15), ImageAttributesCalculator,
 │         DuplicatesGroupCollector(FileNode calc, NothingAutoselector))
 │       + IncrementalDuplicateDetector(RegularFileHashCalculator)
 │    → [SimilarImageGroupModel]
 └─ UI: OrganizeRootNode{duplicatesNode, similarImagesNode, laofNode, downloadsNode}
        DataManager + MediaGallery (select control, navigation, preview and metadata)
```
Construction: duplicates `FUN_0008ab54`/`FUN_0008ea04` [O]. Similar `FUN_0009c058` @0x9c058 [O]: it calls `ImageSimilarityCalculator.init(threshold: 0xf)`.

---

## 1. Scope

### 1.1 Roots
* **The root is one directory, chosen by the user.** Each scan task carries a single `directory: URL` (`DuplicatesScanTask.directory`, `SimilarImagesScanTask.directory`) [O].
  * The default is the real home directory (`FileManagerProvider.realHomeDirectory`). The `VolumeSelectionViewModel(urlProvider:…homeURL:homeTitle:…savedPreferences:)` lets the user pick a different folder or volume (OM line ~19109) [O].
  * The chosen folder is stored in `SharedPreferencesKeys.organizeModuleCustomScanPath` (OM ~75632) and wrapped in a `ModuleScanningURLProvider(url:directoryProvider:)` [O].
  * Tiles also run on fixed roots: Desktop (`DesktopDuplicatesTile`), Documents (`DocumentsDuplicatesTile`, "Dups in Documents") and the Photos library (`PhotosSimilarsTile`) [O].
* **The Photos library is enumerated separately through PhotoKit, and only when it lies under the scan root.** The duplicates task reads `DirectoryURLProvider.photoLibrary` (OM `FUN_0008d…` ~118274). The check is `photoLibURL.pathComponents.hasPrefix(directory.pathComponents)` [O]:
  * If the check passes, the task builds an `AsyncStream` that merges the `FileNodeEnumerator` stream with a `PhotoLibraryEnumerator.enumerate(at:rules:)` stream.
  * Log texts: `Scan started in Photo library … . Enumerating photos...` and `… duplicate photo candidates.` The similar-images task does the same (OM ~131123) and logs `… similar image from photo library candidates.` [O]
  * The file walker skips `.photoslibrary` bundles through a default rule (§1.2), so library files are never read twice [O].

### 1.2 Ignore rules (OS `InternalIgnoreRules`)
`IgnoreStatus` is an OptionSet [O, values from statics]:
* `skipGrouping = 1`
* `skipHashing = 2`
* `skipEnumeration = 4`

`IgnoreStatus.evaluate(withRules:forURL:)` @OS 0x16f10 ORs together the statuses of all the rules [O]. Every built-in rule uses status **7** (all three bits).

**`default`** (`FUN_00017600` @OS 0x17600) [O], in this order:
1. `FileNameRegularExpressionIgnoreRule`. The regex is built as `"(p1)|(p2)|…"` with `NSRegularExpression` options `1` (case-insensitive) (`FUN_00016828`). The patterns (static array @0x3f1c0) are:
   `\.git`, `\.svn`, `\.Trash`, `\.DS_Store`, `credits.?`, `infoplist.?`, `web-inf.?`, `backups\.backupdb`, `licence.?`, `license.?`, `node_modules`, `gems`, `bower_components`.
2. `FilePathExtensionsRule` with 78 extensions (static @0x3f298). The extensions are:
   framework build lproj a so h pch c hpp h++ cpp c++ m swift java class idea py rb php css js json jar lib dylib dll ocx pth db rpl hds info def properties proofingtool bup ar tmp hg vsd xsd xslt xsl entitlements xcconfig sparsebundle dsym cer crt applescript version asset prefab unity html scss sh bash scala sc cs cake coffee cshtml csx ts py vim vue plist yml yaml gradle md ruby gemfile gem sql
3. `FilePathExtensionsRule` with `photoslibrary` and `musicLibrary` (@0x3f7b0).
4. `FilePathPrefixIgnoreRule` entries, each path normalised to end in "/" (only the rules whose directories exist are kept, up to 9 optional rules):
   * `FileManagerProvider.systemDirectory` (/System)
   * `libraryDirectory` (/Library)
   * `userLibraryDirectory` (~/Library)
   * `userMusicDirectory/Music`
   * `userMusicDirectory/iTunes`
5. `HiddenURLIgnoreRule` (`URLType.isHidden`), status 7.

**`duplicatesSpecificRules`** (`FUN_0001822c`) [O]:
* `MinimumFileSizeIgnoreRule(minimumFileSize: 102400, status: 7)`. The value comes from the literal @0x2e640 = (102400, 7), so files smaller than **100 KiB** are skipped.
* `FilePathExtensionsRule(["xcassets"], 7)`.

**`similarImagesSpecificRules`** (`FUN_00018518`) [O]:
* `MinimumFileSizeIgnoreRule(102400, 7)`.
* `AcceptedContentKindIgnoreRule(contentKind: .image, status: 7)`. Anything that is not an image is skipped.
* `FilePathExtensionsRule(["psd","psb"], 7)`.
* `FilePathExtensionsRule(["xcassets"], 7)`.

`laofSpecificRules` (for comparison): `MinimumFileSize(52428800 = 50 MiB)` [O].

**Knowledge-base (user Ignore list) rules.** `DuplicatesKnowledgeBaseIgnoreRule.ignoreStatus` @OM 0x7b438 and `SimilarImagesKnowledgeBaseIgnoreRule.ignoreStatus` @OM 0x92770 both work the same way: if `knowledgeBase.isIgnored(url)` returns true, they return `skipEnumeration|skipHashing|skipGrouping` (= 7), otherwise 0 [O].
* Each scan's `rules` = `InternalIgnoreRules.default + <feature>SpecificRules + [KB rule]` [I].
* The KB is `DuplicatesKnowledgeBase` / `SimilarImagesKnowledgeBase` over `KnowledgeBaseService`, keyed by URL. Items get there through the "Add "%@" to Ignore List" action (`OrganizeNodeIgnorerFactory`) [I].

### 1.3 Enumeration (`FileNodeEnumerator`, OS)
* IO uses the dispatch queue `com.macpaw.CleanMyMac.FileNodeEnumerator.IO`, with `maxConcurrentScans = 16` (@OS 0x2dbc) [O].
* Prefetched keys include `isUbiquitousItem`, `fileAllocatedSize`, `fileSize`, `fileResourceType`, `contentModificationDate`, `creationDate`, `contentType` and `isHidden` [O].
* Per item (`FUN_000096b8` @OS 0x96b8) [O]:
  1. If `isUbiquitousItem == true`, **skip** (all iCloud items are excluded, not only placeholders).
  2. Evaluate the rules. If the result contains `skipEnumeration`, skip the item.
  3. Build a `Node`:
     * `resourceLocator = .file(url)`
     * `size = fileSize` (0 if missing)
     * `modificationDate = contentModificationDate ?? .distantPast`
     * `creationDate`
     * `fileResourceType`
     * `contentKind`
     * `ignoreStatus`
* `FileResourceTypeEvaluator` (@OS 0x47c8) maps `NSURLFileResourceTypeDirectory` → `.directory` (0), `Regular` → `.regular` (1) and anything else (symlinks and so on) → `.other` (2) [O].
* `ContentKindEvaluator.contentKind` (@OS 0x1f30) reads `contentType` [O]:
  * conforms to `UTType.image` → `.image`
  * else conforms to `.movie` → `.video`
  * else, or if the type is unknown → `.other`
* `isBundle` (@OS 0x2540): the item is a directory whose `contentType` conforms to `.package`, `.bundle` or `.applicationBundle` [O].
* Bundles are emitted as one node, not walked into, and hashed as an aggregate (§2.4) [I: `EnumerationItemSkipDecision {noSkip, skip, skipWithDescendants}`].

### 1.4 Photos library (`PhotoLibraryEnumerator`, OS)
* Requires `PHPhotoLibrary.authorizationStatus`. The log `PhotoLibrary.authorizationStatus: ` is written when access is denied, and the error is `EnumerationError.couldNotGetPhotoKitItems` [O].
* Fetch: `PHAsset.fetchAssets` with predicate `"(mediaType = %d) OR (mediaType = %d)"` (image = 1, video = 2) [O].
* `PhotoKitLibraryItemsBuilder` maps each asset to a file inside the library [O]. It uses the private KVC keys `directory`, `filename`, `originalFilename`, `mainFileURL` and `thumbnailIdentifier`. `ValidDirectory {masters, previews, thumbnails}` covers the "Masters", "Previews" and "Thumbnails" folders.
  * Fields: `PhotoKitLibraryItem{asset, filename, itemName, originalURL, previewRelativeComponents, thumbnailRelativeComponents}`.
* `PhotosItemInfo` holds `identifier` (localIdentifier), `name`, `modificationDate`, `creationDate`, `isFavorite`, `width`, `height`, `filename`, `location`, `albums` and a lazy `isInDeletedAlbum` [O].
* **Assets in a "Gemini duplicates" album are skipped** (`FUN_00012668`, OS ~14331). `knownDeletedItemsAlbumNames` (@0x3ef00) is:
  "Doublons Gemini", "Дублікати Gemini", "Gemini Duplicates", "Gemini Duplikate", "Duplicati Gemini", "Duplikaty Gemini", "Duplicados Gemini", "Duplicatas do Gemini", "Gemini 重复项", "Gemini-duplicaten", "Gemini の重複項目" [O].
* Node: `resourceLocator = .photoLibraryAsset(id, url)`, `size = fileSize` of the original file, plus `photosItemInfo` [O].

---

## 2. Duplicate detection

### 2.1 Collector (`DuplicatesGroupCollector`, OM)
* Fields: `sizeBucketsActor: DictionaryActor<UInt64,[Node]>`, `fileHashBucketsActor: DictionaryActor<FileHash,[Node]>`, `nodeBucketItemCalculator`, `autoselector` and `contentKindEvaluator` [O, reflection].
* `collectGroups(from: AsyncStream<EnumeratorNodeType>, inputProgress:, outputProgress:)` @0x82d18 is async [O].

Algorithm [O structure, I order]:
```
for node in stream:
  if node.ignoreStatus ⊇ skipHashing: continue (nodeHash returns nil)  // FUN_00080fe8
  s = nodeBucketCalc.nodeSize(node)
  bucket = sizeBuckets[s].append(node)
  if bucket.count == 2: hash both nodes        // progress: FUN_00085ad0 adds size0+size1
  elif bucket.count > 2: hash the new node     // adds node.size
  for each hashed n: h = nodeHash(n) (FileHash?) ; if nil → drop
                     fileHashBuckets[h].append(n)
groups = fileHashBuckets.values
          .map { $0.filter { !$0.ignoreStatus.contains(.skipGrouping) } }
          .filter { $0.count >= 2 }             // FUN_00085bc4: "< 2 → nil"
          .map  { autoselector.autoselect($0) → DuplicateGroupModel }
```
* `FileHash { hashData: Data, size: UInt64 }`. Equality and hashing cover both fields (`FileHash.==` @0x8153c) [O].
* Hard links and APFS clones get no special handling. No inode, `fileResourceIdentifier` or link-count keys are read anywhere [O: absence]. Two hard links to the same inode therefore form a duplicate group.

### 2.2 File hash (`RegularFileHashCalculator.calculateHash(at:)` @OM 0x82500) [O]
1. Read `fileSize` (`NSURLFileSizeKey`). If the read fails, throw `couldNotGetFileSize` (1). If size < 1, throw `couldNotReadData` (0).
2. Open the file with `NSFileHandle(forReadingFrom:)`.
3. Compute the chunk ranges with `ranges(size, count: 4, chunk: 0x100000)` (`FUN_00082208`, called @0x81d10 with `w1=4, w2=0x100000`):
   ```
   if 4 * 1 MiB < size:  step = size / 4
                         ranges = [(i*step) ..< (i*step + 1 MiB) for i in 0..<4]
   else:                 ranges = [0 ..< size]          // whole file
   ```
4. For each range, `seekToFileOffset(lower)` and then `readData(ofLength: upper-lower)` (`FUN_00082620`). Feed each chunk into **`Insecure.SHA1`** (CryptoKit; SHA1 is the only hash imported).
5. Return `FileHash(hashData: SHA1.finalize(), size: size)`.

So a file larger than 4 MiB is fingerprinted by its size plus SHA-1 over 4 × 1 MiB samples taken at offsets 0, ⌊s/4⌋, ⌊s/2⌋ and ⌊3s/4⌋. Smaller files get a full SHA-1. No full-file verification pass follows [O: none found].

### 2.3 Bucket item calculators
* `FileNodeBucketItemCalculator(hashCalculator:)`: `nodeSize = node.size` and `nodeHash = hashCalculator.calculateHash(url)` [O].
* `AggregatedNodeBucketItemCalculator{fileNode…, bundleNode…, contentKindEvaluator}` uses the bundle calculator when `contentKindEvaluator.isBundle(url)` is true and the file calculator otherwise [I from fields and `FUN_0008ea04`].
* `BundleNodeBucketItemCalculator{fileManager, fileHashCalculator, bundleHashCalculator: DataHashCalculator, contentKindEvaluator}` [I]:
  1. Enumerate all regular files in the bundle.
  2. Build `HashPair(path: relativePath, fileHash)` for each file.
  3. Sort the pairs by path.
  4. `DataHashCalculator` (SHA1) over the concatenation of the pairs.
  5. size = sum of the file sizes.

### 2.4 Group model
* `DuplicateGroupModel{duplicates:[DuplicateFileModel], url, title, size, kind: DuplicateKind, modificationDate, hash: FileHash}` [O].
* `DuplicateFileModel{creationDate, modificationDate, size, isAutoselected, resourceLocator, metadata}` [O]. The metadata comes from `MediaMetadataFetcher.default.fetch(with:)` at group build time.
* `DuplicateKind ∈ {application, archive, audio, text, image, video, other}`. The kind is decided by UTType conformance: `.application`, `.archive`, `.audio`, `.text`, `.image`, `.movie` [O stubs; order I].
  * UI filter names: Applications, Archives, Audio, Documents (text), Pictures, Videos, Other.
* `title` is the file name of the kept (first) file, and `url` is that file's URL [I].
* Group size = the per-file size. "Unwanted" size = Σ(size of autoselected files) (`DuplicatesScanProduct.unwantedFilesSize`) [I].

---

## 3. Auto-selection of duplicates

### 3.1 `DuplicateAutoselector(prioritizers:)` (`FUN_000771e8` @OM 0x771e8) [O]
```
sorted = nodes.sorted { cmp(a,b) == .orderedAscending }
cmp(a,b) = first prioritizer result != .orderedSame        // FUN_00077380
result[i] = AutoselectedFileNode(node, isAutoselected: i != 0)
```
The first node after sorting is **kept** (not selected). Every other node is autoselected for removal.

### 3.2 Prioritizers (`FUN_00078b3c`, ordered list; the description strings are verbatim) [O]

| # | Description | Comparator (rule: the kept copy sorts first) |
|---|---|---|
| 1 | "Select in Downloads folder" | `inDL(x) = x.pathComponents.hasPrefix(downloadsDir.pathComponents)`. The downloads dir is `userDownloads`, falling back to `realHome/"Downloads"`. `(a in, b out) → +1`, `(a out, b in) → -1`, else 0 (`FUN_00079c4c`). Copies in Downloads get selected. |
| 2 | "Select with greater copy number" | `copyNumber(name)` (`FUN_000790a4`): `nil` < any number, and two numbers compare with `NSNumber.compare` (`FUN_00079000`). The lower or absent copy number is kept. |
| 3 | "Select not in Photo library" | `inPL(x)` is the same prefix test against `photoLibrary`, reversed (`FUN_00079e98`). The Photos-library copy is kept. This prioritizer is only present when the photo-library URL resolves. |
| 4 | "Select older modified" | `b.modificationDate.compare(a.modificationDate)` (`FUN_0007a064`). The newest modification is kept. |
| 5 | "Select deeper path" | `a.pathComponents.count` compared with b's (`FUN_0007a174`). The shallowest path is kept. |
| 6 | "Select shorter filename" | `b.nameLen.compare(a.nameLen)`, using the name without extension (`FUN_0007a290`). The longest name is kept. |
| 7 | "Select by file path alphabetically" | `a.path.compare(b.path, options: .numericSearch (0x40))` (`FUN_0007a4a8`). The alphabetically first path is kept. |

**`copyNumber`** [I, partially O] uses `DuplicateSelectionPrioritizers{directoryURLProvider, copySuffixes, copyPrefixes}`:
* It takes `stem = lastPathComponent` with the extension removed.
* A run of trailing ASCII digits, with an optional `+` or `-`, is parsed as an Int.
* The remaining stem is then checked for a copy suffix or prefix. When the stem has a copy marker but no number, it counts as copy 1 [?].
* copySuffixes (@0xf4990), case as stored:
  `" copy"`, `"-copy"`, `" (copy)"`, `" копия"`, `" (kopie)"`, `" kopie"`, `" (kopia)"`, `" (kópia)"`, `" (kopie)"`, `" kópia"`, `" (สำเนา)"`, `" สำเนา"`, `" - copie"`, `" kopie"`, `" copia"`, `" còpia"`, `"-cópia"`, `" kopi"`, `" kopia"`, `" kopija"`, `" kopio"`, `" kopya"`, `" másolat"`, `" salin"`, `" 拷貝"`, `" копія"`, `"のコピー"`, `"복사본"`, `"αντίγραφο"`, `"-kopia"`, `"副本"`, `" نسخة"`, `" - עותק"`, `" עותק"`
* copyPrefixes (@0xf4bd8): `"copy of "`, `"copy "`, `"копия "`, `"bản sao "`, `"cópia de "`, `"salinan "`, `"نسخة "`

### 3.3 Selection control (group header "Select" menu)
Titles come from ModuleCore strings. `SelectionControlFactory` (OM) [O]:
* **`makeDuplicates`** @0x37a1c: `[SmartSelectionControlOption ("Smartly"), Oldest, Newest, DeselectAll]` (count 4 @0xade00).
* **`makeSimilarImages`** @0x37d88: `[BestQualitySelectionControlOption, Oldest, Newest, Smallest, Largest, DeselectAll]` (count 6 @0xadf40).
* `Oldest/Newest.splitNodes` (@0x36120 / 0x35e58) [O structure, ? direction]:
  * Collect each node's date (`FUN_0003614c(nodes, isNewest)`).
  * Take the min (Oldest) or max (Newest) using `Comparable.<` (`FUN_00036e10` / `FUN_00036fd8`).
  * Split the nodes into those whose date equals the extreme and the rest.
  * If no node has a date, fall back to `FUN_000367b0` (a second date field).
  * The result is `(nodesForSelect, nodesForDeselect)`. Smallest and Largest are analogous on size.
* "Smartly" re-applies the autoselect flags (`isAutoselected`). Context menu: "Apply Smart Selection" [I].
* Selecting every item in a group raises an alert (`SelectionAlerter`) [O strings]: "Are you sure you want to select all items within this group?" / "This will remove all of the instances of your file." with the buttons [Select All] [Cancel].
* `OrganizeAutoSelectableStrategy {disabled, smartSelect, full}` controls whether the autoselect flags are applied on load [O].

---

## 4. Similar images

### 4.1 Per-image attributes (`ImageAttributesCalculator`, OM)
* **Thumbnail** (`generateImageThumbnail(from:)` @0xa05c4 → `FUN_000a13f8` with options from `FUN_000a0fe8`) [O]:
  * Source: `CGImageSourceCreateWithURL` with `{kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: true}` (`FUN_000a0e84`).
  * Checks: `CGImageSourceGetCount > 0` and `GetStatus == complete`. Failures throw `ImageProcessorError`.
  * Thumbnail: `CGImageSourceCreateThumbnailAtIndex(src, 0, {ThumbnailMaxPixelSize: 256, CreateThumbnailFromImageAlways: true, CreateThumbnailWithTransform: true})`.
  * Everything runs inside an ObjC `@try` wrapper (`ObjcHandler.cmm_tryBlock`).
* **Hash** (`calculateImageHash(for: CGImage)` → `FUN_000a282c`): `ImageHash.hashes = [UInt64](4)`, filled by the C function **`CMImageHashForImage(cgImage, uint64_t out[4])`** @OS 0x2936c [O].
  1. Proceed only if `max(w,h) ≥ 128` and `min(w,h) ≥ 32`. Otherwise return failure, so the image gets no hash and is skipped.
  2. Convert to sRGB ARGB8888 (8 bits per component, 32 bits per pixel, alpha `first` = 4) with vImageConverter.
  3. Compute luma with `vImageMatrixMultiply_ARGB8888ToPlanar8`. The coefficients are `[0, Kr, Kg, Kb]` from `kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2` (0.2126, 0.7152, 0.0722), each ×256, with divisor 256.
  4. Apply a Sobel filter with `vImageConvolve_Planar8`, 3×3, divisor **8**, flags `0x14` (BackgroundColorFill|DoNotTile, background 0, negatives clamp to 0):
     * Gy = `[-1,-2,-1, 0,0,0, 1,2,1]`
     * Gx = `[-1,0,1, -2,0,2, -1,0,1]`
  5. Gradient magnitude: `min(255, (int)sqrt(gx²+gy²))` (`_combineGradients`).
  6. Convert Planar8 to float with a lookup table, `v/255.0`.
  7. Resize to **32×32** with `vImageScale_PlanarF` (default resampling).
  8. For k in 0..3: if k > 0, `vImageRotate90_PlanarF(rotation = 1)`, which rotates the previous buffer by 90° (direction constant 1).
     * Then take the 2-D DCT-II, `D = C·X·Cᵀ`, using two `cblas_sgemm` calls on 32×32 matrices.
     * `C[0][n] = sqrt(1/32) = 0.1767767`, `C[k][n] = 0.25·cos(π(2n+1)k/64)` with π/64 = 0.04908738521234052.
     * Take the top-left 8×8 block of D (rows 0–7, cols 0–7), including the DC term, and compute `mean = Σ/64`.
     * Hash bit `i` (`i = row*8+col`; the bit is set at position i, LSB = coefficient 0) = `D[i] >= mean`.
     * `out[k]` = that 64-bit value.
* **Similarity** (`ImageSimilarityCalculator.areHashesSimilar` @OM 0xa0cc8) [O]:
  ```
  dist = Σ_{k=0..3} popcount(h1[k] ^ h2[k])      // all 4 rotations, index-aligned
  similar = dist <= threshold   // threshold = 15 (FUN_0009c058)
  ```
  This is effectively a 256-bit pHash with a Hamming threshold of 15.
* **Characteristics** (`calculateImageCharacteristics(for:)` → `FUN_000a4ca8`). The input is the grayscale 8-bit pixels of the thumbnail (`FUN_000a28a0`), and the output is `ImageCharacteristics{metrics: [ImageMetric], width, height}` [O structure]:
  * `noise` (`FUN_000a3d80`): extract **8×8 patches**, build the 64-D patch covariance matrix and take its eigenvalues with LAPACK `dsyev_`. The noise is the **smallest eigenvalue** (eigen[0], the noise variance; PCA noise estimate) [I]. Errors: `covarianceMatrixIsNotSymmetric`, `eigenvaluesComputationError(Int)`.
  * `blur` (`FUN_000a49f8`): convert the pixels to Double and apply a full multi-level **2-D Haar wavelet transform** (`FUN_000a4650`, which runs a row pass then a column pass of `FUN_000a4394`: `a'=(x0+x1)*0.5`, `d'=(x0−x1)*0.5`, halving each level until length 1). The blur value is the **variance** (Σ(x−μ)²/n) of all the coefficients. Higher means sharper [I].
  * `dynamicRange` = `20·log10(maxPixel/minPixel)` over the luminance bytes. It is omitted when `minPixel == 0` [O].
  * `width` and `height` are the original image pixel dimensions [I].

### 4.2 Pipeline (`SimilarImagesGroupCollector`, `SimilarImagesScanTask`)
1. Enumerate the images (files plus Photos) under the similar-images rules (§1.2).
2. `processImageNode(_:updateProgress:)` (`FUN_00094718`):
   * Hop to the `imageProcessingQueue` ("com.macpaw.CleanMyMac.ImageProcessing") through `withCheckedContinuation`.
   * `calculateImageAttributes(url)` returns `(ImageHash, ImageCharacteristics)?`.
   * On failure, log "Failed to calculate image hash or characteristics for …" and drop the image [O].
3. **Exact-duplicate detection.** `IncrementalDuplicateDetector{hashCalculator: RegularFileHashCalculator, seenNodes: [FileHash: DuplicateAwareNode]}` (`FUN_00093c78`) uses the same SHA1 4×1 MiB hash. If the hash was already seen, it sets `isDuplicate = true` on both the earlier and the current node [O].
   * Effect: exact copies are reported by Duplicates rather than Similar [I: they are excluded or tagged, ?].
4. **Clustering** (`FUN_00095554`) is greedy first-fit single linkage in stream order [O]:
   ```
   for node in nodes:
     for g in groups (in creation order):
       if g.contains(where: { sim.areHashesSimilar($0.hash, node.hash) }): g.append(node); goto next
     groups.append([node])
   ```
5. **Group finalisation** (`FUN_0009580c`) [O]:
   * Drop nodes with `skipGrouping`, then drop groups with fewer than 2 members.
   * Fetch metadata (`MediaMetadataFetcher`).
   * Build `SimilarImageModel{creationDate, modificationDate, contentCreationDate, creationOrModificationDate, size, resourceLocator, imageCharacteristics, isBestInGroup, metadata}`.
   * Wrap the models in `SimilarImageGroupModel{similarImages, url, title, size, date}`. `title` and `date` come from a group date formatter over the image dates [I].
6. **Best-in-group scoring** (`FUN_00098420` + min/max from `FUN_00096bb0`, disassembly 0x98550–0x98710) [O]:
   * Min-max normalise each field over the group: `n(x) = (x − min)/(max − min)`. If `max == min`, the raw value is used, which is a quirk.
   * Variables:
     * `nN = noise present ? n(noise) : 1.0`
     * `nB = blur present ? n(blur) : 0`
     * `nD = dynamicRange present ? n(dr) : 0`
     * `nW = n(width)`
     * `nH = n(height)`
   * Score:
     ```
     score = sqrt((nN − 1)² + nB²) + 0.3·nD + 0.1·nW + 0.1·nH
     ```
     Constants: 0.3 = `0x3fd3333333333333` and 0.1 = `0x3fb999999999999a`.
   * Sort by score **descending** (insertion and merge sort `FUN_00097440`; `fcmp prev,cur; b.pl stop`).
   * Keep the **top k** as `isBestInGroup = true` (`FUN_00098328` takes the prefix of length `m>>1`):
     * n ∈ {2,3} → k = 1
     * n ∈ {4,5,6} → k = 2
     * n ≥ 7 → k = 3
     * n == 1 → none
   * The UI shows these with the badge text "One of the best to keep" (asset `bestInGroup`).
7. Auto-selection. The collector's `DuplicatesGroupCollector` uses `NothingAutoselector`. The "Best quality" select option (and smart select) selects every image with `!isBestInGroup` [I].
8. "Visual Flaws" badge texts: "Blur", "Noise" and the tooltip "This image shows signs of visual imperfections." The thresholds that trigger the badge were not located [?]. A plausible implementation flags an image whose normalised blur or noise is the worst in its group.

### 4.3 Products and tiles
* `SimilarImagesScanProduct{groups, similarImagesCount, unwantedFilesSize, isPartial}` and `DuplicatesScanProduct{groups, duplicatesCount, unwantedFilesSize, isPartial}` [O].
* Tiles [O strings + `Calendar.date(byAdding:)` values]:

| Tile | Rule |
|---|---|
| Duplicates (sizeable) | All duplicates. |
| `FreshDuplicatesTile` "Dups from the Last 3 Months" | Date ≥ now − **90 days** (−0x5a). |
| Desktop / Documents duplicates | Path prefix. |
| `MostRecentSimilarsTile` | Date ≥ now − **30 days** (−0x1e). |
| `BiggestSimilarsTile` | Largest groups. |
| `PhotosSimilarsTile` | Groups inside the Photos library. |

---

## 5. Removal
* `OrganizeModuleCleanerFactory{fileRemover, photoLibraryRemover}` and `DuplicateRemovalTask{resourceLocatorResolver, fileRemover, photoLibraryRemover}` [O].
* **Files.** The remover is chosen by `OrganizeModuleConfig.kind` (`FUN_00014e98` @OM ~21071) [O]:
  * `kind ∈ {smartCare, smartCareLAOF}` → `MoveToTrashFileRemover` (Trash).
  * `module` / `customFlow` → `FileRemover(fileManager:)` (CleaningCore `NSFileManager removeItemAtURL`, a permanent delete; see `specs/caches.md`), wrapped in `ConfigDependentFileRemover`.
  * Protected paths go through `ProtectedFileRemover.shared` [O].
* **Photos assets.** `PhotoLibraryRemover` collects `PhotoLibraryRemovalItem{assetIdentifier, url, node}` [O]:
  * `PHAsset.fetchAssetsWithLocalIdentifiers:options:`
  * then `PHPhotoLibrary.performChangesAndWait { PHAssetChangeRequest.deleteAssets(assets) }` (OM ~46102/46137).
  * Photos moves the assets to "Recently Deleted" and shows the system confirmation.
* `ConfigDependentPhotoLibraryRemover(throwIfFailCleanEnabled:debugRemover:realRemover:)`: the debug remover logs `[SIMULATE]: Photo library removal`. Errors log "Failed to remove …" [O].
* Result texts:

| State | Text |
|---|---|
| In progress | "Removing files…" |
| Success | "Removal complete!" / "successfully removed" |
| Failure | "Removal failed..." / "Some files were not removed. Please make sure none of your apps are using them and try again." |
| Buttons | "Review More Items", "My Clutter Log" |

---

## 6. UI flow and texts

### 6.1 Flow
`Intro` ("My Clutter" / "Sort through your files and reduce the mess in just a few clicks.") → **Scan** → **Results tiles** → **Data Manager** → **Clean**.

| Screen | Texts |
|---|---|
| Scan, duplicates | "Looking for duplicate files..." |
| Scan, similar images | "Looking for similar images..." / "Looking for similar photos across your library." |
| Results tiles | "Review" / "Review All Files" |
| Nothing found | "How did you keep it this tidy?" / "There is no clutter to be found." |
| Partial scan | "Rescan", with the tooltip "The scan couldn't be completed for some items. Scan again to include them. It may take longer than usual." |

### 6.2 Categories
* **"Duplicates"**: "Identical copies of files that may be stored in different locations of your Mac. They may be wasting a significant amount of space."
* **"Similar Images"**: "Some of the shots you take are virtually identical to the eye, so you might want to keep only the best copy and remove the rest."
* Smart Care variant: "Duplicate Downloads".

### 6.3 Groups list (`OrganizeGroupNode`)
* Columns: group title (file name / date), item count with the tooltip "The total number of the file’s duplicates." or "The total number of similar instances of the photo.", and selected count with the tooltip "The number duplicates selected for removal." or "The number of images selected for removal."
* Date tooltip: "The date when the file was created."
* Size: the group-cell tooltip is "Total size of selected items within the group".
* Duplicate filters: All Files, Selected, Applications, Archives, Audio, Documents, Pictures, Videos, Other.
* `OrganizeDetailsNode{model, isAutoSelected, fileItemInfo, selectionAlerter, imageItem, date}`.

### 6.4 Media gallery (`MediaGalleryView{selectControlView, navigationView, previewView}`)
* **Select control** (`MediaGallerySelectControlViewController`): the "Select" popup with the options from §3.3.
* **Navigation** (`MediaGalleryNavigationViewController`): a table of groups and items.
  * Each cell (`MediaGalleryNavigationCellView`) has a thumbnail, a hover view, a checkbox (`onCheckmark:`), a `noticeView` badge (best or flaws) and a `BadgeView`.
  * Row selection border: `focusedSelectedBorderColor`/`Width`, plus a secondary variant.
* **Preview** (`MediaGalleryPreviewView`):
  * `titleLabel` and a zoomable `imageView` in `imageViewingScrollView`.
  * `pathStackView` with `PathControl` and an open button (reveal in Finder; for Photos items the "Photos" title and the `Photos_PathControl_Icon` asset).
  * A context menu (`menuProvider`): Quick Look, Ignore and Select actions.
* **Metadata grid** (`MediaGalleryMetadataView` = `NSGridView` of `MediaGalleryMetadataRowViewModel{title, description:[String], kind}`). Built by `FUN_000647f8` with the size, date and duration formatters. Row order as built:

| ModuleCore index | Row title |
|---|---|
| 0x48 | Modified: |
| 0x42 | Created: |
| 0x4a | Size: |
| 0x47 | File type: (`ImageFormat` / `VideoFormat.title`) |
| 0x43 | Device make: |
| 0x44 | Camera: |
| 0x3f | Captured: (contentCreationDate) |
| 0x46 | Duration: |
| — | Dimensions: (pixelWidth × pixelHeight) |
| — | Resolution: (DPI) |
| — | Color space: |
| — | Color profile: |

  Metadata sources (OS `MediaMetadataFetcher{fileMetadataFetcher (CMMetadataFetcher/MDItem), imageMetadataFetcher (CGImageSourceCopyPropertiesAtIndex), quickTimeMetadataFetcher (AVAsset QuickTime metadata)}`): `kMDItemAcquisitionMake/Model`, `ColorSpace`, `ContentCreationDate`, `DurationSeconds`, `Orientation`, `PixelWidth/Height`, `ProfileName` and `ResolutionWidth/HeightDPI` [O imports].
* **Thumbnails** (`ThumbnailFetcher{request: FetchImageRequest{url, size: CGSize, scale, iconMode}, cache: ThumbnailCache}`):
  * `fetchImage` uses `QLThumbnailGenerator.shared.generateBestRepresentation(for: QLThumbnailGenerationRequest)`. Cancelling calls `cancelRequest:`.
  * `fetchVideoPreview` produces video frames.
  * When `iconMode` is set, the image is rendered as a file icon. Description: "ThumbnailFetcher(url: …), render as icon: …".
  * Photos items use the library's preview or thumbnail files (`previewRelativeComponents` / `thumbnailRelativeComponents`).
  * Images are cached in `ThumbnailCache` and served through Kingfisher [O].

---

## 7. Reimplementation constants (summary)

| Item | Value |
|---|---|
| Min file size (dups & similar) | 102 400 B |
| Min file size (LAOF, for reference) | 50 MiB |
| Built-in ignore status | 7 (skipGrouping 1, skipHashing 2, skipEnumeration 4) |
| Enumerator concurrency | 16 |
| File hash | SHA-1; whole file if size ≤ 4 MiB, else 4 × 1 MiB samples at i·⌊size/4⌋ |
| Group key | (size, SHA-1) |
| Thumbnail for image analysis | max 256 px, with transform |
| pHash preconditions | max side ≥ 128, min side ≥ 32 |
| pHash | luma BT.709 → Sobel (÷8) magnitude → /255 → 32×32 → DCT-II → 8×8 incl. DC ≥ mean; ×4 rotations |
| Similar threshold | Σ Hamming over 4 hashes ≤ 15 |
| Noise | min eigenvalue of 8×8-patch covariance |
| Blur | variance of the full Haar transform |
| Dynamic range | 20·log10(max/min) |
| Best score | √((nNoise−1)² + nBlur²) + 0.3·nDR + 0.1·nW + 0.1·nH, descending |
| Best k | n≤3 → 1, 4–6 → 2, ≥7 → 3 |
| Fresh duplicates tile | last 90 days |
| Recent similars tile | last 30 days |
| Scan state throttle | `CountableScanState.init(minEstimatedUnitsCount:throttleInterval:)` (dups 0.3 s); similar task 0.5 [I] |
