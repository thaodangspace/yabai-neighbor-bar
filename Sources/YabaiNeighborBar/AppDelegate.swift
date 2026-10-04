import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "dev.local.YabaiNeighborBar", category: "refresh")
    private static let refreshInterval: TimeInterval = 30

    private let renderer = WorkspaceMenuRenderer()
    private let iconResolver = IconResolver()
    private let signals = YabaiSignals()
    private var signalTimer: Timer?
    private var coordinator: RefreshCoordinator<YabaiSnapshot>?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var errorItem: NSStatusItem?
    private var lastError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        coordinator = RefreshCoordinator(fetch: {
            // Re-detect every time so installing/restarting yabai can recover
            // without requiring the menu-bar app to restart.
            guard let client = YabaiClient.detect() else { throw YabaiClientError.executableNotFound }
            return try await client.fetchSnapshot()
        }, receive: { [weak self] result in
            self?.accept(result)
        })
        signals.start { [weak self] in self?.coordinator?.refresh() }
        coordinator?.refresh()
        signalTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            _ = MainActor.assumeIsolated { Task { await self?.signals.install() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        timer?.invalidate()
        signalTimer?.invalidate()
        signals.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        clearError()
        renderer.clear()
    }

    private func accept(_ result: Result<YabaiSnapshot, Error>) {
        switch result {
        case let .success(snapshot):
            let selection = NeighborSelector.select(from: snapshot, allSpaces: true)
            guard !selection.isEmpty else {
                showError("No focused Space reported by yabai")
                return
            }
            clearError()
            renderer.render(spaces: selection, resolver: iconResolver)
        case let .failure(error):
            showError(String(describing: error))
        }
    }

    private func showError(_ reason: String) {
        renderer.clear()
        if lastError != reason {
            Self.logger.error("Snapshot unavailable: \(reason, privacy: .public)")
            lastError = reason
        }
        if errorItem == nil {
            errorItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        errorItem?.button?.title = "Yabai ⚠"
        errorItem?.button?.toolTip = "Yabai Neighbor Bar: \(reason) (retrying automatically)"
    }

    private func clearError() {
        if let errorItem { NSStatusBar.system.removeStatusItem(errorItem) }
        errorItem = nil
        if lastError != nil { Self.logger.info("Yabai snapshot recovered") }
        lastError = nil
    }
}

@main
struct YabaiNeighborBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
