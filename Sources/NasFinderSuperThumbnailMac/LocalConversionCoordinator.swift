import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Local Conversion Stage

enum LocalConversionStage: Equatable, Sendable {
    case pending
    case preparing
    case copyingSource
    case converting
    case verifying
    case staging
    case publishing
    case completed
    case failed(String)
    case cancelled
    case skipped(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skipped:
            return true
        case .pending, .preparing, .copyingSource, .converting, .verifying, .staging, .publishing:
            return false
        }
    }

    var isRunning: Bool {
        switch self {
        case .preparing, .copyingSource, .converting, .verifying, .staging, .publishing:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .pending: return "대기 중"
        case .preparing: return "준비 중"
        case .copyingSource: return "원본 임시 복사 중"
        case .converting: return "엔진 변환 중"
        case .verifying: return "결과 검증 중"
        case .staging: return "완료본 발행 중"
        case .publishing: return "썸네일 생성 및 원본 정리 중"
        case .completed: return "완료"
        case .failed(let err): return "실패: \(err)"
        case .cancelled: return "취소됨"
        case .skipped(let reason): return "건너뜀: \(reason)"
        }
    }
}

// MARK: - Local Conversion Item

struct LocalConversionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let folderID: UUID
    let sourceURL: URL
    let relativePath: String
    let relativeComponents: [String]
    let fileSize: Int64
    let identity: LocalFileIdentity
    var stage: LocalConversionStage
    var fraction: Double?
    var phaseLabel: String?
    var statusMessage: String
    var engineRef: String?
    let addedDate: Date

    init(
        id: UUID = UUID(),
        folderID: UUID,
        sourceURL: URL,
        relativePath: String,
        relativeComponents: [String],
        fileSize: Int64,
        identity: LocalFileIdentity,
        stage: LocalConversionStage = .pending,
        fraction: Double? = nil,
        phaseLabel: String? = nil,
        statusMessage: String = "대기 중",
        engineRef: String? = nil,
        addedDate: Date = Date()
    ) {
        self.id = id
        self.folderID = folderID
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.relativeComponents = relativeComponents
        self.fileSize = fileSize
        self.identity = identity
        self.stage = stage
        self.fraction = fraction
        self.phaseLabel = phaseLabel
        self.statusMessage = statusMessage
        self.engineRef = engineRef
        self.addedDate = addedDate
    }

    var fileName: String {
        sourceURL.lastPathComponent
    }
}

// MARK: - Truthful Cumulative Counters & Summary

struct LocalConversionCounters: Equatable, Sendable {
    var discoveredCount: Int = 0
    var completedCount: Int = 0
    var failedCount: Int = 0
    var skippedCount: Int = 0
    var inProgressCount: Int = 0

    var handledCount: Int {
        completedCount + failedCount + skippedCount
    }
}

struct LocalConversionQueueSummary: Equatable, Sendable {
    var pendingCount: Int
    var runningCount: Int
    var pausedCount: Int
    var completedCount: Int
    var failedCount: Int
    var cancelledCount: Int
    var skippedCount: Int
    var totalCount: Int

    static let empty = LocalConversionQueueSummary(
        pendingCount: 0,
        runningCount: 0,
        pausedCount: 0,
        completedCount: 0,
        failedCount: 0,
        cancelledCount: 0,
        skippedCount: 0,
        totalCount: 0
    )

    var progressFraction: Double {
        totalCount > 0 ? Double(completedCount + skippedCount) / Double(totalCount) : 0.0
    }
}

// MARK: - Per-Attempt Immutable Context & Worker

struct LocalAttemptContext: Sendable {
    let itemID: UUID
    let folderID: UUID
    let sourceURL: URL
    let relativePath: String
    let relativeComponents: [String]
    let fileSize: Int64
    let expectedIdentity: LocalFileIdentity
    let attemptID: String
    let engineRef: String
}

enum LocalWorkerResult: Sendable {
    case completed(message: String)
    case failed(message: String)
    case skipped(message: String)
    case cancelled
}

enum LocalConversionWorker {
    /// Nonisolated background worker performing heavy file I/O, hashing, engine execution,
    /// and atomic descriptor-relative publication strictly off the MainActor.
    nonisolated static func performConversion(
        context: LocalAttemptContext,
        pinnedRoot: NASPinnedRoot,
        engineBridge: DefaultNASConversionEngineBridge,
        downloadLimiter: NASResourceLimiter,
        encodeLimiter: NASResourceLimiter,
        onProgress: @Sendable @escaping (Double?, String?) -> Void,
        onStageChange: @Sendable @escaping (LocalConversionStage, String) -> Void
    ) async -> LocalWorkerResult {
        let itemID = context.itemID
        let sourceURL = context.sourceURL
        let fileSize = context.fileSize
        let attemptID = context.attemptID
        let engineRef = context.engineRef

        // 1. Conservative disk capacity check (at least 2x source size + 500MB headroom)
        let requiredSpace = fileSize * 2 + 500_000_000
        if let available = LocalVolumeDetector.availableCapacityBytes(for: sourceURL), available < requiredSpace {
            let msg = "디스크 여유 공간 부족 (필요: \(requiredSpace / 1024 / 1024)MB, 사용 가능: \(available / 1024 / 1024)MB)"
            return .failed(message: msg)
        }
        // Download/encode cache lives in the local temporary directory regardless of remote quota reporting.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if let localAvailable = LocalVolumeDetector.availableCapacityBytes(for: tempURL), localAvailable < requiredSpace {
            let msg = "Mac 임시 공간 부족 (필요: \(requiredSpace / 1024 / 1024)MB, 사용 가능: \(localAvailable / 1024 / 1024)MB)"
            return .failed(message: msg)
        }

        // 2. Open parent directory chain and source file descriptor-relative to pinnedRoot
        let parentComponents = Array(context.relativeComponents.dropLast())
        guard let fileName = context.relativeComponents.last else {
            return .failed(message: "유효하지 않은 파일 경로입니다.")
        }

        let lock: LocalFileLock
        do {
            lock = try pinnedRoot.withDirectoryFD { rootFD in
                let parentFD = try NASPinnedFS.openDirectoryChain(rootFD, parentComponents, create: false)

                // B3: Check actual opened parentFD belongs to verified root filesystem
                var rootStat = stat()
                var parentStat = stat()
                guard fstat(rootFD, &rootStat) == 0,
                      fstat(parentFD, &parentStat) == 0,
                      parentStat.st_dev == rootStat.st_dev else {
                    Darwin.close(parentFD)
                    throw NSError(domain: "LocalConversionError", code: 41, userInfo: [NSLocalizedDescriptionKey: "상위 디렉터리가 검증된 루트 파일시스템과 일치하지 않습니다 (하위 마운트 또는 stat 실패)."])
                }

                let fd = openat(parentFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    let err = errno
                    Darwin.close(parentFD)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "파일 열기 실패 (errno \(err)): \(fileName)"])
                }
                return try LocalFileLockManager.shared.acquireLock(
                    parentFD: parentFD,
                    fd: fd,
                    fileName: fileName,
                    relativeComponents: context.relativeComponents
                )
            }
        } catch {
            return .skipped(message: "잠금 획득 불가: \(error.localizedDescription)")
        }
        defer { lock.unlock() }

        // Verify initial identity matches discovered identity
        guard lock.identity == context.expectedIdentity else {
            return .skipped(message: "파일 식별 정보가 변경되었습니다.")
        }

        let stem = (fileName as NSString).deletingPathExtension
        let originalExt = (fileName as NSString).pathExtension
        let engineExt = originalExt.lowercased()
        // `_원본` name is only the shared claim identity / conflict marker; the Mac flow never creates it.
        let backupFileName = "\(stem)\(LocalConversionConstants.backupSuffix).\(originalExt)"
        let finalFileName = "\(stem).\(LocalConversionConstants.finalExtension)"

        // 3. Acquire active-only per-output shared video claim
        let claim: VideoConversionClaim
        do {
            claim = try VideoConversionClaim.acquire(
                parentFD: lock.parentFD,
                sourceName: fileName,
                outputName: finalFileName,
                backupName: backupFileName,
                sourceIdentity: lock.identity
            )
        } catch {
            return .skipped(message: "클레임 획득 불가: \(error.localizedDescription)")
        }

        var conversionSucceeded = false
        defer {
            _ = claim.release(success: conversionSucceeded)
        }

        // 4. Prepare private owned workspace root with OS canonical realpath
        let canonicalTempURL: URL
        do {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            canonicalTempURL = try NASPathSecurity.realpathURL(of: tempURL)
        } catch {
            return .failed(message: "임시 디렉토리 정규화 실패: \(error.localizedDescription)")
        }

        let workspaceURL = canonicalTempURL.appendingPathComponent("SuperThumbnail-Local-\(attemptID)", isDirectory: true)

        do {
            try NASPathSecurity.prepareOwnedWorkspaceRoot(at: workspaceURL)
        } catch {
            return .failed(message: "작업공간 준비 실패: \(error.localizedDescription)")
        }

        // Retained only if the original's deletion outcome is uncertain: the workspace then holds the
        // hash-verified copy of the original.
        var shouldRetainWorkspaceEvidence = false
        // True once the final MP4 is published: from then on cancel/error must keep the valid MP4 and original.
        var outputPublished = false
        defer {
            if !shouldRetainWorkspaceEvidence {
                try? FileManager.default.removeItem(at: workspaceURL)
            }
        }

        do {
            try Task.checkCancellation()

            // 5. Copy source media into private workspace from the SAME locked descriptor
            let sourceRelative = "sources/source.\(engineExt)"
            let sourceDestURL = workspaceURL.appendingPathComponent(sourceRelative)
            let sourcesDir = sourceDestURL.deletingLastPathComponent()

            try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

            let sourceFD = lock.fd
            let expectedIdentity = lock.identity
            let (sourceSha256, copiedBytes) = try await downloadLimiter.withPermit { () -> (String, Int64) in
                onStageChange(.copyingSource, "원본 임시 복사 중")

                let dupSourceFD = dup(sourceFD)
                guard dupSourceFD >= 0 else {
                    let err = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "원본 디스크립터 복제 실패 (errno \(err))"])
                }
                let sourceHandle = FileHandle(fileDescriptor: dupSourceFD, closeOnDealloc: true)
                _ = lseek(dupSourceFD, 0, SEEK_SET)

                FileManager.default.createFile(atPath: sourceDestURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let destHandle = try FileHandle(forWritingTo: sourceDestURL)
                defer { try? destHandle.close() }

                var hasher = SHA256()
                var copied: Int64 = 0
                var lastReportedPercent = -1
                onProgress(0, "다운로드 중")
                while true {
                    try Task.checkCancellation()
                    let chunk = try sourceHandle.read(upToCount: 512 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                    copied += Int64(chunk.count)
                    destHandle.write(chunk)
                    if fileSize > 0 {
                        // Cap at 0.99 until the copy size and source identity are verified.
                        let fraction = min(0.99, Double(copied) / Double(fileSize))
                        let percent = Int(fraction * 100)
                        if percent != lastReportedPercent {
                            lastReportedPercent = percent
                            onProgress(fraction, "다운로드 중")
                        }
                    }
                }
                try destHandle.synchronize()

                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: sourceDestURL.path)

                let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()

                // Verify identity unchanged during copy
                let postCopyIdentity = try LocalFileIdentity.inspect(fd: sourceFD)
                guard postCopyIdentity == expectedIdentity, copied == fileSize else {
                    throw NSError(domain: "LocalConversionError", code: 30, userInfo: [NSLocalizedDescriptionKey: "복사 전후 원본 파일 식별 정보 불일치"])
                }

                onProgress(1, "다운로드 완료 · 인코딩 대기")
                return (sha, copied)
            }
            claim.updatePhase("copyingSource")

            // 6. Invoke ConversionEngine via engineBridge.encodeLocal
            claim.updatePhase("converting")

            let environment = NASToolEnvironment.detect()
            guard environment.isReadyToExecute else {
                throw NSError(domain: "LocalConversionError", code: 31, userInfo: [NSLocalizedDescriptionKey: environment.diagnosticMessage])
            }

            let outputRelative = "out/output.mp4"
            let engineResult = try await encodeLimiter.withPermit { () -> NASEngineResultLine in
                onStageChange(.converting, "번들 엔진 변환 중")
                return try await engineBridge.encodeLocal(
                    environment: environment,
                    workspaceRoot: workspaceURL,
                    jobID: attemptID,
                    ref: engineRef,
                    sourceLocalRelativePath: sourceRelative,
                    sourceExt: ".\(engineExt)",
                    sourceExpectedSize: copiedBytes,
                    sourceExpectedSha256: sourceSha256,
                    outputRelativePath: outputRelative,
                    onProgress: { prog in
                        let pct = prog.phase_pct
                        let label = prog.phase_label ?? prog.phase
                        onProgress(pct.map { $0 / 100.0 }, label)
                    }
                )
            }

            guard engineResult.status == "ok", let outputSummary = engineResult.output else {
                throw NSError(domain: "LocalConversionError", code: 32, userInfo: [NSLocalizedDescriptionKey: "엔진 인코딩 실패 (\(engineResult.code)): \(engineResult.message)"])
            }

            // 7. Output validation
            onStageChange(.verifying, "결과 검증 중")
            claim.updatePhase("verifying")

            let localMP4URL = workspaceURL.appendingPathComponent(outputRelative)
            guard FileManager.default.fileExists(atPath: localMP4URL.path) else {
                throw NSError(domain: "LocalConversionError", code: 33, userInfo: [NSLocalizedDescriptionKey: "엔진 출력 파일이 생성되지 않았습니다."])
            }

            // 8. Validate root->parent still matches pinned parent (re-used right before publication and deletion)
            let verifyParentPinned: () throws -> Void = {
                try pinnedRoot.withDirectoryFD { rootFD in
                    let verifyParentFD = try NASPinnedFS.openDirectoryChain(rootFD, parentComponents, create: false)
                    defer { Darwin.close(verifyParentFD) }
                    var parentStat = stat()
                    var lockParentStat = stat()
                    guard fstat(verifyParentFD, &parentStat) == 0,
                          fstat(lock.parentFD, &lockParentStat) == 0,
                          parentStat.st_dev == lockParentStat.st_dev,
                          parentStat.st_ino == lockParentStat.st_ino else {
                        throw NSError(domain: "LocalConversionError", code: 40, userInfo: [NSLocalizedDescriptionKey: "상위 디렉터리 격리 검증 실패 (부모 디렉터리 불일치)"])
                    }
                }
            }
            try verifyParentPinned()

            // 9. Check cancellation before irreversible publication
            try Task.checkCancellation()

            // 10. Exclusive, durable MP4 publication. The original keeps its name (no `_원본` rename).
            onStageChange(.staging, "MP4 발행 및 저장 확인 중")
            claim.updatePhase("publishing")

            let published = try LocalPublicationManager.publishMP4(
                sourceLock: lock,
                engineOutputURL: localMP4URL,
                outputExpectedSize: outputSummary.size,
                outputExpectedSha256: outputSummary.sha256,
                attemptID: attemptID,
                claim: claim,
                onCopyProgress: { fraction in
                    onProgress(fraction, "완료본 저장 중")
                }
            )
            outputPublished = true

            // 11. SuperThumbnail from the actual final MP4 (existing VaultProcessor algorithm, fresh MP4 metadata).
            //     Failure keeps the valid MP4 and the original; nothing is deleted.
            onStageChange(.publishing, "썸네일 생성 중")
            claim.updatePhase("thumbnail")

            let parentURL = context.sourceURL.deletingLastPathComponent()
            let finalURL = parentURL.appendingPathComponent(published.finalFileName)
            let thumbnail = try await LocalPublicationManager.createVerifiedThumbnail(
                sourceLock: lock,
                published: published,
                finalURL: finalURL
            )

            // 12. Delete ONLY this attempt's pinned original once MP4 and thumbnail are both verified.
            onStageChange(.publishing, "원본 정리 중")
            claim.updatePhase("deleting")

            do {
                try LocalPublicationManager.deleteVerifiedOriginal(
                    sourceLock: lock,
                    published: published,
                    thumbnail: thumbnail,
                    attemptID: attemptID,
                    claim: claim,
                    verifyParentPinned: verifyParentPinned
                )
            } catch let uncertain as LocalDeletionUncertainError {
                shouldRetainWorkspaceEvidence = true
                throw uncertain
            }

            conversionSucceeded = true
            return .completed(message: "변환 완료 (MP4·썸네일 확인 후 원본 정리됨)")

        } catch is CancellationError {
            engineBridge.cancel(ref: engineRef)
            if outputPublished {
                return .failed(message: "작업 중단: MP4는 발행되었고 원본은 그대로 보존됩니다 (썸네일 생성/원본 정리 미완료)")
            }
            return .cancelled
        } catch let uncertain as LocalDeletionUncertainError {
            // Original may already be gone: never claim it is preserved; evidence (claim, journal, workspace copy) retained.
            return .failed(message: "\(uncertain.detail) [MP4·썸네일은 확인됨]")
        } catch {
            if outputPublished {
                return .failed(message: "\(error.localizedDescription) [MP4 발행됨 · 원본 정리 미완료]")
            }
            return .failed(message: error.localizedDescription)
        }
    }
}

// MARK: - Local Conversion Coordinator

@MainActor
final class LocalConversionCoordinator: ObservableObject {
    @Published private(set) var folders: [LocalFolderItem] = []
    @Published private(set) var activeItems: [LocalConversionItem] = []
    @Published private(set) var recentItems: [LocalConversionItem] = []
    @Published private(set) var counters: LocalConversionCounters = LocalConversionCounters()
    @Published private(set) var queueSummary: LocalConversionQueueSummary = .empty

    @Published var maxConcurrentConversions: Int = LocalConversionConstants.defaultConcurrency {
        didSet {
            let clamped = min(max(maxConcurrentConversions, 1), 4)
            if maxConcurrentConversions != clamped {
                maxConcurrentConversions = clamped
            }
            UserDefaults.standard.set(maxConcurrentConversions, forKey: LocalConversionConstants.concurrencyDefaultsKey)
            let n = maxConcurrentConversions
            Task { [encodeLimiter] in
                await encodeLimiter.setCapacity(n)
            }
            scheduleWork()
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var statusMessage: String = "대기 중"
    @Published private(set) var activeAttemptCount: Int = 0
    @Published private(set) var recoveryNotice: String? = nil

    var hasActiveWork: Bool {
        isRunning || isPaused || !activeItems.isEmpty || !activeTasks.isEmpty || inFlightPulls > 0 || !pendingCandidates.isEmpty
    }

    /// A final denominator is available only after every selected direct folder was fully read.
    var knownTotalCount: Int? {
        let ready = folders.filter { $0.status.isReady }
        guard !ready.isEmpty, inFlightPulls == 0, pendingCandidates.isEmpty,
              ready.allSatisfy({ folder in
                  guard let cursor = folderCursors[folder.id] else { return false }
                  return cursor.isExhausted && cursor.lastError == nil
              }) else { return nil }
        return counters.discoveredCount
    }

    var onRouteToNAS: ((URL) -> Void)?
    var onDirectWorkCompleted: (() -> Void)?

    private let engineBridge: DefaultNASConversionEngineBridge
    private let downloadLimiter = NASResourceLimiter(capacity: 1)
    private let encodeLimiter: NASResourceLimiter
    private var folderCursors: [UUID: LocalIncrementalFolderCursor] = [:]
    private var folderGenerations: [UUID: Int] = [:]
    private var folderPins: [UUID: NASPinnedRoot] = [:]
    private var retainedScopes: [UUID: (url: URL, pin: NASPinnedRoot)] = [:]

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeItemFolders: [UUID: UUID] = [:]
    private var activeEngineRefs: [UUID: String] = [:]
    private var inFlightPulls: Int = 0
    private var pendingCandidates: [LocalDiscoveredFile] = []
    private var currentRunGeneration: Int = 0
    private var failedIdentitiesInPass: Set<LocalFileIdentity> = []

    private static let maxRecentHistoryCount = 100

    init(engineBridge: DefaultNASConversionEngineBridge = DefaultNASConversionEngineBridge()) {
        self.engineBridge = engineBridge

        // Restore persisted concurrency setting (bounded 1...4, default 2)
        let storedConcurrency = UserDefaults.standard.integer(forKey: LocalConversionConstants.concurrencyDefaultsKey)
        let initialConcurrency: Int
        if storedConcurrency >= 1 && storedConcurrency <= 4 {
            initialConcurrency = storedConcurrency
            self.maxConcurrentConversions = storedConcurrency
        } else {
            initialConcurrency = LocalConversionConstants.defaultConcurrency
            self.maxConcurrentConversions = LocalConversionConstants.defaultConcurrency
        }
        self.encodeLimiter = NASResourceLimiter(capacity: initialConcurrency)

        loadRememberedFolders()
    }

    // MARK: - Folder Management

    func loadRememberedFolders() {
        let records = LocalRememberedFolderStore.loadRecords()
        var updatedRecords: [LocalRememberedFolderRecord] = []

        for record in records {
            let (resolvedURL, scopeStarted, refreshedBookmark) = LocalRememberedFolderStore.resolveRecord(record)
            guard let url = resolvedURL else { continue }

            var updated = record
            if let refreshedBookmark {
                updated.bookmark = refreshedBookmark
            }
            updatedRecords.append(updated)

            let folderID = record.id
            folderGenerations[folderID] = 1

            let initialItem = LocalFolderItem(
                id: folderID,
                url: url,
                addedDate: record.addedDate,
                status: .volumeMetadataUnavailable("상태 확인 중..."),
                isScopeStarted: scopeStarted
            )
            folders.append(initialItem)
            folderCursors[folderID] = LocalIncrementalFolderCursor(folderID: folderID, rootURL: url)

            // Bounded async inspection off MainActor (does not enumerate folder)
            Task { [weak self] in
                let status = await LocalVolumeDetector.inspectVolume(at: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if let idx = self.folders.firstIndex(where: { $0.id == folderID }) {
                        self.folders[idx].status = status
                    }
                    if status.isReady {
                        self.openPinOnly(folderID: folderID, url: url, generation: self.folderGenerations[folderID] ?? 1)
                    } else {
                        switch status {
                        case .requiresSharedCoordination, .notLocalVolume:
                            self.onRouteToNAS?(url)
                        default:
                            break
                        }
                    }
                }
            }
        }

        LocalRememberedFolderStore.saveRecords(updatedRecords)
    }

    func addFolder(url: URL) {
        let standardized = url.standardizedFileURL
        guard !folders.contains(where: { $0.url.standardizedFileURL == standardized }) else {
            return
        }

        let folderID = UUID()
        let bookmark = LocalRememberedFolderStore.createBookmark(for: standardized)
        let scopeStarted = standardized.startAccessingSecurityScopedResource()
        folderGenerations[folderID] = 1

        let initialItem = LocalFolderItem(
            id: folderID,
            url: standardized,
            addedDate: Date(),
            status: .volumeMetadataUnavailable("상태 확인 중..."),
            isScopeStarted: scopeStarted
        )
        folders.append(initialItem)
        folderCursors[folderID] = LocalIncrementalFolderCursor(folderID: folderID, rootURL: standardized)

        if let bookmark {
            var records = LocalRememberedFolderStore.loadRecords()
            records.append(LocalRememberedFolderRecord(id: folderID, bookmark: bookmark, addedDate: initialItem.addedDate, lastPath: standardized.path))
            LocalRememberedFolderStore.saveRecords(records)
        }

        // Bounded async inspection off MainActor (does not enumerate folder)
        Task { [weak self] in
            let status = await LocalVolumeDetector.inspectVolume(at: standardized)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let idx = self.folders.firstIndex(where: { $0.id == folderID }) {
                    self.folders[idx].status = status
                }
                if status.isReady {
                    self.openPinOnly(folderID: folderID, url: standardized, generation: self.folderGenerations[folderID] ?? 1)
                } else {
                    self.statusMessage = status.userMessage
                    switch status {
                    case .requiresSharedCoordination, .notLocalVolume:
                        self.onRouteToNAS?(standardized)
                    default:
                        break
                    }
                }
            }
        }
    }

    private func openPinOnly(folderID: UUID, url: URL, generation: Int) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let pin = try? NASPinnedRoot.openBlocking(rootPath: url.path, folderID: folderID, connection: generation) else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.folderGenerations[folderID] == generation else {
                    pin.close()
                    return
                }
                self.folderPins[folderID]?.close()
                self.folderPins[folderID] = pin

                if self.isRunning && !self.isPaused {
                    self.scheduleWork()
                }
            }
        }
    }

    func removeFolder(id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let item = folders.remove(at: index)

        // Increment generation and remove cursor
        let newGen = (folderGenerations[id] ?? 0) + 1
        folderGenerations[id] = newGen
        folderCursors.removeValue(forKey: id)

        var records = LocalRememberedFolderStore.loadRecords()
        records.removeAll(where: { $0.id == id })
        LocalRememberedFolderStore.saveRecords(records)

        // Cancel running tasks belonging to this folder
        let toCancel = activeItems.filter { $0.folderID == id }
        for activeItem in toCancel {
            if let task = activeTasks[activeItem.id] {
                if let ref = activeEngineRefs[activeItem.id] {
                    engineBridge.cancel(ref: ref)
                }
                task.cancel()
            }
        }

        let hasActiveAttemptsForFolder = activeItemFolders.values.contains(id)
        if let pin = folderPins.removeValue(forKey: id) {
            if hasActiveAttemptsForFolder {
                retainedScopes[id] = (url: item.url, pin: pin)
            } else {
                pin.close()
                if item.isScopeStarted {
                    item.url.stopAccessingSecurityScopedResource()
                }
            }
        } else if !hasActiveAttemptsForFolder && item.isScopeStarted {
            item.url.stopAccessingSecurityScopedResource()
        }

        updateQueueSummary()
    }

    func refreshFolders() {
        for folder in folders {
            folderCursors[folder.id]?.reset()
            if folder.status.isReady, folderPins[folder.id] == nil {
                openPinOnly(folderID: folder.id, url: folder.url, generation: folderGenerations[folder.id] ?? 1)
            }
        }
        if isRunning && !isPaused {
            scheduleWork()
        }
    }

    // MARK: - Queue Lifecycle Controls

    func start() {
        guard !isRunning else {
            if isPaused {
                resume()
            }
            return
        }

        currentRunGeneration += 1
        pendingCandidates.removeAll()

        // Reset cursors and pass-local tracking for fresh pass
        failedIdentitiesInPass.removeAll()
        for cursor in folderCursors.values {
            cursor.reset()
        }

        counters = LocalConversionCounters()
        isRunning = true
        isPaused = false
        statusMessage = "영상 변환 시작"
        scheduleWork()
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        onDirectWorkCompleted = nil
        isPaused = true
        statusMessage = "일시정지됨 (진행 중인 변환은 안전하게 완료됩니다)"
        updateQueueSummary()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        statusMessage = "작업 재개됨"
        scheduleWork()
    }

    func stop() {
        guard isRunning else { return }
        onDirectWorkCompleted = nil
        currentRunGeneration += 1
        pendingCandidates.removeAll()
        inFlightPulls = 0
        isRunning = false
        isPaused = false
        isSearching = false
        statusMessage = "작업 중단됨"

        for (itemID, task) in activeTasks {
            if let ref = activeEngineRefs[itemID] {
                engineBridge.cancel(ref: ref)
            }
            task.cancel()
        }

        for i in 0..<activeItems.count {
            activeItems[i].stage = .cancelled
            activeItems[i].statusMessage = "작업 중단 요청됨"
        }
        updateQueueSummary()
    }

    func clearHistory() {
        recentItems.removeAll { $0.stage.isTerminal && self.activeTasks[$0.id] == nil }
        updateQueueSummary()
    }

    // MARK: - On-Demand Scheduling & Streaming Discovery

    private func scheduleWork() {
        guard isRunning, !isPaused else {
            updateQueueSummary()
            return
        }

        // Thermal throttling check
        let thermal = ProcessInfo.processInfo.thermalState
        let effectiveLimit: Int
        if thermal == .critical {
            effectiveLimit = 1
        } else if thermal == .serious {
            effectiveLimit = max(1, maxConcurrentConversions / 2)
        } else {
            effectiveLimit = maxConcurrentConversions
        }

        Task { [encodeLimiter] in
            await encodeLimiter.setCapacity(effectiveLimit)
        }

        // Overlapped pipeline: up to 3N active tasks across download (1), encode (N), and publication phases
        let maxActiveJobs = effectiveLimit * 3
        var freeSlots = maxActiveJobs - (activeTasks.count + inFlightPulls)
        guard freeSlots > 0 else {
            updateQueueSummary()
            return
        }

        // Consume pending candidates first before pulling new files
        while freeSlots > 0 && !pendingCandidates.isEmpty {
            let candidate = pendingCandidates.removeFirst()
            freeSlots -= 1
            counters.discoveredCount += 1
            startConversion(for: candidate)
        }

        guard freeSlots > 0 else {
            updateQueueSummary()
            return
        }

        for _ in 0..<freeSlots {
            pullNextCandidateAndConvert()
        }
    }

    private func pullNextCandidateAndConvert() {
        let readyFolders = folders.filter { $0.status.isReady }
        guard !readyFolders.isEmpty else {
            checkOverallCompletion()
            return
        }

        // Find an unexhausted cursor
        var selectedCursor: LocalIncrementalFolderCursor? = nil
        for folder in readyFolders {
            if let cursor = folderCursors[folder.id], !cursor.isExhausted, cursor.lastError == nil {
                selectedCursor = cursor
                break
            }
        }

        guard let cursor = selectedCursor else {
            checkOverallCompletion()
            return
        }

        inFlightPulls += 1
        isSearching = true
        statusMessage = "한 개씩 찾는 중..."

        let activeIDs = Set(activeItems.map(\.identity))
        let failedIDs = failedIdentitiesInPass
        let runGen = currentRunGeneration

        Task { [weak self] in
            let candidate = await cursor.pullNextCandidate(
                activeIdentities: activeIDs,
                failedIdentitiesInPass: failedIDs
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.currentRunGeneration == runGen else { return }

                self.inFlightPulls = max(0, self.inFlightPulls - 1)
                self.isSearching = (self.inFlightPulls > 0)

                if self.isPaused {
                    if let candidate {
                        if self.pendingCandidates.count < 4 {
                            self.pendingCandidates.append(candidate)
                        }
                    } else if let err = cursor.lastError {
                        self.statusMessage = "폴더 오류: \(err)"
                    }
                    self.updateQueueSummary()
                    return
                }

                guard self.isRunning else {
                    self.checkOverallCompletion()
                    return
                }

                if let candidate {
                    self.counters.discoveredCount += 1
                    self.startConversion(for: candidate)
                } else {
                    if let err = cursor.lastError {
                        self.statusMessage = "폴더 오류: \(err)"
                    }
                    // Current folder cursor exhausted or encountered an error; try other folders or complete
                    self.scheduleWork()
                }
            }
        }
    }

    private func startConversion(for candidate: LocalDiscoveredFile) {
        let folderID = candidate.folderID
        let itemID = candidate.id

        guard let pin = folderPins[folderID]?.duplicate() else {
            counters.skippedCount += 1
            appendRecentItem(
                LocalConversionItem(
                    id: itemID,
                    folderID: folderID,
                    sourceURL: candidate.url,
                    relativePath: candidate.relativePath,
                    relativeComponents: candidate.relativeComponents,
                    fileSize: candidate.fileSize,
                    identity: candidate.identity,
                    stage: .skipped("폴더 접근 잠금 고정을 열 수 없습니다."),
                    statusMessage: "폴더 접근 잠금 고정 실패"
                )
            )
            scheduleWork()
            return
        }

        let attemptID = UUID().uuidString.lowercased()
        let engineRef = "local-\(attemptID)"

        let item = LocalConversionItem(
            id: itemID,
            folderID: folderID,
            sourceURL: candidate.url,
            relativePath: candidate.relativePath,
            relativeComponents: candidate.relativeComponents,
            fileSize: candidate.fileSize,
            identity: candidate.identity,
            stage: .preparing,
            statusMessage: "변환 준비 중",
            engineRef: engineRef
        )

        activeItems.append(item)
        appendRecentItem(item)

        let context = LocalAttemptContext(
            itemID: itemID,
            folderID: folderID,
            sourceURL: candidate.url,
            relativePath: candidate.relativePath,
            relativeComponents: candidate.relativeComponents,
            fileSize: candidate.fileSize,
            expectedIdentity: candidate.identity,
            attemptID: attemptID,
            engineRef: engineRef
        )

        activeItemFolders[itemID] = folderID
        activeEngineRefs[itemID] = engineRef

        let bridge = self.engineBridge
        let downloadLimit = self.downloadLimiter
        let encodeLimit = self.encodeLimiter
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer { pin.close() }

            let result = await LocalConversionWorker.performConversion(
                context: context,
                pinnedRoot: pin,
                engineBridge: bridge,
                downloadLimiter: downloadLimit,
                encodeLimiter: encodeLimit,
                onProgress: { [weak self] fraction, label in
                    Task { @MainActor [weak self] in
                        self?.updateItemProgress(itemID, fraction: fraction, label: label)
                    }
                },
                onStageChange: { [weak self] stage, message in
                    Task { @MainActor [weak self] in
                        self?.updateItemStage(itemID, stage: stage, message: message)
                    }
                }
            )

            await MainActor.run { [weak self] in
                self?.handleWorkerResult(candidate: candidate, result: result)
            }
        }

        activeTasks[itemID] = task
        updateQueueSummary()
    }

    private func handleWorkerResult(candidate: LocalDiscoveredFile, result: LocalWorkerResult) {
        let itemID = candidate.id
        switch result {
        case .completed(let msg):
            counters.completedCount += 1
            updateItemStage(itemID, stage: .completed, message: msg)
        case .failed(let msg):
            counters.failedCount += 1
            failedIdentitiesInPass.insert(candidate.identity)
            updateItemStage(itemID, stage: .failed(msg), message: "오류: \(msg)")
        case .skipped(let msg):
            counters.skippedCount += 1
            updateItemStage(itemID, stage: .skipped(msg), message: msg)
        case .cancelled:
            updateItemStage(itemID, stage: .cancelled, message: "작업 취소됨")
        }

        activeTasks.removeValue(forKey: itemID)
        activeEngineRefs.removeValue(forKey: itemID)
        activeItems.removeAll { $0.id == itemID }

        if let folderID = activeItemFolders.removeValue(forKey: itemID) {
            if !activeItemFolders.values.contains(folderID), let retained = retainedScopes.removeValue(forKey: folderID) {
                retained.pin.close()
                retained.url.stopAccessingSecurityScopedResource()
            }
        }

        updateQueueSummary()
        if isRunning && !isPaused {
            scheduleWork()
        }
    }

    private func checkOverallCompletion() {
        guard activeTasks.isEmpty && inFlightPulls == 0 && pendingCandidates.isEmpty else {
            return
        }

        let readyFolders = folders.filter { $0.status.isReady }
        let anyRemaining = readyFolders.contains { folder in
            if let cursor = folderCursors[folder.id] {
                return !cursor.isExhausted && cursor.lastError == nil
            }
            return false
        }

        if anyRemaining {
            scheduleWork()
            return
        }

        guard isRunning else { return }
        isRunning = false
        isPaused = false
        isSearching = false

        let folderErrors = readyFolders.compactMap { folderCursors[$0.id]?.lastError }
        if !folderErrors.isEmpty {
            statusMessage = "변환 완료 (일부 폴더 오류 발생: \(folderErrors.first ?? "")) - 처리 \(counters.handledCount)개"
        } else if counters.failedCount > 0 {
            statusMessage = "변환 종료: 완료 \(counters.completedCount)개, 실패 \(counters.failedCount)개, 건너뜀 \(counters.skippedCount)개"
        } else if counters.handledCount > 0 {
            statusMessage = "모든 변환 작업 완료 (완료 \(counters.completedCount)개, 실패 0개, 건너뜀 \(counters.skippedCount)개)"
        } else {
            statusMessage = "변환 대상 파일을 찾지 못했습니다."
        }
        updateQueueSummary()
        let directDone = onDirectWorkCompleted
        onDirectWorkCompleted = nil
        directDone?()
    }

    // MARK: - History & UI Updates

    private func appendRecentItem(_ item: LocalConversionItem) {
        if let idx = recentItems.firstIndex(where: { $0.id == item.id }) {
            recentItems[idx] = item
        } else {
            recentItems.insert(item, at: 0)
            if recentItems.count > Self.maxRecentHistoryCount {
                recentItems.removeLast()
            }
        }
    }

    private func updateItemStage(_ itemID: UUID, stage: LocalConversionStage, message: String) {
        if let idx = activeItems.firstIndex(where: { $0.id == itemID }) {
            activeItems[idx].stage = stage
            activeItems[idx].statusMessage = message
            if stage.isTerminal {
                activeItems[idx].fraction = nil
            }
        }

        if let idx = recentItems.firstIndex(where: { $0.id == itemID }) {
            recentItems[idx].stage = stage
            recentItems[idx].statusMessage = message
            if stage.isTerminal {
                recentItems[idx].fraction = nil
            }
        }
    }

    private func updateItemProgress(_ itemID: UUID, fraction: Double?, label: String?) {
        if let idx = activeItems.firstIndex(where: { $0.id == itemID }) {
            activeItems[idx].fraction = fraction
            activeItems[idx].phaseLabel = label
        }
        if let idx = recentItems.firstIndex(where: { $0.id == itemID }) {
            recentItems[idx].fraction = fraction
            recentItems[idx].phaseLabel = label
        }
    }

    private func updateQueueSummary() {
        counters.inProgressCount = activeItems.count
        activeAttemptCount = activeItems.count

        queueSummary = LocalConversionQueueSummary(
            pendingCount: (isSearching ? 1 : 0) + pendingCandidates.count,
            runningCount: activeItems.count,
            pausedCount: isPaused ? activeItems.count : 0,
            completedCount: counters.completedCount,
            failedCount: counters.failedCount,
            cancelledCount: 0,
            skippedCount: counters.skippedCount,
            totalCount: counters.discoveredCount
        )
    }
}
