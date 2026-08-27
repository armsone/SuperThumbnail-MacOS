import Foundation

/// UI state for the media discovery that runs after any vault cleanup and
/// before thumbnail generation. Neither pass has a known total, so both
/// render as indeterminate; the phase only tells the user which kind of
/// entry (media files, then folders) is currently being enumerated.
enum MediaDiscoveryPhase: Equatable, Sendable {
    case idle
    case discoveringFiles
    case discoveringFolders

    var isActive: Bool { self != .idle }

    /// Large card title shown for every active phase.
    static let titleText = "사진과 영상을 찾는 중"

    var activityText: String {
        switch self {
        case .idle:
            return ""
        case .discoveringFiles:
            return "사진과 영상 파일을 찾는 중…"
        case .discoveringFolders:
            return "하위 폴더를 찾는 중…"
        }
    }

    var accessibilityLabelText: String { Self.titleText }

    var accessibilityValueText: String {
        switch self {
        case .idle:
            return ""
        case .discoveringFiles:
            return "사진과 영상 파일을 찾는 중"
        case .discoveringFolders:
            return "하위 폴더를 찾는 중"
        }
    }

    /// Accessibility value that also reads out the live tallies, e.g.
    /// "하위 폴더를 찾는 중, 폴더 12개, 파일 340개 발견".
    func accessibilityValueText(with counts: MediaDiscoveryCounts) -> String {
        guard isActive else { return "" }
        return "\(accessibilityValueText), \(counts.accessibilityText)"
    }
}

/// Live tallies reported while discovery walks the selected tree. The file
/// pass counts eligible media files and every folder it passes through; the
/// folder pass re-confirms the folder count. Both passes use the same folder
/// eligibility (inside the root, not a vault, not hidden, not a symlink).
struct MediaDiscoveryCounts: Equatable, Sendable {
    var folderCount = 0
    var fileCount = 0

    static let zero = MediaDiscoveryCounts()

    /// Short label rendered beside the activity text, e.g. "폴더 12개 · 파일 340개".
    var countText: String {
        "폴더 \(folderCount.formatted())개 · 파일 \(fileCount.formatted())개"
    }

    var accessibilityText: String {
        "폴더 \(folderCount)개, 파일 \(fileCount)개 발견"
    }

    /// Per-field maximum. Reports are delivered to the main actor as separate
    /// tasks, so merging with `max` keeps the display monotonic even if two
    /// reports are applied out of order, and lets the folder pass (which
    /// reports `fileCount == 0`) leave the file total from the previous pass
    /// untouched.
    func merging(_ other: MediaDiscoveryCounts) -> MediaDiscoveryCounts {
        MediaDiscoveryCounts(
            folderCount: max(folderCount, other.folderCount),
            fileCount: max(fileCount, other.fileCount)
        )
    }
}

typealias MediaDiscoveryProgressHandler = @Sendable (MediaDiscoveryCounts) -> Void

/// Rate-limits progress callbacks from the enumeration thread so a large NAS
/// tree does not schedule one main-actor hop per directory entry. The first
/// change is always delivered so the UI moves immediately; later changes are
/// coalesced to at most one per `minimumInterval`; a `force`d report (used
/// for the final tally) bypasses the interval but still skips exact repeats.
struct MediaDiscoveryProgressThrottle {
    let minimumInterval: TimeInterval
    private var lastReportedAt: TimeInterval?
    private var lastReported: MediaDiscoveryCounts?

    init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldReport(
        _ counts: MediaDiscoveryCounts,
        at now: TimeInterval,
        force: Bool = false
    ) -> Bool {
        if counts == lastReported { return false }
        if !force, let lastReportedAt, now - lastReportedAt < minimumInterval { return false }
        lastReportedAt = now
        lastReported = counts
        return true
    }

    /// Convenience used by the discovery loops: reports through `handler`
    /// when the throttle allows it. No-op when there is no handler.
    mutating func report(
        _ counts: MediaDiscoveryCounts,
        force: Bool = false,
        to handler: MediaDiscoveryProgressHandler?
    ) {
        guard let handler else { return }
        if shouldReport(counts, at: Date().timeIntervalSinceReferenceDate, force: force) {
            handler(counts)
        }
    }
}
