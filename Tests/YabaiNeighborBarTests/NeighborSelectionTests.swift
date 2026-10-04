import XCTest
@testable import YabaiNeighborBar

/// Pure selection tests. Arrays are constructed directly (and the shared fixture
/// is used where realistic JSON is helpful) so every edge case is explicit.
final class NeighborSelectionTests: XCTestCase {

    // MARK: - Fixture-backed happy path

    func testMiddleSpacePreservesWindowOrderDuplicatePIDsAndDropsUnresolvedIDs() throws {
        let snapshot = try Fixture.snapshot()
        let selection = NeighborSelector.select(from: snapshot)

        XCTAssertEqual(selection, [
            SelectedSpace(id: 11, index: 1, isCurrent: false, windows: [
                SelectedWindow(id: 101, pid: 1001)
            ]),
            SelectedSpace(id: 22, index: 2, isCurrent: true, windows: [
                // Two windows share pid 2002 and must both survive.
                SelectedWindow(id: 102, pid: 2002),
                SelectedWindow(id: 103, pid: 2002),
                SelectedWindow(id: 104, pid: 3003)
            ]),
            // Space 3 lists [105, 999, 105, 106]: 999 is unresolved, 105 repeats.
            SelectedSpace(id: 33, index: 3, isCurrent: false, windows: [
                SelectedWindow(id: 105, pid: 4004),
                SelectedWindow(id: 106, pid: 5005)
            ])
        ])
    }

    func testSelectionIsDeterministic() throws {
        let snapshot = try Fixture.snapshot()
        XCTAssertEqual(NeighborSelector.select(from: snapshot), NeighborSelector.select(from: snapshot))
    }

    // MARK: - Boundary spaces

    func testFirstSpaceHasNoPreviousNeighbor() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [101]),
                     space(22, index: 2, display: 1, focus: false, windows: [])],
            windows: [window(101, pid: 1, space: 1)]
        )
        XCTAssertEqual(NeighborSelector.select(from: snapshot).map(\.index), [1, 2])
    }

    func testLastSpaceHasNoNextNeighbor() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: false, windows: []),
                     space(22, index: 2, display: 1, focus: true, windows: [])],
            windows: []
        )
        XCTAssertEqual(NeighborSelector.select(from: snapshot).map(\.index), [1, 2])
    }

    func testBoundaryCompensationAndAllSpaces() {
        let spaces = (1...5).map { space($0 * 11, index: $0, display: 1, focus: $0 == 1, windows: []) }
        let first = makeSnapshot(displays: [display(1, focus: true)], spaces: spaces, windows: [])
        XCTAssertEqual(NeighborSelector.select(from: first).map(\.index), [1, 2, 3])
        XCTAssertEqual(NeighborSelector.select(from: first, allSpaces: true).map(\.index), [1, 2, 3, 4, 5])

        let last = makeSnapshot(displays: [display(1, focus: true)], spaces: spaces.map {
            space($0.id, index: $0.index, display: 1, focus: $0.index == 5, windows: [])
        }, windows: [])
        XCTAssertEqual(NeighborSelector.select(from: last).map(\.index), [3, 4, 5])
        XCTAssertEqual(NeighborSelector.select(from: last, allSpaces: true).map(\.index), [1, 2, 3, 4, 5])
    }

    func testOnlySpaceOnDisplaySelectsJustItself() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 3, display: 1, focus: true, windows: [])],
            windows: []
        )
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.first?.index, 3)
        XCTAssertEqual(selection.first?.isCurrent, true)
    }

    func testEmptyCurrentSpaceStillSelected() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: false, windows: [101]),
                     space(22, index: 2, display: 1, focus: true, windows: []),
                     space(33, index: 3, display: 1, focus: false, windows: [])],
            windows: [window(101, pid: 1, space: 1)]
        )
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertEqual(selection.map(\.index), [1, 2, 3])
        XCTAssertEqual(selection[1].windows, [])
        XCTAssertEqual(selection[1].isCurrent, true)
    }

    // MARK: - Focus routing

    func testMultiDisplaySelectsOnlyFocusedDisplay() throws {
        var snapshot = try Fixture.snapshot()
        snapshot = YabaiSnapshot(
            displays: snapshot.displays.map { display in
                YabaiDisplay(id: display.id, index: display.index, hasFocus: display.id == 2)
            },
            spaces: snapshot.spaces,
            windows: snapshot.windows
        )
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertEqual(selection.map(\.index), [5, 6])
        XCTAssertEqual(selection.first?.windows, [SelectedWindow(id: 201, pid: 6006)])
        XCTAssertEqual(selection.last?.isCurrent, true)
    }

    func testNoFocusedDisplayYieldsEmptySelection() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: false), display(2, focus: false)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [])],
            windows: []
        )
        XCTAssertTrue(NeighborSelector.select(from: snapshot).isEmpty)
    }

    func testFocusedDisplayWithoutFocusedSpaceYieldsEmptySelection() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: false, windows: []),
                     space(22, index: 2, display: 1, focus: false, windows: [])],
            windows: []
        )
        XCTAssertTrue(NeighborSelector.select(from: snapshot).isEmpty)
    }

    func testFocusedDisplayWithoutAnySpacesYieldsEmptySelection() {
        let snapshot = makeSnapshot(displays: [display(1, focus: true)], spaces: [], windows: [])
        XCTAssertTrue(NeighborSelector.select(from: snapshot).isEmpty)
    }

    // MARK: - Ordering

    func testSpacesAreSortedByIndexRegardlessOfQueryOrder() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(33, index: 3, display: 1, focus: false, windows: [303]),
                     space(11, index: 1, display: 1, focus: false, windows: [101]),
                     space(22, index: 2, display: 1, focus: true, windows: [202])],
            windows: [window(101, pid: 1, space: 1),
                      window(202, pid: 2, space: 2),
                      window(303, pid: 3, space: 3)]
        )
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertEqual(selection.map(\.index), [1, 2, 3])
        XCTAssertEqual(selection.map(\.isCurrent), [false, true, false])
    }

    func testDuplicateSpaceIndexIsTieBrokenByID() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(22, index: 1, display: 1, focus: false, windows: []),
                     space(11, index: 1, display: 1, focus: true, windows: []),
                     space(33, index: 2, display: 1, focus: false, windows: [])],
            windows: []
        )
        // Sorted as id 11 then id 22; fill the third slot with id 33.
        XCTAssertEqual(NeighborSelector.select(from: snapshot).map(\.id), [11, 22, 33])
    }

    // MARK: - Window membership

    func testWindowOrderFollowsSpaceArrayNotWindowQueryOrder() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [104, 102, 103])],
            windows: [window(102, pid: 2, space: 1),
                      window(103, pid: 3, space: 1),
                      window(104, pid: 4, space: 1)]
        )
        XCTAssertEqual(
            NeighborSelector.select(from: snapshot).first?.windows,
            [SelectedWindow(id: 104, pid: 4),
             SelectedWindow(id: 102, pid: 2),
             SelectedWindow(id: 103, pid: 3)]
        )
    }

    func testDuplicateWindowIDIsDeduplicatedWithinOneSpaceOnly() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [101, 101])],
            windows: [window(101, pid: 1, space: 1)]
        )
        XCTAssertEqual(
            NeighborSelector.select(from: snapshot).first?.windows,
            [SelectedWindow(id: 101, pid: 1)]
        )
    }

    func testUnresolvedWindowIDIsDroppedConsistently() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [101, 999, 102])],
            windows: [window(101, pid: 1, space: 1),
                      window(102, pid: 2, space: 1)]
        )
        XCTAssertEqual(
            NeighborSelector.select(from: snapshot).first?.windows,
            [SelectedWindow(id: 101, pid: 1),
             SelectedWindow(id: 102, pid: 2)]
        )
    }

    func testWindowWhoseRecordedSpaceDisagreesIsDropped() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: [101])],
            windows: [window(101, pid: 1, space: 2)]
        )
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(selection.first?.windows, [])
    }

    func testSpacesBelongingToOtherDisplayAreIgnored() {
        let snapshot = makeSnapshot(
            displays: [display(1, focus: true)],
            spaces: [space(11, index: 1, display: 1, focus: true, windows: []),
                     space(99, index: 2, display: 99, focus: false, windows: [])],
            windows: []
        )
        XCTAssertEqual(NeighborSelector.select(from: snapshot).map(\.index), [1])
    }

    // MARK: - Helpers

    private func makeSnapshot(
        displays: [YabaiDisplay],
        spaces: [YabaiSpace],
        windows: [YabaiWindow]
    ) -> YabaiSnapshot {
        YabaiSnapshot(displays: displays, spaces: spaces, windows: windows)
    }

    private func display(_ id: Int, focus: Bool) -> YabaiDisplay {
        YabaiDisplay(id: id, index: id, hasFocus: focus)
    }

    private func space(_ id: Int, index: Int, display: Int, focus: Bool, windows: [Int]) -> YabaiSpace {
        YabaiSpace(id: id, index: index, display: display, hasFocus: focus, windows: windows)
    }

    private func window(_ id: Int, pid: Int, space: Int) -> YabaiWindow {
        YabaiWindow(id: id, pid: pid, space: space)
    }
}
