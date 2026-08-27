import Foundation
import ImageIO
import UniformTypeIdentifiers

/// User-facing concurrency settings.
///
/// - `requestedWorkerCount`: the number shown in the UI and adjusted with the −/+ buttons. It is
///   always the *ceiling* the user asked for, regardless of Auto.
/// - `isAutoEnabled`: when on, the app still targets `requestedWorkerCount` while the machine has
///   capacity but automatically lowers the *effective* number under thermal pressure and raises it
///   back when pressure clears. When off, the requested number is honored as-is except under
///   `.critical` pressure (see `SuperThumbnailConcurrencyPolicy`).
///
/// Changing either value (or the thermal state) while a job is running is applied to the *next*
/// item start only: in-flight items always finish normally, so source media is never left in a
/// half-processed state. See `SuperThumbnailDynamicScheduler`.
struct SuperThumbnailConcurrencySettings: Equatable, Sendable {
    var isAutoEnabled: Bool
    var requestedWorkerCount: Int

    init(isAutoEnabled: Bool, requestedWorkerCount: Int) {
        self.isAutoEnabled = isAutoEnabled
        self.requestedWorkerCount = SuperThumbnailConcurrencyPolicy.clampRequestedWorkerCount(requestedWorkerCount)
    }

    /// Auto on with the processor-derived default requested number.
    static func defaultSettings(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> SuperThumbnailConcurrencySettings {
        SuperThumbnailConcurrencySettings(
            isAutoEnabled: true,
            requestedWorkerCount: SuperThumbnailConcurrencyPolicy.defaultRequestedWorkerCount(
                activeProcessorCount: activeProcessorCount
            )
        )
    }
}

/// Pure policy functions and helpers for concurrency limits and storage/thermal detection.
///
/// Policy contract (file-level, i.e. photo/video items):
/// - No pressure (`.nominal` / `.fair`): effective = requested (Auto on or off).
/// - `.serious`: Auto on → effective = max(1, requested / 2); Auto off → requested (user's choice).
/// - `.critical`: effective = 1 regardless of Auto. Critical pressure is never ignored.
///
/// Folder contract: effective folder limit = max(1, effective file limit / 2), remainder dropped.
/// The same rule applies to NAS/network, removable and local volumes. Because a running worker
/// pool cannot use 0, a requested value of 1 (or 2, or 3) gives a folder limit of 1 — this is the
/// minimum safe effective folder limit (`minimumFolderWorkerLimit`).
enum SuperThumbnailConcurrencyPolicy {
    /// Full user-selectable range of the requested worker number.
    static let supportedWorkerRange: ClosedRange<Int> = 1...16
    /// Effective file limit whenever thermal state is `.critical` (Auto on or off).
    static let criticalThermalWorkerLimit = 1
    /// Lowest possible folder limit; used when half of the file limit would round down to 0.
    static let minimumFolderWorkerLimit = 1

    /// Processor-derived default requested number: one worker per active core, clamped to the
    /// supported range. Auto never keeps the number artificially low — under no pressure the full
    /// requested number is used.
    static func defaultRequestedWorkerCount(
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        clampRequestedWorkerCount(activeProcessorCount)
    }

    static func clampRequestedWorkerCount(_ value: Int) -> Int {
        min(max(value, supportedWorkerRange.lowerBound), supportedWorkerRange.upperBound)
    }

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

    /// Whether the system is under serious or critical thermal pressure.
    static func isThermalThrottled(thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// Whether the given settings/thermal combination actually lowers the effective file limit
    /// below the requested number.
    static func isReducedByThermalPressure(
        settings: SuperThumbnailConcurrencySettings,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        effectiveWorkerLimit(settings: settings, thermalState: thermalState) < settings.requestedWorkerCount
    }

    /// Effective worker limit for item-level (file) processing. See the type documentation for the
    /// exact thermal rules. Always ≥ 1.
    static func effectiveWorkerLimit(
        settings: SuperThumbnailConcurrencySettings,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        let requested = clampRequestedWorkerCount(settings.requestedWorkerCount)
        switch thermalState {
        case .critical:
            return criticalThermalWorkerLimit
        case .serious:
            return settings.isAutoEnabled ? max(1, requested / 2) : requested
        case .nominal, .fair:
            return requested
        @unknown default:
            // Treat unknown future states conservatively, like `.serious`.
            return settings.isAutoEnabled ? max(1, requested / 2) : requested
        }
    }

    /// Effective worker limit for folder processing within a single depth group:
    /// half of the effective file limit with the remainder dropped, never below
    /// `minimumFolderWorkerLimit`. Storage type does not change this value.
    static func effectiveFolderWorkerLimit(
        settings: SuperThumbnailConcurrencySettings,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        folderWorkerLimit(fileWorkerLimit: effectiveWorkerLimit(settings: settings, thermalState: thermalState))
    }

    /// Folder limit derived from a file limit: `max(1, fileWorkerLimit / 2)`.
    static func folderWorkerLimit(fileWorkerLimit: Int) -> Int {
        max(minimumFolderWorkerLimit, fileWorkerLimit / 2)
    }
}

/// Persistence of `SuperThumbnailConcurrencySettings` in `UserDefaults`, including a one-time
/// migration of the legacy `macSuperThumbnail.concurrencyPreference` picker value.
enum SuperThumbnailConcurrencyPersistence {
    static let legacyPreferenceKey = "macSuperThumbnail.concurrencyPreference"
    static let autoEnabledKey = "macSuperThumbnail.concurrencyAutoEnabled"
    static let requestedWorkerCountKey = "macSuperThumbnail.requestedWorkerCount"

    /// Maps a legacy picker raw value to the new settings, preserving the user's intent:
    /// - `"auto"` → Auto on, processor-derived default requested number.
    /// - `"1"`, `"2"`, `"4"`, `"8"` (any integer string) → Auto off, requested = that number (clamped).
    /// - anything else → `nil` (caller falls back to defaults).
    static func migrateLegacyPreference(
        rawValue: String?,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> SuperThumbnailConcurrencySettings? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            return nil
        }
        if rawValue.lowercased() == "auto" {
            return .defaultSettings(activeProcessorCount: activeProcessorCount)
        }
        if let count = Int(rawValue) {
            return SuperThumbnailConcurrencySettings(isAutoEnabled: false, requestedWorkerCount: count)
        }
        return nil
    }

    /// Loads the settings. If the new keys are absent, migrates the legacy key (when present) or
    /// falls back to defaults, writes the result under the new keys and removes the legacy key.
    static func load(
        from defaults: UserDefaults,
        activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> SuperThumbnailConcurrencySettings {
        let hasAuto = defaults.object(forKey: autoEnabledKey) != nil
        let hasRequested = defaults.object(forKey: requestedWorkerCountKey) != nil

        if hasAuto || hasRequested {
            let fallback = SuperThumbnailConcurrencySettings.defaultSettings(activeProcessorCount: activeProcessorCount)
            let settings = SuperThumbnailConcurrencySettings(
                isAutoEnabled: hasAuto ? defaults.bool(forKey: autoEnabledKey) : fallback.isAutoEnabled,
                requestedWorkerCount: hasRequested
                    ? defaults.integer(forKey: requestedWorkerCountKey)
                    : fallback.requestedWorkerCount
            )
            if !hasAuto || !hasRequested {
                save(settings, to: defaults)
            }
            if defaults.object(forKey: legacyPreferenceKey) != nil {
                defaults.removeObject(forKey: legacyPreferenceKey)
            }
            return settings
        }

        let migrated = migrateLegacyPreference(
            rawValue: defaults.string(forKey: legacyPreferenceKey),
            activeProcessorCount: activeProcessorCount
        )
        let settings = migrated ?? .defaultSettings(activeProcessorCount: activeProcessorCount)
        save(settings, to: defaults)
        defaults.removeObject(forKey: legacyPreferenceKey)
        return settings
    }

    static func save(_ settings: SuperThumbnailConcurrencySettings, to defaults: UserDefaults) {
        defaults.set(settings.isAutoEnabled, forKey: autoEnabledKey)
        defaults.set(settings.requestedWorkerCount, forKey: requestedWorkerCountKey)
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
