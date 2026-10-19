# CleanMyMac 5 (MAS 5.7.1): Space Lens UI spec (bubble chart, list, review)

Built from static analysis of `SpaceLensUI.framework` (thin arm64 binary at `$S/bin/SpaceLensUI`; Ghidra output in `$S/lens/SpaceLensUI.c`; disassembly in `$S/lens/SpaceLensUI.dis`) and `SpaceLensModule.framework` (`$S/lens/SpaceLensModule.c`).
Evidence tags: **[O]** observed directly in code or data. **[I]** inferred from strong structural evidence. **[?]** a guess.
Addresses are SpaceLensUI unless prefixed `M:` (SpaceLensModule). Most Swift symbols are redacted, so many functions appear as `FUN_xxxx`.

---

## 0. TL;DR of the algorithm

1. Sort the current folder's children by size, descending. Keep the first 7 as "main". Then keep taking the next item while its size is greater than the sum of all items after it, up to 30 main items. Everything left over goes into one aggregate **"Smaller items"** bubble. The Module adds the special "Other items" / purgeable entries as `otherItems`.
2. Bubble radius = `(size + offset)^0.3`. This is a power law, **not** area ∝ size and **not** sqrt. A 10-iteration bisection finds `offset` so that no bubble ends up smaller than 48 pt in diameter.
3. Positions use **d3-hierarchy `packSiblings`** (front-chain circle packing), largest item first. Each circle gets padding of 12.5 % of its own radius. Then the minimal enclosing circle is computed, and everything is scaled and centered into a circle whose diameter is `min(viewWidth, viewHeight)`.
4. Only one level is drawn. Bubbles do **not** contain their grandchildren.

---

## 1. Bubble layout

### 1.1 Data model

`LevelInfo { currentItem, children:[SpaceLensItemViewModel], otherItems:[SpaceLensItemViewModel] }` is a plain struct. `LevelInfo.level(_:_:_:)` @3796c only wraps its arguments. **[O]**

* `M:FUN_0002276c` splits the Module's children. Any child whose flag byte `node+0x19` is set (the purgeable / "other" pseudo-item, built as `PurgeableSpaceItemViewModel` in `M:FUN_0001f964`) moves into `otherItems`. Everything else stays in `children`. **[O]**
* `SpaceLensItemViewModel(path:size:leavesCount:isDirectory:containsItems:)` has these flags: `isHiddenItem`, `isEphemeral`, `isProtected`, `isSystemFolder`, `protectionReason`, `protectionActionTitle`, and `selection: SpaceLensSelectionState {selected, unselected, partiallySelected}`. **[O]** (syms)

### 1.2 Main vs "smaller items" split: `FUN_000443f0` @443f0 **[O]** (assembly 0x44620–0x44948)

```
sorted = children.sorted(by: size, descending)          // FUN_0002d9e0, insertion/merge sort on vtbl+0x90 (size)
main   = Array(sorted.prefix(min(count, 7)))            // always the 7 biggest
rest   = sorted.dropFirst(main.count)
restSum = Σ rest.size
while let next = rest.first:
    if main.count > 29        { break }                  // cap: at most 30 main bubbles
    if restSum - next.size >= next.size { break }        // stop when next item <= sum of everything smaller
    main.append(next); rest.removeFirst(); restSum -= next.size
smaller = rest
```
* If `smaller` is non-empty, a `SmallerItemsSpaceLensViewModel(items: smaller)` is created (`FUN_0004154c` → `FUN_00032ab4`). Its size is the sum of the items' sizes, its leaves count is the sum of theirs, `isDirectory = true`, and its selection state is derived from its children. **[O]/[I]**
* Bubbles shown at one level: `main` (7–30), plus 1 Smaller-items bubble, plus the `otherItems` (usually 0–1). **[I]**
* The packer has its own hard cap. Only the **38** largest circles keep their radius; any circle at sorted index 38 or higher has `r /= 1000` before packing (`FUN_00002908`, arg `0x26`, `fdiv by 1000.0` @2a18). **[O]**

### 1.3 Radius (scaling) function

The layout object is created in `FUN_0001b7xx` (decompile line 22690, `BubblesCollectionView` setup). Its fields are **[O]**:

| field | value |
|---|---|
| `useFancyTransitions` (+0x10) | false (default) |
| `minimumRenderingItemsSize` (+0x20) | **48.0** pt |
| `scalingFunction` (+0x28/+0x30) | `.powerScaled(power: 0.3)` (enum tag 0) |
| `zoomingInfo` (+0x38/+0x40) | nil |

`ScalingFunction` (`FUN_00001bc8` @1bc8, assembly 0x1c0c–0x1ce4) **[O]**:
* `.powerScaled(power)` (tag 0): `r = pow(value + param, power)`. `param` is an additive offset.
* the second case (tag 1, no payload): `r = pow(value, param)`. Here `param` is the exponent.

`value` is the item size in bytes, converted to Double. The root's value is the sum of its children.

### 1.4 Layout driver: `FUN_0001aab0(rect, items, hideTooSmall, iterations=10)` **[O]**

Called with `iterations = 10` from 5 sites. `hideTooSmall` is 0 at 4 sites and 1 at 1 site (`FUN_00017adc`).

```
if rect.width <= 0 || rect.height <= 0: return [nil] * items.count
nodes = items.enumerated().map { Node(name:"Item \(i)", value: Double(item.size), r:0.5, x:0, y:0) }
root  = Node(name:"Root", value: Σ nodes.value, r: 0.5, x: 0, y: 0)       // FUN_000078b0: r=0.5, power=0.3
minSide = min(rect.width, rect.height)

// search range for the free parameter p
if scaling is tag1 (.power):   p0 = 0.333; lo = 0.01;  hi = 0.333
else (.powerScaled):           if nodes.empty { hi = 1 } else { hi = max(node.value) }
                               p0 = 2e-13; lo = 1e-13

best = nil; bestTooSmall = items.count; bestMin = +DBL_MAX
for it in 0..<iterations:
    p = (it == 0) ? p0 : (hi + lo) / 2
    pack(root, nodes, p)                                  // FUN_000079ec → FUN_00001bc8
    scale = minSide / (2 * root.r)                        // root.r == 0.5 → scale = minSide
    tooSmall = 0; minD = +DBL_MAX; frames = []
    for n in nodes:
        cx = rect.midX + scale * n.x ; cy = rect.midY + scale * n.y ; d = scale * 2 * n.r
        if !finite(cx,cy,d): frames.append(nil); continue
        minD = min(minD, d)
        if Int(d) < Int(48): tooSmall += 1; if hideTooSmall { frames.append(nil); continue }
        frames.append(CGRect(cx - d/2, cy - d/2, d, d))
    // choose best: fewer tooSmall wins; on a tie keep previous unless new minD < bestMin
    if tooSmall < bestTooSmall || (tooSmall == bestTooSmall && minD < bestMin): best = frames, ...
    if tooSmall > 0 { lo = p } else { hi = p }            // grow offset only if needed
return best
```
In effect, with `.powerScaled(0.3)` the first pass is an almost pure `size^0.3`. If any bubble comes out under 48 pt, the additive offset grows by bisection between 1e-13 and the largest child's size, which flattens the size differences until the small bubbles reach 48 pt.

### 1.5 `pack(root, children, p)`: `FUN_00001bc8` + `FUN_00002908` + `FUN_00001f04` **[O]**

This is a faithful port of **d3-hierarchy `pack()` for one level** (front-chain).

```
func pack(root, kids, p):
    if root.packed { return }
    if root.r == 0 { root.r = f(root.value, p) }            // root.r is preset to 0.5 → kept
    targetR = root.r
    for k in kids { k.r = f(k.value, p) }                   // f per §1.3
    packChildren(root, kids, maxCount: 38)                  // sets root.r = enclosing radius e
    k = targetR / root.r ; root.r = targetR
    for c in kids { c.x *= k; c.y *= k; c.r *= k }
    for c in kids where c.parent != nil { c.x += parent.x; c.y += parent.y }
    root.packed = true

func packChildren(root, kids, maxCount):                    // FUN_00002908
    s = kids.sorted { $0.r > $1.r }                         // insertion sort, descending (FUN_000050cc)
    for c in s.suffix(from: maxCount) { c.r /= 1000 }        // index >= 38 shrinks to near 0
    pad = s.map { $0.r * 0.125 }                            // padding = 12.5 % of own radius
    for i in s.indices { s[i].r += pad[i] }
    e = packSiblings(s)                                     // FUN_00001f04 (returns enclosing r)
    for i in s.indices { s[i].r -= pad[i] }
    root.r = e
```
`packSiblings` (`FUN_00001f04`, helper `place` = `FUN_00002db8`, chain score = `FUN_00002e94`) is **d3's front-chain algorithm**, with the same epsilon:
```
a=c[0]: a.x=0,a.y=0;               if n==1 return a.r
b=c[1]: a.x=-b.r; b.x=a.r; b.y=0;  if n==2 return a.r+b.r
place(b,a,c[2]); build circular chain a→b→c
for i in 3..<n:
  place(a,b,c_i)                    // tangent to a and b
  // look for an intersection on the chain: walk j=b.next, k=a.previous alternately, accumulating sj, sk radii
  intersects(x,y) := (x.r+y.r-1e-6) > 0 && dx²+dy² < (x.r+y.r-1e-6)²
  if it intersects j: a=a, b=j (remove nodes between), retry
  if it intersects k: a=k, b=b, retry
  insert c_i between a and b; then a := the chain node minimising score(node) where
     score(n) = |(n.x*n.next.r + n.next.x*n.r)/(n.r+n.next.r), (y likewise)|²  ; b = a.next
enclose(front-chain circles) → (ex,ey,er)                    // FUN_00016fb8 (Welzl / d3.packEnclose) [I]
for c in circles: c.x -= ex; c.y -= ey                       // centre the cluster
return er
```
Placement order is largest first, so the biggest bubble sits roughly in the centre and the rest spiral outward. Nothing in this code is random apart from the possible shuffle inside `enclose` **[?]**.

### 1.6 Depth / nesting
Only the direct children of `currentItem` are laid out. `pack` iterates a single `children` array, and no code renders grandchildren. **[O]**

### 1.7 Bubble rendering: `SpaceLensBaseItemLayer` / `SpaceLensItemLayer` / `SpaceLensSmallerItemsLayer`

**Shape.** The outline (stroke and mask path, `FUN_0000ab68`) is a fixed **squircle** drawn in a 260×260 design box. The constants are **[O]**: move to (130, 0.6352), then 8 cubic Béziers (to; c1; c2):
```
(224.121,35.879; 169.286,0.635; 201.615,13.374)   (259.365,130; 246.626,58.385; 259.365,90.714)
(224.121,224.121; 259.365,169.286; 246.626,201.615) (130,259.365; 201.615,246.626; 169.286,259.365)
(35.879,224.121; 90.714,259.365; 58.385,246.626)   (0.635,130; 13.374,201.615; 0.635,169.286)
(35.879,35.879; 0.635,90.714; 13.374,58.385)       (130,0.635; 58.385,13.374; 90.714,0.635)  close
```
The path is scaled from 260×260 to the bubble bounds after `CGRectInset`. It is a superellipse with n ≈ 2.16, which matches `squircleExponent`.

**Fill.** The fill is a bitmap. Asset catalog images are 262×262 pt @1x / 524 @2x: `Default`, `Default_Hover`, `Selected`, `Selected_Hover`. The cloud variant uses `Clouds_Default`, `Clouds_Default_Hover`. The aggregate bubble uses `Smaller Items`, `Smaller Items_Hover`, `Smaller Items_Focused`, `Smaller Items_Focused_Hover` (260 pt). `Other-Items-Icon` is 46 pt. **[O]**
Image choice (`FUN_00009de8`): `selected ? (hover ? Selected_Hover : Selected) : (hover ? Default_Hover : Default)`. The background layer has opacity 0.5 when `semiTransparent`, otherwise 1.0. **[O]** `semiTransparent` is probably used for protected/essential items **[?]**.

Files and folders get the same bubble images. They differ only by the icon (the file icon at 256×256, from the image loader's NSCache) **[O]**. The colour difference is between the **Space Lens** look (purple) and the **Clouds** look (blue).

**`BubbleUIConfig.spaceLens`** (`FUN_00008994`; field offsets from `FUN_0000a5e4`) **[O]**:

| field | value |
|---|---|
| strokeColorDefault | rgba(0.62, 0.38, 1.0, 1) (purple) (clouds: rgba(0.384, 0.62, 1.0, 1)) |
| strokeColorSelected | rgba(1.0, 0.51, 0.92, 1) (pink) |
| strokeWidthDefault / Highlighted(hover) / Focused | 1 / 5 / 8 |
| strokeWidthMultiplier | 2 |
| strokeWidthMaxDivisor | 6 |
| checkmarkRadius | 17 |
| checkmarkBoxSize | 14 |
| checkmarkBoxCornerRadius | 3 |
| checkmarkBoxLineWidth | 1 |
| checkmarkIconInsets | 2 |
| squircleExponent | 2.16 |
| checkmarkAngleDegrees | 40 |
| checkmark fill/stroke colours (default and selected) | 4 system NSColors **[?]** |
| checkmarkImageSelected / Default, checkmarkEnabled | present |

Stroke width = `min(base * 2, bounds.width / 6)`, where `base` is 8 if focused, 5 if hovered, else 1. The stroke uses the stroke layer's mask, so roughly half of it is visible inside the bubble **[I]**. The colour is the Selected colour if the item is selected, otherwise the Default colour. **[O]**

**Checkmark accessory** (`SpaceLensCheckmarkLayer`, position in `FUN_0000bba0`) sits on the squircle rim at 40° from horizontal:
`inset = min(2, w/6)`; `t = tan(40°)`; `x = R / (1 + t^n)^(1/n)`; `y = x·t`; `pos = (midX + x, midY ∓ y)`, where n = 2.16. The visual is a 14 pt rounded box (corner 3, line 1) inside a 17 pt-radius circle. It updates on `(checkmarkEnabled, hovered, selected, partiallySelected, focused, highlighted)`. **[O]** for the inputs, **[I]** for when it is visible: on hover, or when selected or partially selected.

**Labels.** `SpaceLensItemLayer` uses `FUN_0000d540`. Its init (`FUN_0000d13c`) sets `minimumFontSize = 11`, `maximumFontSize = 90`, `minimumSizeForTwoLayeredText = 115`, `fontSizePercent = 0.05`. **[O]**
```
w = bounds.width
fontSize = clamp(max(sqrt(w), 1), 11, 90)
textHidden = (max(sqrt(w),1) < 11) && (w < 80)          // => text shown when the bubble is at least 80 pt
textFrame  = bounds.insetBy(dx: w/6, dy: h/4).offsetBy(0, -h/2.5)     // lower part
text = (h >= 115) ? text /*two lines: name + size*/ : firstLineText /*name only*/   [I for content]
iconFrame  = textVisible ? bounds.insetBy(w/3.3333, h/3.3333).offsetBy(0, h/10)   // 40 % icon, raised
                         : bounds.insetBy(w*0.25, h*0.25)                         // 50 % icon, centred
```
`SpaceLensSmallerItemsLayer` (`FUN_0000e938`) uses the same 11/90/115 values plus **`minimumSizeForSecondaryText = 130`**. It shows `text` and also a `secondaryText` line (size **[I]**) when the bubble is at least 130 pt. Its content is image + text + secondaryText. **[O]** The exact title string comes from the VM **[?]** (possibly a count like "N items").
"Other items" bubble and row: the title is `space_lens_bubbles_section_other_item_title` = "Other items", with icon `Other-Items-Icon`. **[O]**

### 1.8 Hover tooltip: `BubblesTooltipPopoverController` + `BubblesTooltipView` **[O]**
* Mouse moved over a bubble (`FUN_00018a70`): show the tooltip at `(mouse.x + 13, mouse.y − 21)`, not animated, after a **0.025 s** delay (`FUN_0001d49c`).
* Mouse leaves a bubble or moves to the background: hide after **0.5 s**.
* Keyboard focus (`FUN_0001c0c8`): place the tooltip at the focused bubble's `position.x + width/3`, animated.
* The popover has `behavior = 2` (semitransient), and the controller cancels any pending show/hide when a new request arrives.
* View fields are `titleLabel`, `warningLabel`, and a `stackView` of rows (`leftLabel | divider | rightLabel`). Strings: `Size: %@`, `Selected: %@`, `Entire folder` (fully selected folder), `Modified: %@`, `System folder` (warning), and for Other items `Various files and folders taking up space`. **[O]** strings. Row arrangement **[I]**.

### 1.9 Animations / drill-down transitions **[O]**
* Fade-in: opacity 0→1 over **0.49 s**, timing `cubic(0.24, 0.70, 0.39, 0.91)`. Fade-out: opacity 1→0 over 0.49 s, timing `cubic(0.53, 0.62, 0.20, 1.0)` (`FUN_00008008` / `FUN_00008198`).
* Transform/zoom: **0.7 s**, timing `cubic(0.4, 0.6, 0, 1)`, `fillMode = forwards`, `removedOnCompletion = false` (`FUN_00008320`). There is also a 0.3 s ease-in-ease-out basic animation (`FUN_00008xxx` @ line 8384) for state changes.
* "Fancy" transition (`FUN_00014418`, `BubbleCollectionViewTransition{appearingItems, disappearingItems, zoomingItem, transitionBounds, layout}`). Bubbles fly along a **spiral** `CAKeyframeAnimation("position")` path, key `"spiralAppear"` (and its disappear twin), duration 0.7 s, plus a `"fadeIn"` opacity animation. The path is sampled from a 101-entry easing table `e[]` (data @0x6c548: 0, .0264, .0525 … e(.1)=.2487, e(.25)=.5445, e(.5)=.8391, e(.75)=.967, e(1)=1, roughly `1-(1-t)^2.6`):
  * appear: `r(t) = r0 + (r1 − r0)·e(t)`, `θ(t) = θ1 − 1.4π·(1 − e(t))`, where θ1 = `atan2(final − centre)`
  * disappear: `r(t) = r0 + Δ·e(t)`, `θ(t) = θ0 + 1.4π·e(t)`
* While `activatAnimationsCount > 0`, mouseUp, menu and double-click are ignored.

---

## 2. Interaction **[O]** unless tagged

| input | behaviour (evidence) |
|---|---|
| Click bubble (mouseUp) | `FUN_00019058`: hit-test the item. If the point is inside the item's **accessory (checkmark) layer** frame (`FUN_00018194`), **toggle selection** (`FUN_0001e138`). Otherwise **open the item** (`FUN_0001e394` → `FUN_000431f4`): call `viewModel.open(item)` (witness +0x30) and notify the delegate. If the item is the purgeable/"other" special item, show its popover instead (`FUN_00028a60`). Folders drill in. Files probably do nothing or open a tooltip **[I]**. |
| Selection toggle on aggregate | Setting the Smaller-items bubble also sets each child unless that child is protected (vtbl 200/0xc0 checks). |
| Double-click empty background | `handleBackgroundDoubleClick:` → `FUN_000431ec` → `viewModel` witness +0x40, which goes **up one level / back** **[I]**. |
| Right-click | `menuForEvent:` → delegate builds a context menu with accessibility id ("…ContextMenu", 16 chars). Builders added in `M:` ctor: **Select "%@"** / **Deselect "%@"**, **Quick Look "%@"**, **Reveal in Finder**, **Get Info** (ModuleCore `SelectMenuItemBuilder`, `DeselectMenuItemBuilder`, `addQuickLook`, `RevealInFinderMenuItemBuilder`, `GetInfoMenuItemBuilder`). The menu on the background is the view's default menu. |
| Quick Look | `SpaceLensQuickLookViewModel.showPreviewPanel(for:[URL])` publishes `onPreviewRequested`. `SpaceLensContextMenuController` is the `QLPreviewPanel` controller (`acceptsPreviewPanelControl`). |
| Hover | Sets `currentlyHighlightedIndex` → `Default_Hover` image, stroke width 5, and the tooltip. |
| Back / Forward buttons | `SpaceLensNavigationHistory` (§2.1). Buttons are 24×24 with images `navigation-button-back/forward` (8×16). |
| Breadcrumbs | `pathControl` (NSPathControl, target-action to the VC) inside `pathControlContainerView`. Clicking a component navigates to that ancestor **[I]**. |
| List keyboard | `handleSpacebarKeyDown`: toggle selection of all selected rows that are not protected, then reload them. `handleLeftArrowKeyDown` / `handleRightArrowKeyDown`: collapse/expand or go up/into **[I]**. |
| Review screen | **Esc** (keyCode 0x35, no modifiers) → `cancel()` (`SpaceLensReviewItemsViewController.keyDown` @39d90). |

### 2.1 `SpaceLensNavigationHistory` @35e98… **[O]**
State: `index = -1`, `history: [Item] = []`.
* `canGoBack = history.count > 1 && index > 0`; `canGoForward = history.count > 1 && index != history.count - 1`.
* `addToHistory(x)`: if `index < count - 1`, drop everything after `index`. Then append `x` and set `index = count - 1`.
* `updateHistory(with x)`: if `x` (same path) is already in the history, set `index` to its position. Otherwise, if at the end, call `addToHistory`. Otherwise truncate after the current entry (`FUN_00035bec`) and call `addToHistory`.
* `previousItem()` / `nextItem()` move `index` by 1. `resetAndUpdate(to:with:)` and `findItem(for:)` also exist.

---

## 3. List side panel: `SpaceLensListViewController` / `SpaceLensOutlineView`
* Outline setup (`FUN_00028424`) **[O]**: no header, `rowHeight = 40`, `selectionHighlightStyle = none`, `indentationPerLevel = 0` (cells apply their own `indentation`), `style = .plain(4)`, `intercellSpacing = (0, 4)`, `allowsEmptySelection`, overlay scroller, transparent background. Row views have corner radius 8 (`outlineView(rowViewForItem)` @2ac6c) **[I]**.
* Root rows (`FUN_0002f7f0`) **[O]**: `mainItems.count + (smallerSection != nil ? 1 : 0) + otherItems.count`, in that order. Only the smaller-items section is expandable. Its children are its items (`+0x28`), and expanding it sends `didChangeSmallerItemsSectionExpansionState`. The section cell has `indentation`, `chevronButton` (images `chevron` / `chevron-expanded`), `titleButton`, `sizeLabel`, `onClick`, `onHoverChanged`. The "Other items" row title is `space_lens_list_section_other_item_title` = "Other items".
* Sort order: the same descending-by-size order as the bubbles (shared split `FUN_000443f0`) **[I]**.
* `SpaceLensFileItemCellView`: `indentation`, `actionView` (selection checkbox), `icon`, `titleLabel`, `sizeLabel`, `onHoverChanged`. It reacts to `rowViewHoverDidChange` and `rowViewSelectionDidChange`. Protected items show the `space_lens_list_info_essential_item` info ("This is an essential system item and it cannot be deleted.").
* `CloudStatusSpaceLensFileItemCellView` adds `statusImage` (cloud icon, tooltip "Cloud files"), `statusImageTooltipText` and an `infoPopoverDelegate`. Hovering the status image shows a popover (`statusImageHoverChanged:`). Evicted (cloud-only) items show the protection reason "This item is cloud-only. Manage it in Cloud Cleanup Module." (M strings).
* **Size formatting**, `DefaultSpaceLensSizeFormatter` @332e4 **[O]**: `NSByteCountFormatter` with `allowedUnits = KB|MB|GB (0x0E, no bytes, no TB)`, `countStyle = .file (decimal)`, `includesActualByteCount = false`, `includesUnit = true`. `string(fromCount:)` returns the plain integer `"\(n)"`. The VC/footer/review "selected items" formatters use the same settings.

---

## 4. Selection & review
* `SpaceLensSelectionState`: `selected | unselected | partiallySelected`. A folder becomes partial when only some descendants are selected **[I]**.
* `SelectedItemsInfo { items: Int, size: Int64 }` (Equatable).
* `SpaceLensSelectionOptionViewModel(title:)` and `SpaceLensSelectionDisplayInfo(title, subtitle, items:[option])` feed `selectionView`, which is a `DesignSystem.SelectionControlView` ("Select ▾" control). Its options/state strings come from ModuleCore: Select All / Deselect All, and states None / All / Manually **[I]**.
* **Footer** (`SpaceLensFooterView`): `valueLabel` (selected size), `itemsLabel` (count), `actionsButton`, `infoButton` + `infoButtonText`, `height`. Laid out with height **64**, leading/trailing to the superview, bottom −4 **[O]**. Button title is "Review and Remove" (`spacelens_results_review_button_title`) or "Remove". The info popover text is "This includes items from all selected folders." **[O]** strings. Enablement and which title appears when **[I]**.
* **Review** (`BaseSpaceLensReviewViewModel(title:activeButtonTitle:infoPopoverTitle:items:)` with `selectedItemsInfo`, `isActiveButtonEnabled`, `performAction()`, `cancel()`, `onPerformAction`, `onCancel`, `image`, `moduleColor`). `SpaceLensReviewItemsViewController(viewModel:innerViewModel:)` uses `DefaultReviewScreenListViewModel` (`mainItems`, `url(for:)`, `onPathControl`). Review rows have `indentation`, `actionView`, `icon`, `titleLabel`, `sizeLabel`, `pathControl`, `pathControlOpenButton` and `pathStackView`, so each item shows its path. Strings **[O]**: title "Review Items Before Removal" / "Review files before removal", button "Remove", system-folder checkbox text "This folder is required for the system to operate. It's not recommended to remove system folders". Before removal, a cloud alert appears: "Selected files will also be removed from the cloud" / "Continue" / "Change Selection" / "Don't show again this session".
* **Cleanup complete** (`SpaceLensCleanupCompleteViewController.makeCleanupSuccessView(info:)` @84d0) **[O]**: sets the title, a description string split on `"|"` with the first part coloured (for example `<size>|successfully removed`), an icon, and a button. Strings: "Removal complete!", "successfully removed", "Review More Items", "Done". Failure: "Removal failed...", "Some files were not removed. Please make sure none of your apps are using them and try again.", "Try again". In progress: "Removing files...".

---

## 5. Screen layout: `SpaceLensView.buildLayout` @3b768 (SnapKit, source lines 0x38–0x91)
Maker vtable offsets were mapped as 0x68 = top, 0x70 = bottom, 0x80 = leading, 0x88 = trailing, 0x90 = width, 0x98 = height, 0xa0 = centerX. **[I]** for the mapping, **[O]** for the numbers.

| view | constraints |
|---|---|
| `diskInfoView` (usage bar "%@ of %@ used" with Used/Free/Purgeable/Selected tooltip) | top +14, leading +16, width 384, height 36, bottom −16 @750 |
| `leftContainerView` (glass `fluxBackgroundForLeftContainer`) | top +14 (below disk info), leading +16, **width 384** |
| ├ `currentItemView` (icon, titleLabel, sizeLabel, divider, itemsLabel = current folder name, size, item count) | top, trailing, height |
| ├ `selectionView` | top +4, leading +8, height 32, width offset 8 |
| └ list VC view | top +8, leading +8 (`FUN_0003d154`) |
| bubbles VC view | leading +16, trailing −16, top +16, bottom (`FUN_0003d330`), filling the area right of the left panel. The bubble circle diameter is `min(w,h)` of this view, centred. |
| `pathControlContainerView` (glass `fluxBackgroundForPathControl`) | top/leading/width/height (=) @1000 |
| ├ `backButton` / `forwardButton` | 24×24; forward: top +12, leading +4 after back |
| └ `pathControl` | centerX @750, leading +12, trailing −12, top +12, bottom −12, height 24 |
| `footerView` | leading/trailing to the superview, bottom −4, **height 64** |

Proportions: a fixed 384 pt left panel (inset 16) and a flexible bubble canvas on the right. Breadcrumbs with back/forward sit on a glass bar over the canvas. The footer spans the full width at the bottom. **[I]** for the exact anchors.

Empty state (Module): "Too empty to visualize..." / "Try scanning a more substantial folder to preview its contents." / "Start over". Purgeable bubble: "Purgeable Space", whose popover offers "Clean Purgeable Space".
