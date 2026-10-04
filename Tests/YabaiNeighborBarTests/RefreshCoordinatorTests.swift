import XCTest
@testable import YabaiNeighborBar

private actor FetchProbe {
    var calls = 0
    var active = 0
    var maximum = 0
    func fetch() async throws -> Int {
        calls += 1
        active += 1
        maximum = max(maximum, active)
        try await Task.sleep(for: .milliseconds(40))
        active -= 1
        if calls == 1 { throw YabaiClientError.timedOut }
        return calls
    }
    func counts() -> (Int, Int) { (calls, maximum) }
}

@MainActor
final class RefreshCoordinatorTests: XCTestCase {
    func testOverlappingTriggersCoalesceAndRecover() async {
        let probe = FetchProbe()
        let outcomes = expectation(description: "failure then recovery")
        outcomes.expectedFulfillmentCount = 2
        var results: [String] = []
        let coordinator = RefreshCoordinator<Int>(fetch: { try await probe.fetch() }) { result in
            switch result {
            case .success: results.append("success")
            case .failure: results.append("failure")
            }
            outcomes.fulfill()
        }
        coordinator.refresh()
        coordinator.refresh()
        coordinator.refresh()
        await fulfillment(of: [outcomes], timeout: 3)
        XCTAssertEqual(results, ["failure", "success"])
        let (calls, maximum) = await probe.counts()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(maximum, 1)
        coordinator.stop()
    }

    func testStopDiscardsInflightResult() async {
        let probe = FetchProbe()
        let unexpected = expectation(description: "no callback after stop")
        unexpected.isInverted = true
        let coordinator = RefreshCoordinator<Int>(fetch: { try await probe.fetch() }) { _ in
            unexpected.fulfill()
        }
        coordinator.refresh()
        coordinator.stop()
        await fulfillment(of: [unexpected], timeout: 0.15)
    }
}
