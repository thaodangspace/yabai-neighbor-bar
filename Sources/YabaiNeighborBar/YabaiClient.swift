import Foundation

/// Result of one bounded process invocation.
struct ProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

/// Injectable process runner so the client can be tested without spawning yabai.
///
/// Implementations must run the executable with an argument array (never a shell
/// string), capture stdout/stderr, enforce the timeout by terminating the child,
/// and surface a stable error type.
protocol YabaiCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

enum YabaiClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case executableNotFound
    case timedOut
    case launchFailed(String)
    case nonzeroExit(Int32)
    case decoding(YabaiDecodingError)

    var description: String {
        switch self {
        case .executableNotFound:
            return "yabai executable not found"
        case .timedOut:
            return "yabai query timed out"
        case let .launchFailed(message):
            return "failed to launch yabai: \(message)"
        case let .nonzeroExit(code):
            return "yabai exited with status \(code)"
        case let .decoding(error):
            return error.description
        }
    }
}

/// Locates the yabai executable without invoking a shell.
enum YabaiExecutableLocator {
    static let commonPaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
        "/usr/bin/yabai",
    ]

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        commonPaths: [String] = YabaiExecutableLocator.commonPaths
    ) -> URL? {
        if let override = environment["YABAI_PATH"], !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for path in commonPaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":") where !directory.isEmpty {
                let candidate = "\(directory)/yabai"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }
}

/// Bounded, shell-free reader of yabai's JSON snapshot.
struct YabaiClient: Sendable {
    static let defaultTimeout: TimeInterval = 5

    let executableURL: URL
    let timeout: TimeInterval
    let runner: any YabaiCommandRunning

    init(
        executableURL: URL,
        timeout: TimeInterval = YabaiClient.defaultTimeout,
        runner: any YabaiCommandRunning = ProcessYabaiRunner()
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.runner = runner
    }

    /// Builds a client for the installed yabai, or nil when yabai cannot be found.
    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        runner: any YabaiCommandRunning = ProcessYabaiRunner()
    ) -> YabaiClient? {
        guard let url = YabaiExecutableLocator.locate(environment: environment, fileManager: fileManager) else {
            return nil
        }
        return YabaiClient(executableURL: url, runner: runner)
    }

    /// Fetches displays, spaces and windows as one snapshot.
    ///
    /// The three queries run concurrently for latency, but each is treated as
    /// untrusted input and cross-checked by id during selection; a snapshot that
    /// changes between queries is corrected on the next refresh.
    func fetchSnapshot() async throws -> YabaiSnapshot {
        async let displays = queryDisplays()
        async let spaces = querySpaces()
        async let windows = queryWindows()
        return try await YabaiSnapshot(displays: displays, spaces: spaces, windows: windows)
    }

    func queryDisplays() async throws -> [YabaiDisplay] {
        try await query(flag: "--displays")
    }

    func querySpaces() async throws -> [YabaiSpace] {
        try await query(flag: "--spaces")
    }

    func queryWindows() async throws -> [YabaiWindow] {
        try await query(flag: "--windows")
    }

    private func query<T: Decodable>(flag: String) async throws -> T {
        let result = try await runner.run(
            executableURL: executableURL,
            arguments: ["-m", "query", flag],
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw YabaiClientError.nonzeroExit(result.exitCode)
        }
        do {
            return try YabaiJSONDecoder.decode(T.self, from: result.stdout)
        } catch let error as YabaiDecodingError {
            throw YabaiClientError.decoding(error)
        }
    }
}

/// Default runner: an asynchronous `Process` invocation with a hard wall-clock
/// timeout. No shell is involved; arguments are passed as an array.
final class ProcessYabaiRunner: YabaiCommandRunning, @unchecked Sendable {
    func run(executableURL: URL, arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let session = ProcessSession(executableURL: executableURL, arguments: arguments)
        return try await withCheckedThrowingContinuation { continuation in
            session.start(continuation: continuation, timeout: timeout)
        }
    }
}

/// Owns one in-flight process and the state shared between its pipe readers, its
/// termination handler and the timeout. All mutable state is lock-guarded.
private final class ProcessSession: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()

    private var stdoutData = Data()
    private var stderrData = Data()
    private var hasFinished = false
    private var didTimeOut = false

    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start(continuation: CheckedContinuation<ProcessResult, Error>, timeout: TimeInterval) {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            self?.capture(handle.availableData, isStdout: true)
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            self?.capture(handle.availableData, isStdout: false)
        }
        // Strong capture keeps the session alive until the process ends; the
        // handler is cleared in `finish` to break the retain cycle.
        process.terminationHandler = { [self] process in
            self.finishAfterTermination(process, continuation: continuation)
        }

        do {
            try process.run()
        } catch {
            finish(continuation, result: .failure(YabaiClientError.launchFailed(error.localizedDescription)))
            return
        }
        // Arm the deadline only once the process has launched, so a slow launch
        // cannot mark a not-yet-started process as timed out (and leak the child).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finishAfterTimeout(continuation: continuation)
        }
    }

    private func capture(_ data: Data, isStdout: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if isStdout {
            stdoutData.append(data)
        } else {
            stderrData.append(data)
        }
        lock.unlock()
    }

    private func finishAfterTermination(
        _ process: Process,
        continuation: CheckedContinuation<ProcessResult, Error>
    ) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        capture(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: true)
        capture(stderrPipe.fileHandleForReading.readDataToEndOfFile(), isStdout: false)

        lock.lock()
        let timedOut = didTimeOut
        let result = ProcessResult(stdout: stdoutData, stderr: stderrData, exitCode: process.terminationStatus)
        lock.unlock()
        // If the deadline already fired, the timeout is authoritative even when
        // the termination handler runs first (terminate() races this callback).
        finish(continuation, result: timedOut ? .failure(YabaiClientError.timedOut) : .success(result))
    }

    private func finishAfterTimeout(continuation: CheckedContinuation<ProcessResult, Error>) {
        lock.lock()
        let alreadyFinished = hasFinished
        if !alreadyFinished {
            didTimeOut = true
        }
        lock.unlock()
        guard !alreadyFinished else { return }

        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            // Strong capture keeps the session (and its Process) alive until the
            // fallback runs; this closure lives on a queue, not on the session.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        finish(continuation, result: .failure(YabaiClientError.timedOut))
    }

    /// Resumes the continuation exactly once and tears down the handlers so the
    /// session cannot linger after the caller has been resumed.
    private func finish(
        _ continuation: CheckedContinuation<ProcessResult, Error>,
        result: Result<ProcessResult, Error>
    ) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        continuation.resume(with: result)
    }
}
