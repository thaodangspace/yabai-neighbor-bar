import Foundation

/// Schedules snapshots without overlapping requests. A pending trigger is coalesced
/// into one additional fetch when the in-flight fetch finishes.
@MainActor
final class RefreshCoordinator<Snapshot: Sendable> {
    private let fetch: @Sendable () async throws -> Snapshot
    private let receive: @MainActor (Result<Snapshot, Error>) -> Void
    private var inFlight = false
    private var pending = false
    private var stopped = false

    init(fetch: @escaping @Sendable () async throws -> Snapshot,
         receive: @escaping @MainActor (Result<Snapshot, Error>) -> Void) {
        self.fetch = fetch
        self.receive = receive
    }

    func refresh() {
        guard !stopped else { return }
        if inFlight { pending = true; return }
        inFlight = true
        Task { [weak self, fetch] in
            let result: Result<Snapshot, Error>
            do { result = .success(try await fetch()) }
            catch { result = .failure(error) }
            guard let self, !self.stopped else { return }
            self.receive(result)
            self.inFlight = false
            if self.pending {
                self.pending = false
                self.refresh()
            }
        }
    }

    func stop() {
        stopped = true
        pending = false
    }
}
