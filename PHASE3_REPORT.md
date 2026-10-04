# Phase 3 Report — Live icon resolution and rendering

Scope: **Phase 3 only** of `03_impl_yabai_neighbor_spaces_menu_bar.md`, per the approved
spec `03_spec_yabai_neighbor_spaces_menu_bar.md`. Phase 2 is approved. Phase 4
(refresh/polling lifecycle, retry/error UI, packaging) not started. Phase 1 visual
behavior remains **unverified** and is **not** claimed here. No git repo; no commits.
No yabai daemon stop/restart; no yabairc/user-config changes.

Status: **implemented; build and unit tests green.** Live end-to-end display on this
machine is **blocked** because the running yabai daemon returns partial JSON for
`--displays`/`--spaces` (see Blockers). Per instruction, the app does **not** fall
back to mock data.

## What Phase 3 delivers

1. **Typed live snapshot wired to native items.** `AppDelegate` detects the installed
   `yabai`, requests one snapshot at launch (`YabaiClient.fetchSnapshot()`), selects
   neighbors (`NeighborSelector`), resolves icons, and renders to `NSStatusItem`s. It
   also exposes `requestRefresh()` for further, overlap-safe refreshes (Phase 4 will
   drive the schedule). No polling/retry was added (Phase 4).
2. **PID icon resolution with cache invalidation and per-window fallback.**
   `IconResolver` uses `NSRunningApplication(processIdentifier:)` and caches the
   expensive `icon` per PID. Every resolve re-probes process liveness; a vanished
   process, a PID reused by a different `bundleIdentifier`, or an app with no icon
   yields a template fallback. A cached fallback stays marked as fallback (never
   reported as a real icon). Each window keeps its own identity, so multiple windows
   of one app never collapse into one item.
3. **Main-thread reconciliation with deterministic order and stale removal.**
   `StatusBarRenderer` diffs a complete `StatusBarModel` against native items keyed by
   stable identity (`spaceLabel(spaceID)` / `window(spaceID, windowID)`). It reuses the
   longest unchanged key prefix (no flicker/reorder), removes stale handles, and
   recreates only the suffix AppKit's append-only ordering requires. Final item order
   always equals the model order (previous → current → next, windows in yabai order).
   Current Space is distinguished by label `[index]` vs `index`.
4. **Out-of-order async safety.** `SnapshotGeneration` is a monotonic token. Each
   refresh captures a token; a completion may touch the UI only if no newer refresh has
   started, so a slow stale result cannot overwrite newer state. On decode/CLI failure
   the renderer is cleared and the reason is logged with `os.Logger`; stale items are
   not left to mislead, and mock data is never substituted.

## Changed files

New:
- `Sources/YabaiNeighborBar/IconResolver.swift` — `ResolvedIcon`,
  `RunningApplicationIcon`, injectable `RunningApplicationProviding`,
  `SystemRunningApplications`, and `IconResolver` (PID cache + invalidation + fallback).
- `Tests/YabaiNeighborBarTests/IconResolverTests.swift` — 9 tests: cache reuse,
  liveness probe per resolve, vanished-process invalidation, PID reuse with bundle
  change, explicit invalidate, missing process fallback (no cache), icon-less app stays
  fallback when cached, distinct PIDs, fallback image validity.

Modified:
- `Sources/YabaiNeighborBar/AppDelegate.swift` — removed the Phase 1 mock toggle;
  wires `YabaiClient` + `NeighborSelector` + `IconResolver` + `StatusBarRenderer`;
  generation-gated `requestRefresh()`; clears + logs on failure.
- `Sources/YabaiNeighborBar/StatusBarRenderer.swift` — replaced the
  clear-and-recreate mock renderer with a reconciliation model (`ResolvedWindowIcon`,
  `StatusItemKey`, `StatusItemModel`, `StatusBarModel.make`), abstracted
  `StatusItemHandle`/`StatusItemHost`, real `SystemStatusItemHost`/handle, and
  `SnapshotGeneration`. Current-Space label marker retained.
- `Tests/YabaiNeighborBarTests/StatusBarModelTests.swift` — replaced the 2 Phase 1 mock
  tests with 14 tests: model order/duplicate-PID/current-marker/empty; renderer
  create-in-order, prefix reuse, stale removal, middle insertion, reorder, reused-content
  update, empty-model cleanup, clear, duplicate-key dedupe; generation token tests.
- `README.md` — corrected the now-false "Mock data only" claim and the Phase 1 mock
  alternation description (minor supporting doc change; packaging/run docs remain
  Phase 4).

Untouched: `Package.swift` (new source auto-included; no resource change needed),
`Sources/YabaiNeighborBar/YabaiModels.swift`, `NeighborSelection.swift`,
`YabaiClient.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, fixtures,
`NeighborSelectionTests.swift`, `YabaiClientTests.swift`.

## Commands run and exact exit codes

| Command | Exit | Result |
| --- | --- | --- |
| `swift build` | `0` | Build complete, no warnings |
| `swift build -c release` | `0` | Build complete, no warnings |
| `swift test` (final, logged) | `0` | 57 tests, 0 failures, 1 skipped |
| `swift test` ×3 (stability) | `0`, `0`, `0` | 57 tests each, 0 failures, 1 skipped |

Test breakdown: 56 passed, 1 skipped (`YabaiClientTests.testLiveYabaiSnapshotWhenAvailable`
— daemon unhealthy), 0 failures. No compiler warnings in debug/release/test logs.

## Read-only yabai smoke check (2026-10-04)

Evidence, no daemon/config change:

| Query | Bytes | Content | Exit |
| --- | --- | --- | --- |
| `yabai --version` | — | `yabai-v7.1.25` | 0 |
| `yabai -m query --displays` | 2 | hex `5b 0a` (`[\n`) | 0 |
| `yabai -m query --spaces` | 2 | hex `5b 0a` (`[\n`) | 0 |
| `yabai -m query --windows` | 15563 | full JSON | 0 |

`--displays`/`--spaces` are not valid JSON, so `fetchSnapshot()` fails at decode. This
matches the Phase 2 finding and is a live-daemon condition, not a client bug.

## Blockers

1. **Live end-to-end display is blocked.** yabai emits partial JSON for
   `--displays`/`--spaces` with exit 0, so no snapshot can be decoded and no live
   selection/icon/reconciliation path can run against the real desktop. The app
   correctly reports the failure (clears items + logs) rather than showing mock data.
   Resolving this requires the user's approval to restart/inspect their yabai daemon
   (out of scope here) — I did not alter it.
2. **Manual visual verification not performed.** Phase 1 already had unverified visual
   behavior (automated screenshot capture failed; ordering/notch/overflow unconfirmed),
   and Phase 3's live path cannot render because of blocker 1. Therefore I do **not**
   claim visual validation of item ordering, current-Space distinction, fallback
   appearance, notch/overflow, or live updates. These remain open for a human check
   once yabai serves a full snapshot.
3. **Ordering/overflow caveat (flagged, not claimed solved).** Native `NSStatusItem`
   order is AppKit append order; the renderer guarantees the model's order by recreating
   the unchanged-prefix suffix when order changes. Whether the OS actually shows that
   order and how many items survive next to the notch/Control Center is macOS-controlled
   and visually unverified. Reordering therefore may visibly flicker (it removes and
   recreates the affected suffix by design, since AppKit appends). This is expected and
   should be evaluated during the human visual check.
4. **Pre-existing process/cost observation.** A Phase 1 prototype process has been
   running since before this task (`PID 26449`, `/Users/dt/code/raycast-yabai/.build/YabaiNeighborBar.app/...`,
   ~45% CPU, ~27 min CPU time). I did **not** launch a second app instance (avoiding a
   double process). I also did not kill this user-visible process. The high CPU is a
   Phase 1 behavior (mock timer recreating all status items) and is out of Phase 3
   scope; it should be checked when the user is ready. The on-disk binary now reflects
   Phase 3, but the running process is the older Phase 1 image.

## Notes / proposed follow-ups (not silently changed)

- `README.md` was updated only to stop claiming the app is mock-only; final
  install/run/packaging documentation is Phase 4.
- `package.swift` was intentionally not modified; `IconResolver.swift` is compiled
  automatically and the tests need no new resources.
- Phase 4 should add the bounded refresh schedule that calls `requestRefresh()`, a
  visible minimal error item, and retry/recovery, plus the human visual/overflow check
  that Phase 3 cannot complete here.
