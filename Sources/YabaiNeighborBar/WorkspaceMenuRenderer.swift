import AppKit

/// A single menu-bar item: icons from the focused Space, with every Space in its menu.
@MainActor
final class WorkspaceMenuRenderer {
    private var item: NSStatusItem?

    func render(spaces: [SelectedSpace], resolver: IconResolver) {
        guard let current = spaces.first(where: \.isCurrent) else { clear(); return }
        if item == nil {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        guard let item else { return }
        let icons = uniqueApps(in: current).map { resolver.icon(forPID: pid_t($0.pid)).image }
        item.button?.title = "\(current.index)"
        item.button?.image = icons.isEmpty ? nil : composite(icons)
        item.button?.imagePosition = icons.isEmpty ? .noImage : .imageRight
        item.button?.toolTip = "Space \(current.index) — click to see all Spaces"

        let menu = NSMenu()
        for space in spaces {
            let header = NSMenuItem(title: "Space \(space.index)\(space.isCurrent ? " ✓" : "")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if space.windows.isEmpty {
                let empty = NSMenuItem(title: "    No apps", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for window in uniqueApps(in: space) {
                let app = NSRunningApplication(processIdentifier: pid_t(window.pid))
                let name = app?.localizedName ?? "App (PID \(window.pid))"
                let row = NSMenuItem(title: "    \(name)", action: nil, keyEquivalent: "")
                row.image = resolver.icon(forPID: pid_t(window.pid)).image
                row.image?.size = NSSize(width: 16, height: 16)
                row.isEnabled = false
                menu.addItem(row)
            }
            if space.id != spaces.last?.id { menu.addItem(.separator()) }
        }
        item.menu = menu
    }

    func clear() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Keep the first window for each app, preserving yabai's window order.
    /// A missing bundle identifier falls back to PID so unrelated apps are not merged.
    private func uniqueApps(in space: SelectedSpace) -> [SelectedWindow] {
        var seen = Set<String>()
        return space.windows.filter { window in
            let pid = pid_t(window.pid)
            let key = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                .map { "bundle:\($0)" } ?? "pid:\(pid)"
            return seen.insert(key).inserted
        }
    }

    private func composite(_ icons: [NSImage]) -> NSImage {
        let size = NSSize(width: CGFloat(icons.count) * 20, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        for (index, icon) in icons.enumerated() {
            icon.draw(in: NSRect(x: CGFloat(index) * 20, y: 1, width: 16, height: 16))
        }
        image.unlockFocus()
        return image
    }
}
