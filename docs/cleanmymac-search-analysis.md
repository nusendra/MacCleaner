# How search works in CleanMyMac 5

Target: `/Applications/CleanMyMac_5_MAS.app`, version 5.7.1, arm64 slices.
Method: static analysis only. I used `nm` with `swift-demangle`, Swift reflection metadata (`__swift5_reflstr`), `otool`/`llvm-objdump` disassembly and bind tables, and Ghidra 12.1.4 headless decompilation. I never ran the app under instrumentation.

Legend: **[O]** observed directly in the binary, **[I]** inferred from the code, **[?]** unresolved.

## Two separate search systems

| | Toolbox search (global "find a tool") | Node filter (inside a module's result list) |
|---|---|---|
| Binary | `ToolboxModule.framework`, which embeds a `LookupService` module | `ModuleCore.framework` + `NodesCore.framework` |
| Matching | Weighted token index with scoring and ranking | `localizedCaseInsensitiveContains` on `Node.searchableDescription` |
| Debounce | 150 ms on the main queue | `largeTreeSearchDebounce` = 500 ms |

## 1. Toolbox search (`LookupService`)

### Types [O] (from symbols and reflection field names)

```
WeightedStrings      { weight: Int, values: [String], tag: String? }
LookupDocument<ID>   { id, sources: [WeightedStrings] }
LookupMatch<ID>      { id, score: Double, matchedTags: Set<String> }
LookupIndexedSource  { weight, tag, tokens, normalizedValues }
LookupIndexedRecord  { id, sortOrder, sources }
LookupScoredRecord   { match, sortOrder }
LookupIndex          { records }
LookupTokenizer      { separatorCharacters }
LookupTextNormalizer { }            // no stored fields
LookupScoringPolicy  { }            // no stored fields; constants are inline
LookupEngine         { normalizer, tokenizer, scoringPolicy, index }
LookupClient         actor { engine }   // has $defaultActor
LookupClientFactory.make<A>()
```

`ToolboxIntroViewModel` has these fields: `_lookupQuerySubject`, `lookupClient`, `lookupBootstrapTask`, `isInSearchSession`, `hostedCardSearchDescriptors`. Its states are `results`, `browsing` and `pending`.

### Pipeline

1. **Normalize** [O] (`FUN_0003a7b8`): `query.folding(options: 0x181, locale: Locale.current)`. `0x181` is `caseInsensitive | diacriticInsensitive | widthInsensitive`. The result is then lowercased (`String.lowercased()`).
2. **Tokenize** [O] (`FUN_0003e3cc` closure, `FUN_0003e4cc`): every unicode scalar in `separatorCharacters` becomes `" "`. The text is joined, then split on spaces with `maxSplits: Int.max` and empty pieces omitted. `FUN_0003a320` then de-duplicates tokens in first-seen order. The separator set is built from `alphanumerics.union(whitespacesAndNewlines).inverted` [O: call order at 0x3a644–0x3a680].
3. **Token score** [O] (`FUN_0003dbb0`): for each query token, check every token in the source:
   - `==` → **1.0**
   - `candidate.hasPrefix(q)` → **0.82** (constant `0x3FEA3D70A3D70A3D`)
   - `candidate.contains(q)` → **0.5**
   - The best value wins.
4. **Source score** [O] (`FUN_0003ddac`): `Double(source.weight) * tokenScore`. The best source wins, and its `tag` is added to `matchedTags` (`FUN_0003d320`).
5. **Record score** [O] (`FUN_0003d0ac`):
   - Every query token must match some source. If any token returns nil, the record is dropped, so the query behaves as an AND.
   - The token scores are summed.
   - Phrase bonus **+5.0** (`FUN_0003df6c`): applied when the query has `count > 1` and some source's `normalizedValues` element `contains` the query.
   - If the total is `<= 0`, the record is not a match.
   - The engine checks `Task.isCancelled` while it loops, so a newer query can abort an older one.
6. **Rank** [O] (`FUN_0003af14`): sort by `score` descending; ties go to `sortOrder` ascending, which is document order.

### Field weights [O] (`FUN_0000bb80`, tool documents built from `CustomFlowSearchPayload`)

| tag | weight |
|---|---|
| `title` | 120 |
| `module_name` | 110 |
| `description` | 60 |
| `search_keywords` | 50 |
| `flow_keywords` | 40 |
| `shared_keywords` | 25 |

Hosted cards (`FUN_0000c274`) use two sources with weights **120** and **50**: title and keywords [I: tag strings not traced].

The keyword lists are localized strings. Their keys include `custom_flow_uninstaller_search_keywords` and `custom_flow_leftovers_search_keywords` (see the strings in `ApplicationsModule`).

### UI wiring [O]

- `ToolboxIntroViewModel`: query subject → `debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)` (`0x1f88c`: `mov w0,#0x96`). A second pipeline uses `removeDuplicates()` → `debounce` on `UIScheduler` [? interval].
- Analytics: `trackSearch(query:hasResults:toolsOrder:)` and `trackCancelSearch`.
- `ToolboxIntroEmptySearchView` shows the empty state, and the `toolsSectionHeaderResultsFound` string labels the results header.

## 2. Node filter (`ModuleCore`)

- `SearchComponentView` (`NSSearchField`) → `SearchComponentState.searchString` → `NodeDataManagerViewModel.update(searchText:)` → `searchFilterSubject` → `SearchNodeFilter(searchTerm:name:filter:)` [O].
- `SearchNodeFilter.matchIfSelfOrAnyChildrenMatches()` and `matchSelfOrAnyParentOrChild(upTo:)` keep a node visible when it or a descendant matches [O: symbols; I: semantics from names].
- Matching uses `StringProtocol.localizedCaseInsensitiveContains` on `Node.searchableDescription`. It is the only text-match import in ModuleCore/NodesCore [O: bind table].
- `NodeDataManagerViewModel.largeTreeSearchDebounce` = `.milliseconds(500)` (`0xbe9f4`: `mov w0,#0x1f4`) [O].

## Open questions

- The interval of the second (`UIScheduler`) debounce.
- The exact tag strings for hosted-card sources.
- The separator set includes whitespace only through the final split on `" "`. Tabs and newlines inside one value are not split [I]. The rebuild treats all non-alphanumerics as separators.
