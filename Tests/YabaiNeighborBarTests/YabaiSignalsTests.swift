import XCTest
import Darwin
@testable import YabaiNeighborBar

final class YabaiSignalsTests: XCTestCase {
    func testOwnerPIDParsesLabelsAndFIFOs() {
        XCTAssertEqual(YabaiSignals.ownerPID("yabai-neighbor-bar-25507-space_changed"), 25507)
        XCTAssertEqual(YabaiSignals.ownerPID("yabai-neighbor-bar-25507.fifo"), 25507)
        XCTAssertNil(YabaiSignals.ownerPID("yabai-neighbor-bar-.build.lock"))
        XCTAssertNil(YabaiSignals.ownerPID("other-25507"))
    }

    func testCurrentProcessIsAlive() {
        XCTAssertTrue(YabaiSignals.isAlive(getpid()))
    }

    /// Regression: `printf x > fifo` blocked forever with no reader, piling up
    /// thousands of `sh` processes after the app exited.
    func testSignalActionDoesNotBlockWithoutReader() throws {
        let path = NSTemporaryDirectory() + "yabai-neighbor-bar-test-\(UUID().uuidString).fifo"
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }
        try XCTAssertEqual(runShell(YabaiSignals.signalAction(fifoPath: path)), 0)
    }

    func testSignalActionDoesNotCreateMissingFIFO() throws {
        let path = NSTemporaryDirectory() + "yabai-neighbor-bar-test-\(UUID().uuidString).fifo"
        _ = try runShell(YabaiSignals.signalAction(fifoPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    private func runShell(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            XCTFail("signal action blocked")
            return -1
        }
        return process.terminationStatus
    }
}
