# Codebase Concerns

**Analysis Date:** 2026-05-24

> Snapshot of the Souffleuse codebase right after commit `6ad70df`
> ("Parite Cotypist : reactivite, qualite ghost, activation AX Electron (WIP)").
> Source of record for the gap analysis: `NEXT-MILESTONE-NOTES.md`. Most items
> below are corroborated by `Souffleuse/ARCHITECTURE.md` and the source.

## Tech Debt

**No KV-cache / no TokenizationCache (full re-encode every keystroke):**
- Issue: Every `predict()` re-tokenises the full prompt and recomputes all
  transformer K/V from zero. Cotypist's binary exposes `TokenizationCache`,
  `TokenSequence`, `kvCache`, `sequenceManager`, `reuseThreshold` — Souffleuse
  has none of that infrastructure; the only memo is a 32-entry FIFO
  `predictCache` of *output strings* keyed on the userTail prefix.
- Files: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:74-79`
  (output cache + capacity), `:368-477` (predict path — re-builds prompt,
  re-runs the iterator from scratch),
  `Souffleuse/Sources/SouffleuseBench/Bench.swift` (no incremental TTFT
  metric).
- Impact: TTFT plateau around ~150 ms (per `NEXT-MILESTONE-NOTES.md`). The
  string memo can hide it for repeat prefixes but every fresh keystroke
  pays the full encode + prefill cost. Blocks any move to larger models
  (Qwen 3 1.7B / Gemma 3 4B already too slow on M1 base).
- Fix approach: introduce a `SequenceManager` deciding reuse-vs-re-encode
  per delta, a `TokenizationCache` keyed on stable prefix prefixes, and a
  custom `TokenIterator` that threads `KVCache` state between predicts.
  Scoped as the next milestone in `NEXT-MILESTONE-NOTES.md`.

**Char-based prompt truncation, no per-category token budget:**
- Issue: User tail capped at 2048 chars (line `:369`), enrichment block is
  dumb-concatenated, custom instructions appended verbatim — no token
  accounting and no per-category budget. Cotypist exposes `tokenBudget`,
  `maxPromptTokens`, `contentBudget`.
- Files: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:369`,
  `:486-513`, `Souffleuse/Sources/SouffleuseContext/ContextEnricher.swift`
  (returns a single `prefix` string, no slot metadata).
- Impact: Adding `afterCursor` / field metadata or longer few-shot blocks
  is impossible without random truncation. Long custom instructions can
  silently squeeze the user tail.
- Fix approach: replace char cap with `Tokenizer.encode` + slot allocator
  (`currentPrefix`, `recentInputs`, `fieldContext`, `personalizationFewShot`).
  Pair this with the KV-reuse work so slots have stable byte ranges.

**`PredictorViewModel.swift` is a 870-line god class:**
- Issue: One file owns load lifecycle, predict, FIFO cache, undo-as-ghost,
  prefix overlap stripping, language detection, anti-repeat filter, n-gram
  routing, few-shot retrieval injection, custom `TokenIterator` chaining,
  IT vs PT branching, AppDelegate-facing API, and debug logging. Many of
  these have no shared state but are wired through `self`.
- Files: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift` (870
  lines).
- Impact: Future Cotypist-parity work (multi-candidate scoring, constrained
  decoding, store-without-acceptance learning per
  `NEXT-MILESTONE-NOTES.md`) will land here and bloat further.
- Fix approach: extract three peer units before the KV-cache milestone —
  `PromptBuilder` (system prompt + few-shot + custom instructions + slot
  budget), `SuggestionFilter` (prefix overlap strip, anti-repeat,
  markup strip, word/sentence truncation), and `PredictCache` (FIFO +
  undo-key search). `PredictorViewModel` then just orchestrates the MLX
  call.

**`SouffleuseAppDelegate.swift` is the 1188-line tick loop:**
- Issue: AppDelegate owns the tick loop, status item, hotkey monitor,
  preference observation, AX gating, focus snapshotting, caret rect
  caching, OCR refinement plumbing, debounce scheduler, partial-accept
  state machine, emoji/typo branching, live-consume logic, history
  recording. The `tick()` function alone runs ~450 lines.
- Files: `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift`,
  notably `tick()` starting at `:529` and `handleKey()` starting at `:975`.
- Impact: Every Cotypist-parity feature lands as another branch in `tick()`.
  Hard to test (no unit coverage on tick itself; coverage is on the helpers
  it calls). State invariants between `partialRemainder`,
  `partialAcceptedSoFar`, `partialAcceptedAtPrefix`,
  `partialAcceptedAtBundleID`, `lastPredictedPrefix`, `currentTypo`,
  `dismissedForText` are encoded only in comments.
- Fix approach: extract a `TickPipeline` actor/struct with explicit phases
  (gates → focus → caret → enrichment → live-consume → predict → render)
  and a `PartialAcceptState` value type that owns the four `partial*`
  vars together so they can't drift out of sync.

**`AXClient.swift` mixes 9 force-casts of CFType ↔ `AXUIElement`:**
- Issue: 13 instances of `as!` cast from `AnyObject` to `AXUIElement` /
  `AXValue` (see results below). Correct at runtime per AX API contract,
  but any future API mistake (passing the wrong attribute key) crashes
  the daemon instead of degrading.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:173, 264, 289,
  313, 332, 366, 391, 413, 492, 632, 645, 646`,
  `Souffleuse/Sources/SouffleuseContext/AppContextProbe.swift:96, 100`.
- Impact: A single bad attribute query (`copyAttr` for a non-element
  attribute) crashes the menu-bar app. Crash kills typing pipeline for
  the user until relaunch.
- Fix approach: wrap each access in a `guard let casted = raw as?
  AXUIElement else { return nil }` and bubble the `nil` up as a soft
  failure. `AXValue` casts can use `CFGetTypeID(ref) == AXValueGetTypeID()`
  before the cast.

**Synchronous `usleep` inside CGEventTap callback path:**
- Issue: `backspaceAndInjectViaCGEvent` and friends call `usleep(50_000)`
  / `usleep(5_000)` / `usleep(2_000)` from the `axClient.queue` dispatched
  by `tick()` and key-handler completion. Tab+inject latency is therefore
  bounded by `5_000 + N * 2_000 + 5_000` microseconds per replace.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:188, 224, 238,
  242`.
- Impact: Replacing a 10-char typo takes 30 ms of mandated sleeps before
  the first event posts. Sequential typo corrections feel sluggish.
- Fix approach: replace the inter-event spinlock with a CGEvent batch
  posted in one go, or move the dispatch to `DispatchQueue.asyncAfter`
  and event-stamp each event so the kernel orders them.

## Known Bugs

**Signal Desktop refuses AX activation:**
- Symptoms: Souffleuse's `ensureAccessibilityActivated()` sets
  `AXEnhancedUserInterface` + `AXManualAccessibility` and registers a
  no-op `AXObserver`, but Signal Desktop still returns `text=nil` for
  the focused element. Cotypist succeeds; mechanism not identified yet.
- Files:
  `Souffleuse/Sources/SouffleuseAX/AXClient.swift:95-140`
  (`ensureAccessibilityActivated`),
  `NEXT-MILESTONE-NOTES.md` "Limitations connues".
- Trigger: Open Signal Desktop, focus the message composer, type.
  Souffleuse stays silent — see `/tmp/souffleuse-tick.log` `tick_gate_fail
  reason=no_text`.
- Workaround: None. Slack / Discord / VSCode respond once activated; only
  Signal remains opaque. Tracked as a future milestone.

**Notes / Mail "duplicate insertion" on AX selection-replace path:**
- Symptoms: Setting `kAXSelectedTextRangeAttribute` returns `.success` in
  Notes / RichTextEdit but the host silently ignores the range. The
  subsequent `kAXSelectedTextAttribute` set then inserts at caret instead
  of replacing, producing `BonjouBonjour`-style duplications.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:198-244`
  (`replaceTrailing` / `backspaceAndInjectViaCGEvent`).
- Trigger: any typo correction or emoji shortcode replacement in those
  hosts.
- Workaround: Already in place — `replaceTrailing` deliberately skips the
  AX range path and posts N CGEvent backspaces + a Unicode insert
  instead. Reliable but slow (see Performance section).

**Brave / Chrome / Edge web fields: no AX caret bounds:**
- Symptoms: Chromium-based browsers refuse
  `kAXBoundsForRangeParameterizedAttribute` for web content. AX returns
  degenerate rects like `(0, 900, 0×0)`.
- Files: `Souffleuse/Sources/Souffleuse/CaretResolver.swift` (4-layer
  fallback), `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift`
  (Vision-based recovery), `CaretEstimator` in
  `Souffleuse/Sources/SouffleuseOverlay/CaretEstimator.swift`.
- Trigger: Typing in any Chromium contenteditable surface (Gmail,
  Intercom, Notion web, …).
- Workaround: OCR refinement path + per-bundle calibration cache. Cost is
  50-300 ms one-shot per bundle, then cached for 2 s. Has a hard
  rejection band: if `elementRect.width > 1400 || elementRect.height >
  600`, OCR is skipped (Brave occasionally returns the whole document
  rect, which would lock OCR onto conversation history above the input —
  see `OCRCaretLocator.swift:75-78`).

**Cached caretRect can survive a host scroll / zoom / reflow:**
- Symptoms: After `lastCaretRectByApp[bundleID]` is populated, host events
  that move the caret without an AX bounds re-emit (Brave zoom, Intercom
  scroll) leave the ghost painting at the stale screen coordinates.
- Files: `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:67-78`
  (cache + TTL), `:639-649` (cache read).
- Trigger: Type, scroll the page, type again.
- Workaround: 1.2 s TTL on cached rects (`caretRectTTL` at `:78`). Past
  that the ghost hides rather than paint wrong. Real fix requires either
  AX notifications wired into the cache invalidator, or per-keystroke
  bounds re-query.

**`UserDefaults.standard` direct access for `onboardingDone`:**
- Symptoms: `shouldShowOnboarding()` and `showOnboarding()` read/write
  `UserDefaults.standard` directly, bypassing `PreferencesStore`. If the
  user clears preferences in `Préférences` no onboarding key is reset.
- Files: `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:221,
  230`.
- Trigger: Edge-only; onboarding has already been seen, user wipes
  preferences. Onboarding never re-appears even on permission loss.
- Workaround: Add `onboardingDone` to `PreferencesStore.K` and route
  through the store.

## Security Considerations

**Per-app blocklist depends on three separate hard-coded lists:**
- Risk: Sensitive bundles (1Password, Keychain, banking) appear in three
  places:
  1. `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:34-44`
     (`bundleBlocklist` — gates the LLM ghost).
  2. `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:19-32`
     (`personalizationBundleBlocklist` — gates history recording).
  3. `Souffleuse/Sources/SouffleuseContext/ClipboardReader.swift:11-24`
     (`defaultBlocklist` — gates clipboard reading).
  The three lists overlap but don't match exactly (e.g. `com.lcl` is
  in personalization + clipboard, not in `bundleBlocklist`).
- Files: see above.
- Current mitigation: `ClipboardReader.mergedBlocklist()` adds a user-
  supplied file at `~/Library/Application
  Support/Souffleuse/clipboard-blocklist.txt`. Secret heuristic in
  `TypingHistoryStore.append()` rejects history entries that look like
  tokens/keys.
- Recommendations: extract a single `BundleBlocklist` module in
  `SouffleuseAX` (or a new `SouffleusePrivacy` lib) with three labeled
  sets ("never ghost", "never record", "never read clipboard") and import
  it from all three sites. Add an integration test that asserts every
  banking-app prefix is in all three sets.

**Secure-text-field subrole is checked, but only at the AX snapshot, not
on inject:**
- Risk: `AXSnapshot.isSecureField` is honoured in the tick gate
  (`SouffleuseAppDelegate.swift:567-572`), but the inject path
  (`AXClient.inject()` at `Souffleuse/Sources/SouffleuseAX/AXClient.swift:165-196`)
  also re-checks `kAXSubroleAttribute`. The CGEvent fallback
  (`injectViaCGEvent`) does NOT, because by then we've lost the AXElement
  reference. A racey focus change between the AX inject attempt and the
  CGEvent fallback could theoretically post characters into a secure field.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:165-196, 246-260`.
- Current mitigation: tick gate runs at 80 ms cadence and re-snapshots
  before each ghost; race window is small.
- Recommendations: re-snapshot the focused element from `injectViaCGEvent`
  too and bail if the subrole flipped to `AXSecureTextField` since the
  decision to inject was taken.

**`/tmp/souffleuse-predict.log` and `/tmp/souffleuse-tick.log` capture
user text when env-gated:**
- Risk: `PredictDebug.log` and the tick logger both write raw user input
  (prefix, snapshot, AX bundle, caret rect) to predictable
  world-readable temp paths when `SOUFFLEUSE_PREDICT_LOG` is set.
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:14-36`,
  `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:550-564,
  573-594`,
  `Souffleuse/Sources/SouffleuseAX/AXClient.swift:131-139`.
- Current mitigation: explicitly env-gated; comments say "NEVER use in
  production builds". `audit.sh` enforces no-`print`/no-`NSLog`/no-user-
  text-in-`os_log` but does NOT scan for the `/tmp/souffleuse-*.log`
  pattern or the `PredictDebug` enum.
- Recommendations: extend `audit.sh` rule set with a check that
  `PredictDebug.enabled` returns `false` in Release configuration via
  `#if DEBUG` or a build flag, and assert no `/tmp/souffleuse-*.log`
  writes survive in shipping bits. Today both fire under any `.app` if
  the user (or a malicious caller) sets the env var.

**No code signing / notarization automation:**
- Risk: `Souffleuse/make-app.sh` is the only build script; no Sparkle,
  no notarization, no model checksum verification. ARCHITECTURE.md
  promises "Open weights vérifiables, checksums publics, no telemetry"
  as a positioning wedge.
- Files: `Souffleuse/make-app.sh` (2.6K), `Souffleuse/Package.resolved`
  (no SHA pinning beyond SPM defaults).
- Current mitigation: none.
- Recommendations: ship a `verify-model.sh` that fetches the manifest,
  checks each `mlx-community/...` repo against a known hash, fails the
  load on mismatch. Add notarization step to `make-app.sh` once the
  Developer ID is provisioned.

## Performance Bottlenecks

**LLM prefill on every keystroke:**
- Problem: Full re-encode of the prompt + transformer prefill every
  predict — see Tech Debt §1. TTFT floors around 150 ms even after the
  tactical wins shipped in `6ad70df` (tick 200→80 ms, debounce 150→50 ms,
  prefix cap 2048→512 chars, maxWords default 6→3).
- Files: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:368-700`
  (predict path), `Souffleuse/Sources/SouffleuseBench/Bench.swift`
  (current A/B bench, no incremental TTFT instrumentation).
- Cause: no KV cache reuse, no tokenization cache; greedy top-1 forces
  re-decode of identical prompt tails.
- Improvement path: KV-cache reuse milestone (point 1 in
  `NEXT-MILESTONE-NOTES.md`). Add an incremental TTFT metric to
  `SouffleuseBench` first to confirm gains.

**OCR fallback adds 50-300 ms latency for Chromium hosts:**
- Problem: `OCRCaretLocator.locate()` captures the screen via
  `ScreenCaptureKit`, crops to `elementRect`, and runs Vision
  `VNRecognizeTextRequest` with the accurate recogniser (slowest mode).
- Files: `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift`
  (465 lines), `Souffleuse/Sources/SouffleuseOverlay/CaretEstimator.swift`.
- Cause: Accurate recogniser is mandated — `recognitionLevel = .fast`
  collapses to whole-line bounding boxes that can't honour
  `boundingBox(for:)` per-character.
- Improvement path: cache calibrated metrics per bundle (already done in
  `CaretResolver`), keep the OCR fire rate at 2 s cooldown, and consider
  running OCR only on the first focus + on element-rect shifts > 20 pt
  (already implemented at `CaretResolver.swift:201-213`). The remaining
  cost is the 50-300 ms one-shot — acceptable per design.

**`Timer.scheduledTimer` at 80 ms cadence wakes the main runloop 12.5×/s
even when no app is focused:**
- Problem: `pollTimer` fires every 80 ms regardless of whether a text
  element is focused — the tick gate bails fast, but the wake itself is
  charged to App Nap.
- Files: `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:208-210`.
- Cause: No AX notification-driven path; everything is polled.
- Improvement path: hook
  `NSWorkspace.didActivateApplicationNotification` to suspend the timer
  when frontmost app is in the blocklist, and resume on focus change.
  Targets the "<2% CPU idle" promise in ARCHITECTURE.md §1 which is
  borderline today.

**Synchronous `replaceTrailing` posts N backspaces with 2 ms inter-event
delay:**
- Problem: typo / emoji replace of K characters takes
  `5 ms + K × 2 ms + 5 ms` of mandated sleeps before the inject lands.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:217-243`.
- Cause: bursting N backspaces in one go caused some hosts (Notes, Mail)
  to drop events mid-stream empirically — comment at `:233-238`.
- Improvement path: post a single composite CGEvent batch and let the
  kernel dispatch them sequentially; failing that, halve the delay on
  hosts known to handle bursts (Slack, Mail.app desktop, Safari).

**Each accepted history entry rewrites the entire encrypted file:**
- Problem: `TypingHistoryStore.flush()` re-encodes JSON, re-seals AES-GCM,
  and atomically rewrites `history.aes` on every `append()`.
- Files:
  `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift:81-93,
  130-145`.
- Cause: synchronous-flush by design (privacy / crash-safety).
- Improvement path: cap is 200 entries / ~100 KB so cost is bounded;
  could defer flush via a debounce timer (5 s) without losing data on
  graceful quit. Don't prioritise — current cost is invisible.

## Fragile Areas

**Partial-accept state machine spans four mutable vars:**
- Files:
  `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:124-135`
  (var declarations) and `:797-873` (state transitions inside `tick()`).
- Why fragile: `partialRemainder`, `partialAcceptedSoFar`,
  `partialAcceptedAtPrefix`, `partialAcceptedAtBundleID` must stay
  consistent across (focus change, typo replace, emoji replace, Esc,
  divergence, live-consume completion, manual Tab). Each transition is a
  separate code path; missing one branch causes ghosts to render at the
  wrong rect or partial acceptance to bleed across bundles.
- Safe modification: never touch one of the four without checking the
  other three; treat them as a single value type. The unit tests cover
  `cancelPreservesPredictCache` and `cancelClearsActiveSuggestion` but
  not the full state machine — coverage is regression-driven.
- Test coverage: partial — no exhaustive coverage of focus-change-mid-
  partial. See gap in §"Test Coverage Gaps".

**`predictCache` keyed on raw `userTail` — model swap or pref change
silently invalidates assumptions:**
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:74-79,
  108-118` (model swap clears cache), `:411` (re-apply `capToWords` on
  read because `maxWords` may have changed between insert and read).
- Why fragile: any property that influences output (system prompt,
  custom instructions, contextPrefix, personalization strength,
  detected language) is NOT part of the cache key. The `capToWords`
  re-trim on read is a band-aid for `maxWords`; the other inputs are
  not handled.
- Safe modification: when adding any new knob that affects predict
  output, either (a) clear the cache on change, or (b) extend the key.
  Reading `predictCache.removeAll` call sites is the audit checklist.
- Test coverage: undo-as-ghost and cache_hit covered; `capToWords`
  reapplication covered. Other invalidation paths uncovered.

**MLX `LLMModelFactory.shared` is a process-wide singleton:**
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:146-173`
  (`loadModel`), `:108-118` (`swapModel`).
- Why fragile: `LLMModelFactory.shared` and `MLX.GPU.set(cacheLimit:)`
  reach across the process. Swap during in-flight predict relies on
  `cancel()` semantics being honest; `currentTask?.cancel()` is checked
  before each chunk but MLX's own prefill is non-cancellable.
- Safe modification: don't call `loadModel` concurrently. Today
  `loadModel` early-exits if state isn't `.idle`; `swapModel` sets
  state to `.idle` first, ensuring serialisation.

**`@unchecked Sendable` on `AXClient` and `KeyInterceptor`:**
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:56`,
  `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift:9`.
- Why fragile: Swift 6 concurrency is otherwise enforced
  (`swiftLanguageModes: [.v6]` in `Souffleuse/Package.swift:112`). Both
  classes opt out via `@unchecked Sendable`. `AXClient` is safe because
  every mutation goes through the internal `queue: DispatchQueue`;
  `KeyInterceptor` mutates `active` and `tap` from the main thread only
  (per comment).
- Safe modification: keep the queue invariant for `AXClient`. Any new
  mutable property must either be confined to `queue` or annotated.
- Test coverage: none on threading — concurrency bugs would show up as
  flakes in `SouffleuseTests.swift`.

**OCR matcher can align AX text against the wrong region:**
- Files:
  `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift:65-78`
  (size sanity guard),
  `Souffleuse/Sources/Souffleuse/CaretResolver.swift:160-182` (post-OCR
  in-bounds check).
- Why fragile: when the user types short common text ("Bonjour,") into a
  reply box in Intercom-like hosts, the OCR matcher can lock onto the
  same string in the conversation history above. Defended by two layers:
  rejection if `elementRect` is suspiciously large (>1400×600), and a
  post-locate check that the resolved caret centre falls inside
  `elementRect` ± 12 pt slack.
- Safe modification: any change to the OCR matcher must preserve both
  guards. Loosening them re-introduces "ghost paints far from caret".

**`AllowlistConfig` regex compilation happens on every `mode()` call:**
- Files:
  `Souffleuse/Sources/Souffleuse/AllowlistConfig.swift:30-35`
  (`compiledRegex: NSRegularExpression?` is a computed property).
- Why fragile: each focus change in `tick()` calls
  `store.allowlist.mode(...)` which iterates rules and may compile each
  `titleRegex`. Bad pattern → silent `nil` (rule never matches).
- Safe modification: memoise compiled regex when the rule list is
  written.

## Scaling Limits

**Single-model loaded at any time:**
- Current capacity: one MLX container in `PredictorViewModel.container`.
  Switching model means cancelling + dropping + reloading. ~3-10 s for
  a 1 GB 4-bit model on M1 base.
- Limit: cannot run e.g. typo correction on a small fast model + LLM
  ghost on a bigger model in parallel.
- Scaling path: introduce a second container slot dedicated to short
  completions; coordinate cancellation across both.

**Personalization history capped at 200 entries:**
- Current capacity: `TypingHistoryStore.maxEntries = 200` (~100 KB
  encrypted blob), hard `hardSizeCapBytes = 1_000_000`.
- Files:
  `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift:11-12`.
- Limit: heavy users churn through 200 entries in days; few-shot
  retrieval (`SimilarHistoryRetrieval`) then loses long-term style.
- Scaling path: dual-tier storage (200 hot + an aged blob), or per-app
  partitions. Tracked implicitly in
  `NEXT-MILESTONE-NOTES.md` point 6 ("Apprentissage élargi").

**FIFO `predictCache` capped at 32 entries:**
- Current capacity:
  `PredictorViewModel.predictCacheCapacity = 32`.
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:79`.
- Limit: long typing sessions evict useful prefixes; undo-as-ghost
  reach drops to ~20 prefixes back.
- Scaling path: bump to 128 (cost ~10 KB RAM) and switch FIFO to LRU
  (true touch-on-hit). Cheap.

**No worker pool for OCR — one Vision request can run at a time per
bundle:**
- Current capacity: `OCRCaretLocator` is an `actor`; serial on its own
  state, but Vision itself is single-shot per call.
- Files:
  `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift:43-57`.
- Limit: 50-300 ms blocking; if the user switches between three
  Chromium apps rapidly, calibration warm-up is sequential.
- Scaling path: keep as-is; the 2 s cooldown in
  `CaretResolver.shouldFireOCR` already bounds the rate.

## Dependencies at Risk

**`mlx-swift-examples` `from: "2.0.0"` — single dependency:**
- Risk: One external SPM dep
  (`https://github.com/ml-explore/mlx-swift-examples`) drives the entire
  inference path via `MLXLLM` + `MLXLMCommon`. Open-range constraint
  accepts breaking 2.x minor bumps silently if Apple's repo respects
  semver.
- Files: `Souffleuse/Package.swift:25`.
- Impact: KV-cache / TokenIterator work depends on what the upstream
  package exposes; the next milestone's `Décisions en suspens` flags
  "MLX API compatible with KV state?" (per
  `NEXT-MILESTONE-NOTES.md:102`).
- Migration plan: pin to a known-good SHA via `.upToNextMinor(from:)`
  once the KV milestone lands and validates the API surface. Fork to
  `Souffleuse/vendor/mlx-swift-examples` if MLX upstream churns.

**No `Package.resolved` SHA pinning audit:**
- Risk: `Souffleuse/Package.resolved` exists but is not validated by
  CI; a malicious tag bump on a transitive dependency would not be
  caught.
- Files: `Souffleuse/Package.resolved`.
- Impact: supply-chain attack surface; small for now (one dep).
- Migration plan: add a `verify-deps.sh` to `audit.sh` that diffs
  `Package.resolved` SHAs against an in-tree allowlist.

## Missing Critical Features

**No `afterCursor` capture:**
- Problem: AX `kAXSelectedTextRangeAttribute` gives us caret position;
  we currently slice `text.prefix(caretIndex)` and discard everything
  after the caret. Cotypist exposes `afterCursor` in its prompt and
  uses it as completion constraint signal.
- Blocks: mid-line completions where the user types into the middle of
  an existing sentence — Souffleuse would happily emit a continuation
  that duplicates text already after the caret.
- Files:
  `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:762`
  (where `prefix` is computed).
- Tracked: `NEXT-MILESTONE-NOTES.md` point 3.

**No field-level metadata in the prompt:**
- Problem: AX exposes `kAXPlaceholderValueAttribute`, `kAXHelpAttribute`,
  `kAXIdentifierAttribute`, `kAXTitleAttribute` — none of these are
  read; only role + subrole + value + selection are captured in
  `AXSnapshot`.
- Blocks: domain-aware completion (e.g. "this field expects an email
  address" → biases against free-form prose). Cotypist uses
  `typingContext, domain, windowTitle, placeholderValue, help,
  accessibilityIdentifier`.
- Files:
  `Souffleuse/Sources/SouffleuseAX/AXClient.swift:10-44` (`AXSnapshot`),
  `Souffleuse/Sources/SouffleuseAX/AXClient.swift:299-453` (snapshot
  build paths).
- Tracked: `NEXT-MILESTONE-NOTES.md` point 3.

**Greedy top-1 decoding only:**
- Problem: `predict()` runs the iterator once and shows the streamed
  output verbatim. Cotypist generates K candidates, scores by
  `averageLogprob` / `totalLogprob`, applies `constraint` /
  `requiredPrefix` constrained decoding, picks the best.
- Blocks: quality gap on ambiguous prefixes; observed today as
  "fortune cookie" suggestions on first-word inputs (defended by
  `hasCompletedFirstWord` gate in
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:255-265`).
- Files: `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:530-700`
  (single-stream path).
- Tracked: `NEXT-MILESTONE-NOTES.md` point 4.

**No negative-signal learning:**
- Problem: `recordPartialAcceptanceToHistoryIfAllowed` and the full-
  accept branch record only what the user *took*. Dismissed ghosts,
  typed-instead alternatives, and ignored suggestions are not
  captured. Cotypist's `UserInputRecord` /
  `hasAcceptedCompletion` / `Store Inputs Without Accepted
  Completions` lets it learn from rejections too.
- Blocks: long-term style adaptation to what the user *doesn't* want.
- Files:
  `Souffleuse/Sources/SouffleusePersonalization/TypingHistoryStore.swift:81-93`
  (only `accepted` is stored — `TypingHistoryEntry` has no rejection
  fields).
- Tracked: `NEXT-MILESTONE-NOTES.md` point 6.

**No visual-width truncation on ghost:**
- Problem: ghost length is capped by word count + sentence terminators
  only. Cotypist additionally enforces
  `completionWidthExceedsMaximum, prefixWidthExceedsMaximum,
  maxSearchWidth, maxResultWidth` against the rendered pixel width.
- Blocks: long ghosts can overflow narrow text fields, painting over
  surrounding UI.
- Files:
  `Souffleuse/Sources/SouffleuseOverlay/OverlayWindow.swift` (no width
  clamp visible),
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:584-589`
  (word cap only).
- Tracked: `NEXT-MILESTONE-NOTES.md` point 5.

## Test Coverage Gaps

**`PredictorViewModel.predict()` is not exercised end-to-end:**
- What's not tested: the full `predict()` path (model load → predict →
  stream → filter → cache write). Tests cover `stripPrefixOverlap`,
  `capToWords`, `hasCompletedFirstWord` indirectly via the
  cache-eviction tests, but no end-to-end run with a fake
  `ModelContainer`.
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:368-700`,
  `Souffleuse/Tests/SouffleuseTests/SouffleuseTests.swift` (39 tests,
  none load a model).
- Risk: regression on any of the inline filters (`ghostIsRepeatingPrefix`,
  the markup strip regex, sentence-terminator truncation) will only show
  up in manual QA.
- Priority: Medium. Mock `ModelContainer` to inject a deterministic
  token stream.

**`tick()` partial-accept state machine has no exhaustive coverage:**
- What's not tested: the 8-way branch in
  `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:797-873`
  (live-consume divergence, expected.hasPrefix(prefix), prefix grew
  past expected with match vs divergence, focus change mid-partial,
  history record on each exit).
- Files:
  `Souffleuse/Sources/Souffleuse/SouffleuseAppDelegate.swift:797-873`.
- Risk: state desync between `partialRemainder` and
  `partialAcceptedSoFar` produces ghost-at-wrong-prefix bugs that
  only show under specific keystroke timings.
- Priority: High. Extract a `PartialAcceptState` struct + state-machine
  unit tests.

**No tests for `AXClient.inject` / `replaceTrailing`:**
- What's not tested: AX inject vs CGEvent fallback selection,
  secure-field refusal on inject, `replaceTrailing` backspace count
  correctness.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:165-244`.
- Risk: silent regressions on the inject path are user-visible (wrong
  text inserted) but only reproducible against a real focused app.
- Priority: Medium. Wrap CGEvent posting behind a protocol so a
  recorder test double can capture the events.

**No tests for `OCRCaretLocator` / Vision integration:**
- What's not tested: anything that involves screen capture or Vision
  recognisers — by design, since both need a real display.
- Files:
  `Souffleuse/Sources/SouffleuseContext/OCRCaretLocator.swift` (465
  lines, 0 tests),
  `Souffleuse/Sources/SouffleuseContext/VisionOCR.swift`,
  `Souffleuse/Sources/SouffleuseContext/ScreenCapturer.swift`.
- Risk: silent regressions in the sanity guards
  (`element_too_large`, `caret_outside_field`) re-introduce ghost-
  drift bugs that took weeks to root-cause.
- Priority: Medium. Inject a deterministic `[VNRecognizedTextObservation]`
  array into the matcher and assert the returned rect; the screen-
  capture half stays integration-only.

**Coherence / IT-vs-PT model selection branch is exercised only via
`SouffleuseCoherence` executable:**
- What's not tested: the `isInstructModel` branch logic at
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:525-526`.
  Decisions there determine whether the chat template is applied.
- Files:
  `Souffleuse/Sources/Souffleuse/PredictorViewModel.swift:525-526`,
  `Souffleuse/Sources/SouffleuseCoherence/` (separate executable).
- Risk: regression on the regex (`"-it"` vs `"instruct"`) would silently
  apply the wrong template to a new model id.
- Priority: Low — string match is trivial — but add one parameterised
  test cycling through `ModelOption.catalogue`.

**No threading / Swift-6-concurrency stress tests on
`@unchecked Sendable` classes:**
- What's not tested: `AXClient` queue invariant, `KeyInterceptor`
  active/tap mutation from non-main threads.
- Files: `Souffleuse/Sources/SouffleuseAX/AXClient.swift:56`,
  `Souffleuse/Sources/SouffleuseInput/KeyInterceptor.swift:9`.
- Risk: data races would manifest as crashes under sustained typing
  (M2/M3 timing differs from M1).
- Priority: Low. Add a TSan-only test in CI.

---

*Concerns audit: 2026-05-24*
