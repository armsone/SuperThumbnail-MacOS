import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Concurrency preference selectable by the user.
/// - auto: Conservative limit based on storage type (network/removable: 2, local fixed: 4) and thermal state.
/// - explicit (1, 2, 4, 8): Fixed upper bound, dynamically clamped to 1 under serious/critical thermal pressure.
///
/// Changing the preference (or the thermal state) while a job is running is applied to the
/// *next* item start only: in-flight items always finish normally, so source media is never
/// left in a half-processed state. See `SuperThumbnailDynamicScheduler`.
enum SuperThumbnailWorkerPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "auto"
    case one = "1"
    case two = "2"
    case four = "4"
    case eight = "8"

    var id: String { rawValue }

    var explicitCount: Int? {
        switch self {
        case .auto: return nil
        case .one: return 1
        case .two: return 2
        case .four: return 4
        case .eight: return 8
        }
    }

    var displayName: String {
        switch self {
        case .auto:
            return "자동"
        case .one:
            return "1개"
        case .two:
            return "2개"
        case .four:
            return "4개"
        case .eight:
            return "8개"
        }
    }

    var menuTitle: String {
        switch self {
        case .auto:
            return "자동 (저장소 및 발열에 맞춤)"
        case .one:
            return "1개 (순차 처리)"
        case .two:
            return "2개 작업자"
        case .four:
            return "4개 작업자"
        case .eight:
            return "8개 작업자"
        }
    }
}

/// Pure policy functions and helpers for concurrency limits and storage/thermal detection.
enum SuperThumbnailConcurrencyPolicy {
    static let autoLocalWorkerLimit = 4
    static let autoRemoteOrRemovableWorkerLimit = 2
    static let maxFolderWorkers = 2
    static let thermalThrottledWorkerLimit = 1

    /// Detects if a URL is on a network volume or removable storage.
    static func isNetworkOrRemovable(url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        guard let values = try? canonical.resourceValues(forKeys: keys) else {
            return true // Conservative fallback
        }
        if values.volumeIsLocal == false || values.volumeIsRemovable == true {
            return true
        }
        return false
    }

    /// Base worker count before thermal pressure is applied.
    static func baseWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool
    ) -> Int {
        switch preference {
        case .auto:
            return isNetworkOrRemovable ? autoRemoteOrRemovableWorkerLimit : autoLocalWorkerLimit
        case .one:
            return 1
        case .two:
            return 2
        case .four:
            return 4
        case .eight:
            return 8
        }
    }

    /// Whether the system is under serious or critical thermal pressure.
    static func isThermalThrottled(thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// Effective worker limit for item-level processing.
    /// Clamps to 1 if thermal state is serious or critical.
    static func effectiveWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        if isThermalThrottled(thermalState: thermalState) {
            return thermalThrottledWorkerLimit
        }
        let base = baseWorkerLimit(preference: preference, isNetworkOrRemovable: isNetworkOrRemovable)
        return max(1, base)
    }

    /// Effective worker limit for folder processing within a single depth group.
    /// Deepest depth first; within one depth allows bounded concurrency capped at 2.
    /// Clamped to 1 under thermal pressure.
    static func effectiveFolderWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        let itemLimit = effectiveWorkerLimit(
            preference: preference,
            isNetworkOrRemovable: isNetworkOrRemovable,
            thermalState: thermalState
        )
        return min(itemLimit, maxFolderWorkers)
    }
}

/// Main-actor wake-up signal used by `SuperThumbnailDynamicScheduler`.
///
/// Whenever an input of the effective worker limit changes (user preference, thermal state),
/// call `notifyChanged()`. A scheduler that is blocked waiting for an in-flight item to finish
/// is woken up so it can start additional queued items immediately when the limit went up.
@MainActor
final class SuperThumbnailWorkerLimitSignal {
    /// Monotonic counter incremented on every `notifyChanged()`.
    private(set) var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func notifyChanged() {
        generation &+= 1
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }

    /// Suspends until `notifyChanged()` is called after `generation`, or until the current task
    /// is cancelled. Returns immediately if a change already happened since `generation`.
    func waitForChange(after generation: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if self.generation != generation || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.resumeWaiter(id)
            }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// Event produced inside the scheduler's task group.
enum SuperThumbnailSchedulerEvent<Outcome: Sendable>: Sendable {
    case outcome(Outcome)
    case limitChanged
}

/// Bounded-concurrency scheduler whose limit is re-read before every item start.
///
/// Contract:
/// - `limit()` is evaluated on the main actor right before each start. Lowering it never cancels
///   in-flight work; it only stops additional starts until enough items finish.
/// - Raising it (followed by `signal.notifyChanged()`) wakes the loop while it is waiting for
///   outcomes, so queued items are started immediately instead of after the next completion.
/// - Items are started in array order; outcomes are delivered as they complete.
/// - Task cancellation stops new starts and cancels the group; already-delivered outcomes stay applied.
/// - While `isPaused()` is true, no new items are started and outcomes are held (matching the
///   previous pause semantics).
@MainActor
enum SuperThumbnailDynamicScheduler {
    static func run<Item: Sendable, Outcome: Sendable>(
        items: [Item],
        signal: SuperThumbnailWorkerLimitSignal,
        limit: @MainActor () -> Int,
        isPaused: @MainActor () -> Bool,
        onInFlightChange: @MainActor (Int) -> Void = { _ in },
        work: @escaping @Sendable (Item) async -> Outcome,
        onOutcome: @MainActor (Outcome) -> Void
    ) async {
        guard !items.isEmpty else { return }

        await withTaskGroup(of: SuperThumbnailSchedulerEvent<Outcome>.self) { group in
            var nextIndex = 0
            var inFlight = 0
            var isWatching = false

            while true {
                // Start as many queued items as the *current* limit allows.
                if !Task.isCancelled && !isPaused() {
                    let currentLimit = max(1, limit())
                    while nextIndex < items.count && inFlight < currentLimit {
                        let item = items[nextIndex]
                        nextIndex += 1
                        inFlight += 1
                        group.addTask {
                            let outcome = await work(item)
                            return .outcome(outcome)
                        }
                        onInFlightChange(inFlight)
                    }
                }

                // Keep exactly one watcher alive while there is still queued work so a raised
                // limit can be applied without waiting for the next completion.
                if nextIndex < items.count && !isWatching && !Task.isCancelled {
                    let generation = signal.generation
                    isWatching = true
                    group.addTask {
                        await signal.waitForChange(after: generation)
                        return .limitChanged
                    }
                }

                guard inFlight > 0 else {
                    if nextIndex < items.count && !Task.isCancelled {
                        // Paused before anything could start: wait for resume, then retry.
                        while isPaused() && !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                        continue
                    }
                    break
                }
                guard let event = await group.next() else { break }

                switch event {
                case .limitChanged:
                    isWatching = false

                case .outcome(let outcome):
                    inFlight -= 1
                    onInFlightChange(inFlight)

                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }

                    onOutcome(outcome)

                    while isPaused() && !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                    }

                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }
                }
            }

            // Only a watcher can still be pending here (inFlight == 0); release it.
            group.cancelAll()
        }
    }
}

/// Helper for partitioning folder entries by depth into deepest-first batches.
enum FolderDepthGrouping {
    /// Groups folders by depth descending (deepest depth first).
    /// Folders within the same depth are sorted by localized path for determinism.
    static func groupDeepestFirst(folders: [FolderEntry]) -> [[FolderEntry]] {
        let grouped = Dictionary(grouping: folders, by: \.depth)
        let sortedDepths = grouped.keys.sorted(by: >)
        return sortedDepths.map { depth in
            (grouped[depth] ?? []).sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        }
    }
}

/// Result of processing a single media file in bounded concurrency.
struct MediaFileProcessingOutcome: Sendable {
    let file: MediaFile
    let result: Result<ProcessingResult, Error>
    let previewItem: SuperThumbnailMacPreviewItem?
}

/// Result of processing a single folder in bounded concurrency.
struct FolderProcessingOutcome: Sendable {
    let folder: FolderEntry
    let result: Result<FolderProcessingResult, Error>
    let previewItem: SuperThumbnailMacPreviewItem?
}

extension VaultProcessor {
    /// Processes a single media file asynchronously and gathers result and preview item.
    static func processMediaItem(
        _ file: MediaFile,
        workerID: String
    ) async -> MediaFileProcessingOutcome {
        do {
            let result = try await process(file, workerID: workerID)
            var preview: SuperThumbnailMacPreviewItem? = nil
            let vault = file.url.deletingLastPathComponent()
                .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
            if let filename = try? NasFinderVaultCompatibility.thumbnailFilename(for: file.url) {
                let thumbnailURL = vault.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    preview = SuperThumbnailMacPreviewItem(
                        id: SuperThumbnailPreviewOrdering.canonicalID(for: thumbnailURL),
                        name: file.url.lastPathComponent,
                        isFolder: false,
                        vaultFileURL: thumbnailURL
                    )
                }
            }
            return MediaFileProcessingOutcome(
                file: file,
                result: .success(result),
                previewItem: preview
            )
        } catch is CancellationError {
            return MediaFileProcessingOutcome(
                file: file,
                result: .failure(CancellationError()),
                previewItem: nil
            )
        } catch {
            return MediaFileProcessingOutcome(
                file: file,
                result: .failure(error),
                previewItem: nil
            )
        }
    }

    /// Processes a single folder asynchronously and gathers result and preview item.
    static func processFolderItem(
        _ folder: FolderEntry,
        workerID: String,
        tileCache: FolderSheetTileCache
    ) async -> FolderProcessingOutcome {
        do {
            let result = try await Task.detached(priority: .utility) {
                try VaultProcessor.processFolder(
                    folder,
                    workerID: workerID,
                    tileCache: tileCache
                )
            }.value

            var preview: SuperThumbnailMacPreviewItem? = nil
            if result.state == .generated {
                let parentVault = folder.url.deletingLastPathComponent()
                    .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
                let sheetURL = parentVault.appendingPathComponent(
                    NasFinderVaultCompatibility.folderThumbnailFilename(folderName: folder.url.lastPathComponent)
                )
                if fileManager.fileExists(atPath: sheetURL.path) {
                    preview = SuperThumbnailMacPreviewItem(
                        id: SuperThumbnailPreviewOrdering.canonicalID(for: sheetURL),
                        name: folder.url.lastPathComponent,
                        isFolder: true,
                        vaultFileURL: sheetURL
                    )
                }
            }
            return FolderProcessingOutcome(
                folder: folder,
                result: .success(result),
                previewItem: preview
            )
        } catch is CancellationError {
            return FolderProcessingOutcome(
                folder: folder,
                result: .failure(CancellationError()),
                previewItem: nil
            )
        } catch {
            return FolderProcessingOutcome(
                folder: folder,
                result: .failure(error),
                previewItem: nil
            )
        }
    }
}
