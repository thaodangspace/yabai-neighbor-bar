import AppKit

/// A resolved icon together with whether it is the fallback rather than the app's
/// real icon. The flag is carried through so the UI can distinguish a genuine icon
/// from a placeholder without dropping the window.
struct ResolvedIcon: Equatable {
    let image: NSImage
    let isFallback: Bool
}

/// Minimal view of a running application needed to pick a window icon.
struct RunningApplicationIcon {
    let bundleIdentifier: String?
    let icon: NSImage?
}

/// Injectable application lookup so PID cache behavior is testable without
/// spawning real processes. Always used from the main actor.
@MainActor
protocol RunningApplicationProviding {
    func runningApplication(pid: pid_t) -> RunningApplicationIcon?
}

/// Production lookup backed by `NSRunningApplication`.
struct SystemRunningApplications: RunningApplicationProviding {
    func runningApplication(pid: pid_t) -> RunningApplicationIcon? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }
        return RunningApplicationIcon(bundleIdentifier: app.bundleIdentifier, icon: app.icon)
    }
}

/// Resolves per-PID app icons.
///
/// Successful lookups are cached by PID so several windows of one app load the
/// (expensive) `NSRunningApplication.icon` only once. Each resolve still probes
/// process liveness; a cache entry is invalidated when the process disappears (or
/// never existed) or when the PID is reused by a different bundle identifier, in
/// which case a fresh resolution (or the per-window fallback) is returned instead
/// of a stale icon.
@MainActor
final class IconResolver {
    private struct Entry {
        let bundleIdentifier: String?
        let image: NSImage
        let isFallback: Bool
    }

    nonisolated static let fallbackSymbolNames = ["app.dashed", "app", "questionmark.square.dashed"]

    private var cache: [pid_t: Entry] = [:]
    private let provider: any RunningApplicationProviding
    private let makeFallback: () -> NSImage

    init(
        provider: any RunningApplicationProviding = SystemRunningApplications(),
        makeFallback: @escaping () -> NSImage = IconResolver.systemFallbackImage
    ) {
        self.provider = provider
        self.makeFallback = makeFallback
    }

    func icon(forPID pid: pid_t) -> ResolvedIcon {
        guard let running = provider.runningApplication(pid: pid) else {
            // The process is gone (or never existed): never reuse a stale entry.
            cache.removeValue(forKey: pid)
            return ResolvedIcon(image: makeFallback(), isFallback: true)
        }
        if let cached = cache[pid], cached.bundleIdentifier == running.bundleIdentifier {
            return ResolvedIcon(image: cached.image, isFallback: cached.isFallback)
        }
        // First sight, PID reuse, or a bundle change: resolve and cache.
        let entry = Entry(
            bundleIdentifier: running.bundleIdentifier,
            image: running.icon ?? makeFallback(),
            isFallback: running.icon == nil
        )
        cache[pid] = entry
        return ResolvedIcon(image: entry.image, isFallback: entry.isFallback)
    }

    /// Drops the cached entry for one PID (e.g. when its last window disappears).
    func invalidate(pid: pid_t) {
        cache.removeValue(forKey: pid)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    /// Number of live process entries; used by tests to assert invalidation.
    var cachedProcessCount: Int { cache.count }

    /// A template system symbol used when no app icon can be resolved.
    nonisolated static func systemFallbackImage() -> NSImage {
        for name in fallbackSymbolNames {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: "Window") {
                image.isTemplate = true
                return image
            }
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }
}
