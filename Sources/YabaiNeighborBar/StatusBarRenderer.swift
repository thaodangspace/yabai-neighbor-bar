import AppKit

/// Resolved per-window icon. The same app's icon may back several windows of one
/// Space; each window keeps its own identity so icon counts never collapse.
struct ResolvedWindowIcon: Equatable {
    let windowID: Int
    let pid: pid_t
    let image: NSImage
    let isFallback: Bool
}

/// Stable identity of a menu bar element across refreshes. Space labels are keyed
/// by Space id and windows by (Space id, window id), so reconciliation can reuse
/// items even when Space indices move.
enum StatusItemKey: Hashable {
    case spaceLabel(spaceID: Int)
    case window(spaceID: Int, windowID: Int)
}

struct StatusItemModel: Equatable {
    enum Content: Equatable {
        case spaceLabel(index: Int, isCurrent: Bool)
        case windowIcon(ResolvedWindowIcon)
    }

    let key: StatusItemKey
    let content: Content
}

/// Ordered, reconciliation-ready menu bar model: previous Space, its windows,
/// current Space, its windows, next Space, its windows.
struct StatusBarModel: Equatable {
    let items: [StatusItemModel]

    /// Builds the render model from a neighbor selection. Icon resolution is
    /// injected so the mapping stays side-effect-free and unit-testable.
    static func make(
        from spaces: [SelectedSpace],
        resolveIcon: (SelectedWindow) -> ResolvedWindowIcon
    ) -> StatusBarModel {
        var items: [StatusItemModel] = []
        for space in spaces {
            items.append(StatusItemModel(
                key: .spaceLabel(spaceID: space.id),
                content: .spaceLabel(index: space.index, isCurrent: space.isCurrent)
            ))
            for window in space.windows {
                items.append(StatusItemModel(
                    key: .window(spaceID: space.id, windowID: window.id),
                    content: .windowIcon(resolveIcon(window))
                ))
            }
        }
        return StatusBarModel(items: items)
    }
}

/// One native menu bar element. Abstracted so reconciliation is testable without a
/// live `NSStatusBar`.
@MainActor
protocol StatusItemHandle: AnyObject {
    func apply(_ content: StatusItemModel.Content)
    func remove()
}

/// Creates native handles. Abstracted alongside `StatusItemHandle`.
@MainActor
protocol StatusItemHost: AnyObject {
    func makeHandle() -> any StatusItemHandle
}

/// Reconciliation-safe renderer.
///
/// Each render diffs the desired complete model against the native items. The
/// longest unchanged prefix of keys is reused (no flicker/reorder); stale handles
/// are removed; only items required by the new order are (re)created. AppKit
/// appends new status items, so an order change beyond the shared prefix is
/// realized by recreating the affected suffix. The native items always end up in
/// the model's order.
@MainActor
final class StatusBarRenderer {
    private let host: any StatusItemHost
    private var handles: [StatusItemKey: any StatusItemHandle] = [:]
    private var nativeOrder: [StatusItemKey] = []

    init(host: any StatusItemHost = SystemStatusItemHost()) {
        self.host = host
    }

    func render(_ model: StatusBarModel) {
        let desired = Self.deduplicated(model.items)
        let desiredKeys = desired.map(\.key)

        let prefix = Self.commonPrefixLength(nativeOrder, desiredKeys)
        let survivingKeys = Set(nativeOrder.prefix(prefix))

        // Remove every handle that is not part of the surviving prefix.
        for key in Array(handles.keys) where !survivingKeys.contains(key) {
            handles.removeValue(forKey: key)?.remove()
        }
        nativeOrder = Array(nativeOrder.prefix(prefix))

        // Refresh reused prefix content, then create the rest in order.
        for item in desired.prefix(prefix) {
            handles[item.key]?.apply(item.content)
        }
        for item in desired.dropFirst(prefix) {
            let handle = handles[item.key] ?? host.makeHandle()
            handle.apply(item.content)
            handles[item.key] = handle
            nativeOrder.append(item.key)
        }
    }

    func clear() {
        for handle in handles.values { handle.remove() }
        handles.removeAll()
        nativeOrder.removeAll()
    }

    /// Number of native items currently owned by the renderer.
    var itemCount: Int { nativeOrder.count }

    private static func deduplicated(_ items: [StatusItemModel]) -> [StatusItemModel] {
        var seen = Set<StatusItemKey>()
        var result: [StatusItemModel] = []
        for item in items where seen.insert(item.key).inserted {
            result.append(item)
        }
        return result
    }

    private static func commonPrefixLength(_ lhs: [StatusItemKey], _ rhs: [StatusItemKey]) -> Int {
        var length = 0
        while length < lhs.count, length < rhs.count, lhs[length] == rhs[length] {
            length += 1
        }
        return length
    }
}

/// Production host backed by the system status bar.
@MainActor
final class SystemStatusItemHost: StatusItemHost {
    func makeHandle() -> any StatusItemHandle {
        SystemStatusItemHandle(
            statusItem: NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        )
    }
}

@MainActor
private final class SystemStatusItemHandle: StatusItemHandle {
    private let statusItem: NSStatusItem

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func apply(_ content: StatusItemModel.Content) {
        guard let button = statusItem.button else { return }
        switch content {
        case let .spaceLabel(index, isCurrent):
            button.image = nil
            button.imagePosition = .noImage
            button.title = isCurrent ? "[\(index)]" : "\(index)"
            button.toolTip = isCurrent ? "Current Space \(index)" : "Space \(index)"
        case let .windowIcon(icon):
            button.title = ""
            button.image = icon.image
            button.imagePosition = .imageOnly
            // Never surface a window title; only the window id and fallback state.
            button.toolTip = icon.isFallback
                ? "Window \(icon.windowID) (icon unavailable)"
                : "Window \(icon.windowID)"
        }
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

/// Monotonic generation counter used to drop stale async snapshot completions.
///
/// A refresh captures the token returned by `next()`; when it finishes it may only
/// touch the UI if `isCurrent(token)` still holds, i.e. no newer refresh started.
struct SnapshotGeneration: Equatable {
    private(set) var current: UInt64 = 0

    mutating func next() -> UInt64 {
        current &+= 1
        return current
    }

    func isCurrent(_ token: UInt64) -> Bool {
        token == current
    }
}
