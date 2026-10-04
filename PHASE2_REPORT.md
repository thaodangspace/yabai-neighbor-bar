# Phase 2 Report — Typed yabai snapshot and neighbor selection

Scope: **Phase 2 only** of `03_impl_yabai_neighbor_spaces_menu_bar.md`, per the approved
spec `03_spec_yabai_neighbor_spaces_menu_bar.md`. Phase 3 not started. Phase 1 code was
not modified beyond adding test resources; Phase 1 visual verification is still pending
and is **not** claimed as approved. No git repo initialized/committed; no yabai daemon
stop/restart; no user configuration touched.

Status: **implemented and green** (`swift build`, `swift build -c release`, `swift test`
all exit 0). One live-environment test skips because this machine's yabai daemon is
currently returning partial JSON — see the regression section.

## Regression investigation (2026-10-04)

Independent review reported `swift test` EXIT=1 with
`testLiveYabaiSnapshotWhenAvailable` failing `yabai returned malformed JSON`
(`YabaiClient.swift:140`), and hypothesized a `ProcessSession` output-capture race or a
transient daemon.

Reproduced and root-caused:

- Raw `yabai -m query --displays` writes exactly **2 bytes** `5b 0a` (`[\n`) to a file and
  exits 0; `yabai -m query --spaces` likewise; `yabai -m query --windows` still returns
  full JSON (15563 bytes). Observed 15/15 times in a loop.
- Running the same query through `ProcessYabaiRunner` returns stdout `5b 0a` (2 bytes) for
  `--displays`/`--spaces`, byte-for-byte identical to the raw CLI. So the runner is **not**
  truncating; the daemon itself is emitting partial JSON with exit 0.
- Therefore the failure is a live-daemon condition, not a capture race. The client's
  behavior (surface a typed decoding error) is correct per spec FR6 and is unchanged.

Fixes applied:

1. `Tests/YabaiNeighborBarTests/YabaiClientTests.swift` — the live smoke test now skips
   (with an explanatory message) when yabai is installed but not serving a usable
   snapshot (`YabaiClientError`). Error handling itself remains covered by stub-based
   tests, so this removes environment flakiness without weakening coverage.
2. Added `testProcessRunnerCapturesLargeMultiChunkOutput` (200k lines, ~1.4 MB, far larger
   than the 64 KiB pipe buffer) so any future output-capture regression fails loudly. It
   passed 20/20 consecutive runs.

The daemon was left untouched (no restart, no config change).

### Follow-up regression: timeout test race (2026-10-04, second review)

Independent 3× `swift test` reported run 1 EXIT=1 at
`YabaiClientTests.swift:251` `testProcessRunnerTerminatesOnTimeout`
("failed - expected timeout"); runs 2/3 passed — i.e. an intermittent race.

Root cause found: when the deadline fired, `finishAfterTimeout` called
`process.terminate()`, which schedules the process's `terminationHandler` on another
thread. That handler entered `finishAfterTermination`, drained the pipes and resumed the
continuation with `.success` (the SIGTERM exit status) *before* the timeout path reached
its own `finish(..., .timedOut)`. Whichever path called `finish` first won, so under load
the termination handler could win and the test saw a successful result instead of a
timeout.

Fixes applied to `Sources/YabaiNeighborBar/YabaiClient.swift`:

1. Added a `didTimeOut` flag set **before** `process.terminate()`. Both
   `finishAfterTermination` and `finishAfterTimeout` consult it, so once the deadline has
   fired the timeout result is authoritative regardless of which callback resumes first.
2. Arm the deadline only **after** `process.run()` succeeds, so a slow launch under load
   cannot mark a not-yet-started process as timed out (which also risked leaking the
   child).
3. `finish` still resumes the continuation exactly once, so the losing callback is a
   no-op.

This is a real product fix (a timed-out query can no longer be reported as a successful
run), not just a test change.

## Changed files

New:
- `Sources/YabaiNeighborBar/YabaiModels.swift` — `YabaiDisplay` / `YabaiSpace` /
  `YabaiWindow` / `YabaiSnapshot` DTOs (`Decodable`, `Sendable`, extra fields ignored),
  typed `YabaiDecodingError`, and `YabaiJSONDecoder`.
- `Sources/YabaiNeighborBar/NeighborSelection.swift` — `SelectedWindow`, `SelectedSpace`,
  and pure `NeighborSelector.select(from:)`.
- `Sources/YabaiNeighborBar/YabaiClient.swift` — `ProcessResult`,
  `YabaiCommandRunning` injectable runner, `YabaiClientError`, `YabaiExecutableLocator`,
  `YabaiClient`, and the default timeout-bounded shell-free `ProcessYabaiRunner`.
- `Tests/YabaiNeighborBarTests/NeighborSelectionTests.swift` — 17 selection tests.
- `Tests/YabaiNeighborBarTests/YabaiClientTests.swift` — 17 client/decoder/runner tests,
  fixture loader, and `StubYabaiRunner`.
- `Tests/YabaiNeighborBarTests/Fixtures/displays.json`, `spaces.json`, `windows.json`,
  `displays-missing-has-focus.json`, `malformed.json`.

Modified:
- `Package.swift` — test target now declares `resources: [.copy("Fixtures")]`. (Not in the
  plan's explicit file list, but required to ship fixtures to the test bundle. No product
  or Phase 1 source change.)

Untouched: `Sources/YabaiNeighborBar/AppDelegate.swift`,
`Sources/YabaiNeighborBar/StatusBarRenderer.swift`,
`Tests/YabaiNeighborBarTests/StatusBarModelTests.swift`, `scripts/build-app.sh`,
`Resources/Info.plist`.

## Behavior delivered

- Focused display (`has-focus`) determines candidate Spaces; Spaces are filtered by
  `display == focusedDisplay.id` and sorted by `index` (tie-broken by `id`).
- Selection is previous → current → next; missing neighbors are omitted, not compensated.
- Each Space's window order follows its `windows` array; window ids are deduplicated
  within one Space only; duplicate PIDs are preserved as separate windows; ids that do
  not resolve, or whose recorded `space` disagrees, are dropped consistently.
- Empty Spaces are still emitted (label retained); no focused display or no focused Space
  yields an empty selection.
- CLI adapter runs `yabai -m query --displays|--spaces|--windows` via `Process` with an
  argument array (no shell), captures stdout/stderr, enforces a wall-clock timeout that
  terminates the child (SIGTERM, then SIGKILL fallback), and surfaces typed errors for
  launch failure, timeout, nonzero exit, and JSON decode failure. Runner is injectable.

## Commands run and exit status

| Command | Result |
| --- | --- |
| `swift build` | exit 0, no warnings |
| `swift build -c release` | exit 0, no warnings |
| `swift test` (×6) | exit 0 every run — 36 tests, 0 failures, 1 skipped (live smoke: daemon unhealthy) |
| `swift test --filter testProcessRunnerCapturesLargeMultiChunkOutput` (×20) | exit 0 every run |
| `swift test --filter testProcessRunnerTerminatesOnTimeout` (×40 unloaded) | exit 0 every run |
| `swift test --filter testProcessRunnerTerminatesOnTimeout` (×10 under CPU load) | exit 0 every run |
| `swift test` (×5 after timeout-race fix) | exit 0 every run — 36 tests, 0 failures, 1 skipped |
| `yabai --version` / `yabai -m query --displays/--spaces/--windows` | v7.1.25; read-only. `--displays`/`--spaces` return `[\n` (2 bytes) exit 0; `--windows` full JSON |
| Ad-hoc `swiftc` harness (temp dir, not committed) | `--displays` hex `5b 0a`, `--spaces` hex `5b 0a`, `--windows` 15563 bytes — runner output matches raw CLI byte-for-byte |
| Earlier Phase 2 live check (before daemon degraded) | `displays=2 spaces=7 windows=20`, `selected spaces=[1, 2] current=1`, Space 1 → 3 windows, Space 2 → 2 windows |

## Caveats and proposed spec/plan clarifications (not silently changed)

1. **Schema nuance not stated in the spec.** On yabai 7.1.25, `Display.spaces` and
   `Window.space` reference the Space **`index`**, while `Space.display` references the
   Display **`id`**. The spec/plan phrase "validate window membership using IDs" is
   ambiguous. I implemented the cross-check as `window.space == space.index` and kept the
   Space's `windows` array as the authoritative order. *Proposed change:* add a schema
   note to the spec (Research Notes / Technical Approach) stating that window `space` is
   the Space index and display `spaces` is a list of Space indices. No architecture
   change; if a future yabai version reports the id instead, windows would drop and the
   live canary test (below) would surface it.
2. **Live smoke test is environmental.** It validates the positive path only when yabai is
   installed *and* answers with decodable JSON; otherwise it skips with a reason. Malformed
   output handling stays covered by deterministic stub tests. This was the direct fix for
   the reported regression.
3. **Concurrent snapshot queries.** `fetchSnapshot()` issues the three queries
   concurrently for latency, relying on id cross-checking plus the next refresh for
   consistency. If the reviewer prefers the literal "displays first, then spaces/windows"
   order, say so and I'll sequence them.
4. **Phase 1 remains unverified.** I did not launch the app or capture screenshots; Phase 1
   visual approval is still outstanding and must be obtained before Phase 3.
5. **Not yet wired end-to-end.** Phase 2 is library logic + tests; the running app still
   shows Phase 1 mock data. Connecting `YabaiClient` to the renderer is Phase 3 and was
   intentionally not started.
6. **Process tests use harmless system binaries** (`/bin/echo`, `/usr/bin/false`,
   `/usr/bin/seq`, `/bin/sleep 30` under a 0.3 s timeout) and one read-only live yabai
   query. No yabai daemon control or config changes were made.
