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
        Self.removeStaleFIFOs(except: pid)
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
        await removeStaleSignals(client: client)
        for event in events {
            guard !stopped else { return }
            let label = "yabai-neighbor-bar-\(pid)-\(event)"
            _ = try? await runner.run(executableURL: client.executableURL,
                                      arguments: ["-m", "signal", "--remove", label], timeout: 5)
            guard !stopped else { return }
            _ = try? await runner.run(executableURL: client.executableURL,
                                      arguments: ["-m", "signal", "--add", "event=\(event)",
                                                  "label=\(label)", "action=\(Self.signalAction(fifoPath: fifoPath))"], timeout: 5)
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
        // Must finish before the process exits: a detached task never gets to run
        // from applicationWillTerminate, which leaked one signal set per launch.
        guard let client = YabaiClient.detect() else { return }
        for event in events {
            Self.runSync(client.executableURL, ["-m", "signal", "--remove", "yabai-neighbor-bar-\(pid)-\(event)"])
        }
    }

    /// `1<>` opens the FIFO read-write, which never blocks on Darwin even with no
    /// reader; `>` would hang one `sh` per event forever once the app is gone.
    /// `-p` keeps a missing FIFO from being recreated as a regular file.
    nonisolated static func signalAction(fifoPath: String) -> String {
        "[ -p \(fifoPath) ] && printf x 1<> \(fifoPath)"
    }

    /// PID embedded in one of our signal labels or FIFO names, e.g. `yabai-neighbor-bar-123-space_changed`.
    nonisolated static func ownerPID(_ name: String) -> pid_t? {
        guard name.hasPrefix("yabai-neighbor-bar-") else { return nil }
        let rest = name.dropFirst("yabai-neighbor-bar-".count)
        return pid_t(rest.prefix { $0.isNumber })
    }

    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Signals left by instances that crashed or were killed without running `stop()`.
    private func removeStaleSignals(client: YabaiClient) async {
        guard let result = try? await runner.run(executableURL: client.executableURL,
                                                  arguments: ["-m", "signal", "--list"], timeout: 5),
              let list = try? JSONSerialization.jsonObject(with: result.stdout) as? [[String: Any]] else { return }
        for case let label as String in list.compactMap({ $0["label"] }) {
            guard let owner = Self.ownerPID(label), owner != pid, !Self.isAlive(owner) else { continue }
            _ = try? await runner.run(executableURL: client.executableURL,
                                      arguments: ["-m", "signal", "--remove", label], timeout: 5)
        }
    }

    private static func removeStaleFIFOs(except pid: pid_t) {
        let dir = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".fifo") {
            guard let owner = ownerPID(name), owner != pid, !isAlive(owner) else { continue }
            unlink(dir + name)
        }
    }

    /// Bounded blocking run for use during termination.
    private static func runSync(_ url: URL, _ arguments: [String], timeout: TimeInterval = 1) {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return }
        if done.wait(timeout: .now() + timeout) == .timedOut { process.terminate() }
    }
}
