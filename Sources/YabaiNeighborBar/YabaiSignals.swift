import Foundation
import Dispatch
import Darwin

/// yabai writes to a private FIFO on changes; the app re-queries the snapshot.
@MainActor
final class YabaiSignals {
    private let events = ["space_changed", "space_created", "space_destroyed", "space_moved", "display_changed", "display_added", "display_removed", "window_created", "window_destroyed", "window_moved", "window_minimized", "window_deminimized", "application_launched", "application_terminated"]
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let runner = ProcessYabaiRunner()
    private var source: DispatchSourceRead?
    private var descriptor: Int32 = -1
    private var fifoPath: String { NSTemporaryDirectory() + "yabai-neighbor-bar-\(pid).fifo" }
    private var stopped = false
    private var installing = false
    private var refreshWork: DispatchWorkItem?

    func start(refresh: @escaping @MainActor () -> Void) {
        guard mkfifo(fifoPath, 0o600) == 0 else { return }
        descriptor = open(fifoPath, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else { unlink(fifoPath); return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while read(self.descriptor, &buffer, buffer.count) > 0 {}
            // yabai can emit space_changed before its query snapshot settles.
            self.refreshWork?.cancel()
            let work = DispatchWorkItem { refresh() }
            self.refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        source.resume()
        self.source = source
        Task { await install() }
    }

    /// Reinstall after yabai restarts; the slower polling timer also provides recovery.
    func install() async {
        guard !stopped, !installing, let client = YabaiClient.detect() else { return }
        installing = true
        defer { installing = false }
        for event in events {
            guard !stopped else { return }
            let label = "yabai-neighbor-bar-\(pid)-\(event)"
            _ = try? await runner.run(executableURL: client.executableURL,
                                      arguments: ["-m", "signal", "--remove", label], timeout: 5)
            guard !stopped else { return }
            _ = try? await runner.run(executableURL: client.executableURL,
                                      arguments: ["-m", "signal", "--add", "event=\(event)",
                                                  "label=\(label)", "action=printf x > \(fifoPath)"], timeout: 5)
        }
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
        if descriptor >= 0 { close(descriptor); descriptor = -1 }
        unlink(fifoPath)
        refreshWork?.cancel()
        refreshWork = nil
        let pid = pid
        let events = events
        Task.detached {
            guard let client = YabaiClient.detect() else { return }
            let runner = ProcessYabaiRunner()
            for event in events {
                _ = try? await runner.run(executableURL: client.executableURL,
                    arguments: ["-m", "signal", "--remove", "yabai-neighbor-bar-\(pid)-\(event)"], timeout: 5)
            }
        }
    }
}
