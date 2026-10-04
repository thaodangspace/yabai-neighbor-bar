import Foundation
import XCTest
@testable import YabaiNeighborBar

/// Loads the JSON fixtures copied into the test bundle.
enum Fixture {
    enum Error: Swift.Error {
        case missing(String)
    }

    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw Error.missing(name)
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try url(name))
    }

    static func snapshot(
        displays: String = "displays",
        spaces: String = "spaces",
        windows: String = "windows"
    ) throws -> YabaiSnapshot {
        YabaiSnapshot(
            displays: try YabaiJSONDecoder.decode([YabaiDisplay].self, from: data(displays)),
            spaces: try YabaiJSONDecoder.decode([YabaiSpace].self, from: data(spaces)),
            windows: try YabaiJSONDecoder.decode([YabaiWindow].self, from: data(windows))
        )
    }
}

/// Records calls and returns canned results. An actor so it is trivially
/// `Sendable` while still mutating recorded state across async calls.
actor StubYabaiRunner: YabaiCommandRunning {
    struct Call: Equatable, Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private var calls: [Call] = []
    private var responses: [String: Result<ProcessResult, YabaiClientError>] = [:]

    func setData(forFlag flag: String, data: Data, exitCode: Int32 = 0) {
        responses[flag] = .success(ProcessResult(stdout: data, stderr: Data(), exitCode: exitCode))
    }

    func setFailure(forFlag flag: String, error: YabaiClientError) {
        responses[flag] = .failure(error)
    }

    func recordedCalls() -> [Call] { calls }

    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        calls.append(Call(executableURL: executableURL, arguments: arguments, timeout: timeout))
        let flag = arguments.last ?? ""
        guard let response = responses[flag] else {
            throw YabaiClientError.launchFailed("no stub response for \(flag)")
        }
        return try response.get()
    }
}

final class YabaiClientTests: XCTestCase {

    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/yabai")

    // MARK: - Decoding

    func testDecoderReadsFixtureAndIgnoresExtraFields() throws {
        let snapshot = try Fixture.snapshot()
        XCTAssertEqual(snapshot.displays.count, 2)
        XCTAssertEqual(snapshot.displays.first { $0.hasFocus }?.id, 1)
        XCTAssertEqual(snapshot.spaces.count, 6)
        XCTAssertEqual(snapshot.windows.count, 7)
    }

    func testDecoderReportsMissingRequiredField() throws {
        let data = try Fixture.data("displays-missing-has-focus")
        XCTAssertThrowsError(try YabaiJSONDecoder.decode([YabaiDisplay].self, from: data)) { error in
            XCTAssertEqual(error as? YabaiDecodingError, .missingField("has-focus"))
        }
    }

    func testDecoderReportsMalformedJSON() throws {
        let data = try Fixture.data("malformed")
        XCTAssertThrowsError(try YabaiJSONDecoder.decode([YabaiDisplay].self, from: data)) { error in
            XCTAssertEqual(error as? YabaiDecodingError, .malformedJSON)
        }
    }

    // MARK: - Client

    func testFetchSnapshotDecodesAllThreeQueries() async throws {
        let runner = StubYabaiRunner()
        let snapshot = try Fixture.snapshot()
        for (flag, name) in [("--displays", "displays"), ("--spaces", "spaces"), ("--windows", "windows")] {
            await runner.setData(forFlag: flag, data: try Fixture.data(name))
        }
        let client = YabaiClient(executableURL: executable, timeout: 2, runner: runner)

        let result = try await client.fetchSnapshot()
        XCTAssertEqual(result, snapshot)
    }

    func testQueriesUseArgumentArraysWithoutShellInterpolation() async throws {
        let runner = StubYabaiRunner()
        for (flag, name) in [("--displays", "displays"), ("--spaces", "spaces"), ("--windows", "windows")] {
            await runner.setData(forFlag: flag, data: try Fixture.data(name))
        }
        let client = YabaiClient(executableURL: executable, timeout: 3, runner: runner)
        _ = try await client.fetchSnapshot()

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls.allSatisfy { $0.executableURL == executable })
        XCTAssertTrue(calls.allSatisfy { $0.timeout == 3 })
        let argumentSets = Set(calls.map(\.arguments))
        XCTAssertEqual(argumentSets, [
            ["-m", "query", "--displays"],
            ["-m", "query", "--spaces"],
            ["-m", "query", "--windows"],
        ])
    }

    func testNonzeroExitSurfacesTypedError() async throws {
        let runner = StubYabaiRunner()
        await runner.setData(forFlag: "--displays", data: Data(), exitCode: 7)
        await runner.setData(forFlag: "--spaces", data: try Fixture.data("spaces"))
        await runner.setData(forFlag: "--windows", data: try Fixture.data("windows"))
        let client = YabaiClient(executableURL: executable, runner: runner)

        await assertThrows(.nonzeroExit(7)) { _ = try await client.fetchSnapshot() }
    }

    func testMalformedJSONSurfacesDecodingError() async throws {
        let runner = StubYabaiRunner()
        await runner.setData(forFlag: "--displays", data: try Fixture.data("malformed"))
        await runner.setData(forFlag: "--spaces", data: try Fixture.data("spaces"))
        await runner.setData(forFlag: "--windows", data: try Fixture.data("windows"))
        let client = YabaiClient(executableURL: executable, runner: runner)

        await assertThrows(.decoding(.malformedJSON)) { _ = try await client.fetchSnapshot() }
    }

    func testMissingFieldSurfacesDecodingError() async throws {
        let runner = StubYabaiRunner()
        await runner.setData(forFlag: "--displays", data: try Fixture.data("displays-missing-has-focus"))
        await runner.setData(forFlag: "--spaces", data: try Fixture.data("spaces"))
        await runner.setData(forFlag: "--windows", data: try Fixture.data("windows"))
        let client = YabaiClient(executableURL: executable, runner: runner)

        await assertThrows(.decoding(.missingField("has-focus"))) { _ = try await client.fetchSnapshot() }
    }

    func testRunnerTimeoutPropagates() async throws {
        let runner = StubYabaiRunner()
        await runner.setFailure(forFlag: "--displays", error: .timedOut)
        await runner.setData(forFlag: "--spaces", data: try Fixture.data("spaces"))
        await runner.setData(forFlag: "--windows", data: try Fixture.data("windows"))
        let client = YabaiClient(executableURL: executable, runner: runner)

        await assertThrows(.timedOut) { _ = try await client.fetchSnapshot() }
    }

    // MARK: - Executable locator

    func testLocatorPrefersExplicitOverride() {
        let url = YabaiExecutableLocator.locate(
            environment: ["YABAI_PATH": "/bin/echo"],
            fileManager: .default,
            commonPaths: []
        )
        XCTAssertEqual(url?.path, "/bin/echo")
    }

    func testLocatorFindsExecutableOnPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let candidate = directory.appendingPathComponent("yabai")
        try "#!/bin/sh\n".write(to: candidate, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)

        let url = YabaiExecutableLocator.locate(
            environment: ["PATH": directory.path],
            fileManager: .default,
            commonPaths: []
        )
        XCTAssertEqual(url?.path, candidate.path)
    }

    func testLocatorReturnsNilWhenNothingMatches() {
        let url = YabaiExecutableLocator.locate(
            environment: ["PATH": "/nonexistent-dir"],
            fileManager: .default,
            commonPaths: []
        )
        XCTAssertNil(url)
    }

    // MARK: - Real process runner (no shell)

    func testProcessRunnerCapturesStdoutAndExitCode() async throws {
        let result = try await ProcessYabaiRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"],
            timeout: 5
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello world\n")
    }

    func testProcessRunnerReportsNonzeroExit() async throws {
        let result = try await ProcessYabaiRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 5
        )
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// Guards against pipe-capture races with output far larger than the pipe
    /// buffer, forcing many read callbacks plus the final drain.
    func testProcessRunnerCapturesLargeMultiChunkOutput() async throws {
        let count = 200_000
        let result = try await ProcessYabaiRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "\(count)"],
            timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        let expected = (1...count).map(String.init).joined(separator: "\n") + "\n"
        XCTAssertEqual(result.stdout.count, expected.utf8.count)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), expected)
    }

    func testProcessRunnerTerminatesOnTimeout() async {
        let start = Date()
        do {
            _ = try await ProcessYabaiRunner().run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.3
            )
            XCTFail("expected timeout")
        } catch let error as YabaiClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: - Live smoke check (read-only)

    func testLiveYabaiSnapshotWhenAvailable() async throws {
        guard let executable = YabaiExecutableLocator.locate() else {
            throw XCTSkip("yabai is not installed; skipping live smoke check")
        }
        let client = YabaiClient(executableURL: executable, timeout: 5)
        let snapshot: YabaiSnapshot
        do {
            snapshot = try await client.fetchSnapshot()
        } catch let error as YabaiClientError {
            // yabai being installed does not guarantee the daemon is healthy
            // (e.g. it can emit partial JSON with exit 0). Error handling is
            // covered by the stub-based tests; skip the live positive check.
            throw XCTSkip("yabai is installed but not serving a usable snapshot (\(error)); skipping live smoke check")
        }
        XCTAssertFalse(snapshot.displays.isEmpty)
        XCTAssertTrue(snapshot.displays.contains(where: \.hasFocus))
        let selection = NeighborSelector.select(from: snapshot)
        XCTAssertFalse(selection.isEmpty)
        // If yabai reports any windows at all, the selected current Space must
        // resolve at least one; otherwise the membership cross-check is wrong.
        if !snapshot.windows.isEmpty {
            XCTAssertTrue(selection.contains { !$0.windows.isEmpty })
        }
    }

    // MARK: - Helpers

    private func assertThrows(
        _ expected: YabaiClientError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as YabaiClientError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
