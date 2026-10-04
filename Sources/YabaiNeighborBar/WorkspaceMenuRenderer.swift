import AppKit

/// Up to three neighboring Spaces in the menu bar, each with a Space menu.
@MainActor
final class WorkspaceMenuRenderer {
    private var item: NSStatusItem?

    func render(spaces: [SelectedSpace], menuSpaces: [SelectedSpace], resolver: IconResolver) {
        guard spaces.contains(where: \.isCurrent) else { clear(); return }
        let visible = spaces
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        item?.button?.title = ""
        item?.button?.image = workspaceImage(visible, resolver: resolver)
        item?.button?.imagePosition = .imageOnly
        item?.button?.toolTip = "Spaces \(visible.map { String($0.index) }.joined(separator: ", ")) — click to see all Spaces"
        item?.menu = makeMenu(spaces: menuSpaces, resolver: resolver)
    }

    private func makeMenu(spaces: [SelectedSpace], resolver: IconResolver) -> NSMenu {
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
                let row = NSMenuItem(title: "    \(name)", action: #selector(activateApp(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = NSNumber(value: window.pid)
                row.image = resolver.icon(forPID: pid_t(window.pid)).image
                row.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(row)
            }
            if space.id != spaces.last?.id { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit YabaiNeighborBar", action: #selector(quitApp(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func activateApp(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.int32Value,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return }
        app.activate(options: [.activateAllWindows])
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

    /// Draw all Spaces in one status item so macOS cannot reorder them independently.
    private func workspaceImage(_ spaces: [SelectedSpace], resolver: IconResolver) -> NSImage {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let groups = spaces.map { space in
            (space, uniqueApps(in: space).map { resolver.icon(forPID: pid_t($0.pid)).image })
        }
        let widths = groups.map { space, icons in
            ceil((String(space.index) as NSString).size(withAttributes: attributes).width) + CGFloat(icons.count) * 20 + 20
        }
        let separatorWidth: CGFloat = 12
        let image = NSImage(size: NSSize(width: widths.reduce(0, +) + CGFloat(max(0, groups.count - 1)) * separatorWidth, height: 22))
        image.lockFocus()
        var x: CGFloat = 0
        for (position, (space, icons)) in groups.enumerated() {
            let width = widths[position]
            if position > 0 {
                NSColor.white.withAlphaComponent(0.65).setStroke()
                let separator = NSBezierPath()
                separator.move(to: NSPoint(x: x - separatorWidth / 2, y: 5))
                separator.line(to: NSPoint(x: x - separatorWidth / 2, y: 17))
                separator.lineWidth = 1
                separator.stroke()
            }
            if space.isCurrent {
                NSColor.white.setStroke()
                let underline = NSBezierPath()
                underline.move(to: NSPoint(x: x + 3, y: 1))
                underline.line(to: NSPoint(x: x + width - 3, y: 1))
                underline.lineWidth = 1
                underline.stroke()
            }
            let label = String(space.index) as NSString
            label.draw(at: NSPoint(x: x + 7, y: 3), withAttributes: attributes)
            let iconStart = x + 13 + ceil(label.size(withAttributes: attributes).width)
            for (index, icon) in icons.enumerated() {
                icon.draw(in: NSRect(x: iconStart + CGFloat(index) * 20, y: 3, width: 16, height: 16))
            }
            x += width + separatorWidth
        }
        image.unlockFocus()
        return image
    }
}
