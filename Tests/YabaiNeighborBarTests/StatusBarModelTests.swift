import AppKit
import XCTest
@testable import YabaiNeighborBar

/// Records the handles it creates and whether they were removed. Lets the
/// reconciliation tests assert ordering, reuse and cleanup without a live menu bar.
@MainActor
final class RecordingStatusItemHost: StatusItemHost {
    final class Handle: StatusItemHandle {
        private(set) var applied: StatusItemModel.Content?
        private(set) var applyCount = 0
        private(set) var isRemoved = false

        func apply(_ content: StatusItemModel.Content) {
            applied = content
            applyCount += 1
        }

        func remove() {
            isRemoved = true
        }
    }

    private(set) var created: [Handle] = []
    var liveHandles: [Handle] { created.filter { !$0.isRemoved } }

    func makeHandle() -> any StatusItemHandle {
        let handle = Handle()
        created.append(handle)
        return handle
    }
}

@MainActor
final class StatusBarModelTests: XCTestCase {

    // MARK: - Model building

    func testModelPreservesSpaceAndWindowOrderWithDuplicatePIDs() {
        let model = StatusBarModel.make(from: [
            space(11, index: 1, current: false, windows: [window(101, pid: 1001)]),
            space(22, index: 2, current: true, windows: [window(102, pid: 2002), window(103, pid: 2002)]),
            space(33, index: 3, current: false, windows: []),
        ], resolveIcon: resolvedIcon)

        XCTAssertEqual(model.items.map { signature($0.content) }, [
            "space(1,false)", "window(101,false)",
            "space(2,true)", "window(102,false)", "window(103,false)",
            "space(3,false)",
        ])
        XCTAssertEqual(model.items.map(\.key), [
            .spaceLabel(spaceID: 11), .window(spaceID: 11, windowID: 101),
            .spaceLabel(spaceID: 22), .window(spaceID: 22, windowID: 102), .window(spaceID: 22, windowID: 103),
            .spaceLabel(spaceID: 33),
        ])
    }

    func testModelMarksOnlyCurrentSpace() {
        let model = StatusBarModel.make(from: [
            space(11, index: 1, current: false, windows: []),
            space(22, index: 2, current: true, windows: []),
        ], resolveIcon: resolvedIcon)

        XCTAssertEqual(model.items.map { signature($0.content) }, ["space(1,false)", "space(2,true)"])
    }

    func testModelForEmptySelectionHasNoItems() {
        XCTAssertTrue(StatusBarModel.make(from: [], resolveIcon: resolvedIcon).items.isEmpty)
    }

    // MARK: - Renderer reconciliation

    func testRendererCreatesItemsInOrder() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 10),
            label(spaceID: 2, index: 2, current: true),
        ]))

        XCTAssertEqual(host.liveHandles.count, 3)
        XCTAssertEqual(signatures(host), ["space(1,false)", "window(10,false)", "space(2,true)"])
        XCTAssertEqual(renderer.itemCount, 3)
    }

    func testRendererReusesUnchangedPrefix() {
        let (renderer, host) = makeRenderer()
        let model = StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 10),
        ])
        renderer.render(model)
        let firstHandles = host.liveHandles

        renderer.render(model)

        XCTAssertEqual(host.created.count, 2, "identical render must not recreate items")
        XCTAssertTrue(host.liveHandles[0] === firstHandles[0])
        XCTAssertTrue(host.liveHandles[1] === firstHandles[1])
        XCTAssertEqual(host.liveHandles.map(\.applyCount), [2, 2])
    }

    func testRendererRemovesStaleItems() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 10),
            windowItem(spaceID: 1, windowID: 11),
        ]))
        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 10),
        ]))

        XCTAssertEqual(host.created.count, 3)
        XCTAssertEqual(signatures(host), ["space(1,false)", "window(10,false)"])
        XCTAssertEqual(renderer.itemCount, 2)
    }

    func testRendererInsertsInMiddleKeepingUnchangedPrefix() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 20),
        ]))
        let firstHandle = host.liveHandles[0]

        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: false),
            windowItem(spaceID: 1, windowID: 10),
            windowItem(spaceID: 1, windowID: 20),
        ]))

        XCTAssertEqual(signatures(host), ["space(1,false)", "window(10,false)", "window(20,false)"])
        XCTAssertTrue(host.liveHandles[0] === firstHandle, "prefix must be reused, not recreated")
        XCTAssertEqual(host.created.count, 4)
        XCTAssertEqual(renderer.itemCount, 3)
    }

    func testRendererReordersWhenOrderChanges() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            windowItem(spaceID: 1, windowID: 10),
            windowItem(spaceID: 1, windowID: 11),
        ]))
        renderer.render(StatusBarModel(items: [
            windowItem(spaceID: 1, windowID: 11),
            windowItem(spaceID: 1, windowID: 10),
        ]))

        XCTAssertEqual(signatures(host), ["window(11,false)", "window(10,false)"])
        XCTAssertEqual(host.created.count, 4, "AppKit appends, so the reordered suffix is rebuilt")
    }

    func testRendererUpdatesReusedContent() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [windowItem(spaceID: 1, windowID: 10, fallback: false)]))
        let handle = host.liveHandles[0]

        renderer.render(StatusBarModel(items: [windowItem(spaceID: 1, windowID: 10, fallback: true)]))

        XCTAssertTrue(host.liveHandles[0] === handle, "same key must reuse the native item")
        XCTAssertEqual(signatures(host), ["window(10,true)"])
        XCTAssertEqual(handle.applyCount, 2)
    }

    func testRendererRemovesAllWhenModelBecomesEmpty() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            label(spaceID: 1, index: 1, current: true),
            windowItem(spaceID: 1, windowID: 10),
        ]))
        renderer.render(StatusBarModel(items: []))

        XCTAssertTrue(host.liveHandles.isEmpty)
        XCTAssertEqual(renderer.itemCount, 0)
    }

    func testRendererClearRemovesEverything() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [label(spaceID: 1, index: 1, current: true)]))
        renderer.clear()

        XCTAssertTrue(host.liveHandles.isEmpty)
        XCTAssertEqual(renderer.itemCount, 0)
    }

    func testRendererDeduplicatesDuplicateKeysKeepingFirst() {
        let (renderer, host) = makeRenderer()
        renderer.render(StatusBarModel(items: [
            label(spaceID: 5, index: 1, current: false),
            label(spaceID: 5, index: 2, current: true),
            windowItem(spaceID: 5, windowID: 50),
        ]))

        XCTAssertEqual(signatures(host), ["space(1,false)", "window(50,false)"])
        XCTAssertEqual(renderer.itemCount, 2)
    }

    // MARK: - Generation gate

    func testSnapshotGenerationIncrementsMonotonically() {
        var generation = SnapshotGeneration()
        XCTAssertEqual(generation.next(), 1)
        XCTAssertEqual(generation.next(), 2)
        XCTAssertEqual(generation.current, 2)
    }

    func testSnapshotGenerationOnlyLatestTokenIsCurrent() {
        var generation = SnapshotGeneration()
        let stale = generation.next()
        let fresh = generation.next()

        XCTAssertFalse(generation.isCurrent(stale))
        XCTAssertTrue(generation.isCurrent(fresh))
    }

    // MARK: - Helpers

    private func makeRenderer() -> (StatusBarRenderer, RecordingStatusItemHost) {
        let host = RecordingStatusItemHost()
        return (StatusBarRenderer(host: host), host)
    }

    private func signatures(_ host: RecordingStatusItemHost) -> [String] {
        host.liveHandles.map { signature($0.applied) }
    }

    private func signature(_ content: StatusItemModel.Content?) -> String {
        switch content {
        case .none:
            return "none"
        case let .spaceLabel(index, isCurrent):
            return "space(\(index),\(isCurrent))"
        case let .windowIcon(icon):
            return "window(\(icon.windowID),\(icon.isFallback))"
        }
    }

    private func space(
        _ id: Int,
        index: Int,
        current: Bool,
        windows: [SelectedWindow]
    ) -> SelectedSpace {
        SelectedSpace(id: id, index: index, isCurrent: current, windows: windows)
    }

    private func window(_ id: Int, pid: Int) -> SelectedWindow {
        SelectedWindow(id: id, pid: pid)
    }

    private func resolvedIcon(_ window: SelectedWindow) -> ResolvedWindowIcon {
        ResolvedWindowIcon(
            windowID: window.id,
            pid: pid_t(window.pid),
            image: NSImage(size: NSSize(width: 16, height: 16)),
            isFallback: window.pid <= 0
        )
    }

    private func label(spaceID: Int, index: Int, current: Bool) -> StatusItemModel {
        StatusItemModel(
            key: .spaceLabel(spaceID: spaceID),
            content: .spaceLabel(index: index, isCurrent: current)
        )
    }

    private func windowItem(
        spaceID: Int,
        windowID: Int,
        pid: Int = 1,
        fallback: Bool = false
    ) -> StatusItemModel {
        StatusItemModel(
            key: .window(spaceID: spaceID, windowID: windowID),
            content: .windowIcon(ResolvedWindowIcon(
                windowID: windowID,
                pid: pid_t(pid),
                image: NSImage(size: NSSize(width: 16, height: 16)),
                isFallback: fallback
            ))
        )
    }
}
