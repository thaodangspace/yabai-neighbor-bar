import AppKit
import XCTest
@testable import YabaiNeighborBar

/// Records lookups and returns canned running-application info.
@MainActor
private final class StubRunningApplications: RunningApplicationProviding {
    var applications: [pid_t: RunningApplicationIcon] = [:]
    private(set) var requestedPIDs: [pid_t] = []

    func runningApplication(pid: pid_t) -> RunningApplicationIcon? {
        requestedPIDs.append(pid)
        return applications[pid]
    }
}

@MainActor
final class IconResolverTests: XCTestCase {

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }

    // MARK: - Caching

    func testResolvesAndCachesSuccessfulLookup() {
        let provider = StubRunningApplications()
        let appIcon = makeImage()
        provider.applications[42] = RunningApplicationIcon(bundleIdentifier: "com.example.a", icon: appIcon)
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        let first = resolver.icon(forPID: 42)
        XCTAssertFalse(first.isFallback)
        XCTAssertTrue(first.image === appIcon)

        // Same PID, same bundle, but AppKit would now hand back a different
        // NSImage: the cache must keep serving the already-resolved icon instead
        // of re-reading it for every window of the app.
        provider.applications[42] = RunningApplicationIcon(bundleIdentifier: "com.example.a", icon: makeImage())
        let second = resolver.icon(forPID: 42)
        XCTAssertFalse(second.isFallback)
        XCTAssertTrue(second.image === appIcon)
        XCTAssertEqual(resolver.cachedProcessCount, 1)
    }

    func testProcessLivenessIsProbedPerResolve() {
        let provider = StubRunningApplications()
        provider.applications[42] = RunningApplicationIcon(bundleIdentifier: "com.example.a", icon: makeImage())
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        _ = resolver.icon(forPID: 42)
        _ = resolver.icon(forPID: 42)

        // Each resolve re-checks the process so a dead PID cannot be masked by
        // the cache; only the expensive icon load is cached.
        XCTAssertEqual(provider.requestedPIDs, [42, 42])
    }

    func testDistinctPIDsAreResolvedIndependently() {
        let provider = StubRunningApplications()
        let iconA = makeImage()
        let iconB = makeImage()
        provider.applications[1] = RunningApplicationIcon(bundleIdentifier: "a", icon: iconA)
        provider.applications[2] = RunningApplicationIcon(bundleIdentifier: "b", icon: iconB)
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        XCTAssertTrue(resolver.icon(forPID: 1).image === iconA)
        XCTAssertTrue(resolver.icon(forPID: 2).image === iconB)
        XCTAssertEqual(resolver.cachedProcessCount, 2)
    }

    // MARK: - Invalidation

    func testVanishedProcessInvalidatesCacheAndUsesFallback() {
        let provider = StubRunningApplications()
        let appIcon = makeImage()
        provider.applications[42] = RunningApplicationIcon(bundleIdentifier: "com.example.a", icon: appIcon)
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        _ = resolver.icon(forPID: 42)
        XCTAssertEqual(resolver.cachedProcessCount, 1)

        provider.applications[42] = nil

        let fallback = resolver.icon(forPID: 42)
        XCTAssertTrue(fallback.isFallback)
        XCTAssertEqual(resolver.cachedProcessCount, 0)
        XCTAssertEqual(provider.requestedPIDs, [42, 42])
    }

    func testPIDReuseWithDifferentBundleResolvesNewIcon() {
        let provider = StubRunningApplications()
        let oldIcon = makeImage()
        let newIcon = makeImage()
        provider.applications[7] = RunningApplicationIcon(bundleIdentifier: "com.example.old", icon: oldIcon)
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        XCTAssertTrue(resolver.icon(forPID: 7).image === oldIcon)

        // Same PID recycled by another app: the stale entry must not be reused.
        provider.applications[7] = RunningApplicationIcon(bundleIdentifier: "com.example.new", icon: newIcon)
        let reused = resolver.icon(forPID: 7)
        XCTAssertFalse(reused.isFallback)
        XCTAssertTrue(reused.image === newIcon)
        XCTAssertEqual(provider.requestedPIDs, [7, 7])
    }

    func testExplicitInvalidateForcesRefetch() {
        let provider = StubRunningApplications()
        provider.applications[9] = RunningApplicationIcon(bundleIdentifier: "x", icon: makeImage())
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        _ = resolver.icon(forPID: 9)
        resolver.invalidate(pid: 9)
        XCTAssertEqual(resolver.cachedProcessCount, 0)
        _ = resolver.icon(forPID: 9)
        XCTAssertEqual(provider.requestedPIDs, [9, 9])
    }

    // MARK: - Fallback

    func testMissingProcessReturnsFallbackWithoutCaching() {
        let provider = StubRunningApplications()
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        XCTAssertTrue(resolver.icon(forPID: 99).isFallback)
        XCTAssertTrue(resolver.icon(forPID: 99).isFallback)
        XCTAssertEqual(resolver.cachedProcessCount, 0)
    }

    func testRunningAppWithoutIconStaysFallbackWhenCached() {
        let provider = StubRunningApplications()
        provider.applications[7] = RunningApplicationIcon(bundleIdentifier: "x", icon: nil)
        let resolver = IconResolver(provider: provider, makeFallback: makeImage)

        XCTAssertTrue(resolver.icon(forPID: 7).isFallback)
        // A cached fallback must not be reported as a real icon on the next window.
        XCTAssertTrue(resolver.icon(forPID: 7).isFallback)
        XCTAssertEqual(resolver.cachedProcessCount, 1)
    }

    func testSystemFallbackImageIsNonEmpty() {
        let image = IconResolver.systemFallbackImage()
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
