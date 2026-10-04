import Foundation

/// A window chosen for display: yabai window `id` plus the owning process `pid`.
///
/// The same `pid` may appear more than once within one Space (multiple windows of
/// one app), and each occurrence is kept as its own entry so icon counts stay
/// accurate. Icon resolution happens later, in Phase 3.
struct SelectedWindow: Equatable, Sendable {
    let id: Int
    let pid: Int
}

/// A Space chosen for the menu bar, in the order it should be rendered:
/// previous → current → next. `index` is the yabai Space label; `isCurrent` marks
/// the focused Space. An empty Space is still emitted (with no windows).
struct SelectedSpace: Equatable, Sendable {
    let id: Int
    let index: Int
    let isCurrent: Bool
    let windows: [SelectedWindow]
}

/// Pure, side-effect-free neighbor selection.
enum NeighborSelector {
    /// Selects the focused display's current Space and its immediate neighbors.
    ///
    /// Rules:
    /// - Only the display with `hasFocus == true` is considered; no display focus
    ///   yields an empty selection.
    /// - Spaces are filtered to that display and sorted by `index` (tie-broken by
    ///   `id`) so first/last/only Space behave predictably.
    /// - The selected window is the one with `hasFocus == true`; if none is marked
    ///   in a consistent snapshot the selection is empty.
    /// - Missing neighbors are omitted rather than compensated from the other side.
    /// - Within a Space, window ids follow the Space's `windows` array order, ids are
    ///   deduplicated within that Space only, and an id that cannot be resolved to a
    ///   window (or whose recorded `space` disagrees with the Space's `index`) is
    ///   dropped consistently.
    static func select(from snapshot: YabaiSnapshot, allSpaces: Bool = false) -> [SelectedSpace] {
        guard let focusedDisplay = snapshot.displays.first(where: \.hasFocus) else {
            return []
        }

        let displaySpaces = snapshot.spaces
            .filter { $0.display == focusedDisplay.id }
            .sorted { lhs, rhs in
                lhs.index == rhs.index ? lhs.id < rhs.id : lhs.index < rhs.index
            }
        guard !displaySpaces.isEmpty,
              let currentPosition = displaySpaces.firstIndex(where: \.hasFocus)
        else {
            return []
        }

        var chosen: [YabaiSpace] = []
        if allSpaces {
            chosen = displaySpaces
        } else {
            if currentPosition > 0 { chosen.append(displaySpaces[currentPosition - 1]) }
            chosen.append(displaySpaces[currentPosition])
            if currentPosition + 1 < displaySpaces.count { chosen.append(displaySpaces[currentPosition + 1]) }
        }

        let windowsByID = Dictionary(
            snapshot.windows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return chosen.map { space in
            var seen = Set<Int>()
            var windows: [SelectedWindow] = []
            for windowID in space.windows {
                guard seen.insert(windowID).inserted else { continue }
                guard let window = windowsByID[windowID], window.space == space.index else { continue }
                windows.append(SelectedWindow(id: window.id, pid: window.pid))
            }
            return SelectedSpace(
                id: space.id,
                index: space.index,
                isCurrent: space.hasFocus,
                windows: windows
            )
        }
    }
}
