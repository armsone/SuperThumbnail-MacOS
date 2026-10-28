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

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isSkipped: Bool {
        if case .skipped = self { return true }
        return false
    }

    /// Short badge for list rows; the full text lives in `detailText`.
    var shortBadge: String {
        switch self {
        case .completed: return "완료"
        case .failed: return "실패"
        case .skipped: return "건너뜀"
        case .cancelled: return "취소됨"
        case .pending, .preparing, .copyingSource, .converting, .verifying, .staging, .publishing: return displayName
        }
    }

    /// Complete, unshortened reason for failed / skipped stages.
    var detailText: String? {
        switch self {
        case .failed(let err): return err
        case .skipped(let reason): return reason
        default: return nil
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
    /// Set only for a candidate recovery proved to already have a verified published MP4: the worker re-verifies it
    /// under its own new claim and only creates/verifies the thumbnail (no re-encode, no deletion).
    var publishedResume: LocalPublishedResumeProof? = nil
}

enum LocalWorkerResult: Sendable {
    case completed(message: String)
    case failed(message: String)
    case skipped(message: String)
    case cancelled
    /// Internal to the retry wrapper: the pre-publication attempt was aborted only because WebDAV refreshed
    /// mtime/ctime. Never surfaced to the coordinator.
    case identityRefresh(LocalFileIdentity)
}

/// What a finished attempt confirmed about its own cleanup; a metadata-refresh retry runs only if all are clean.
final class LocalAttemptCleanupState: @unchecked Sendable {
    private let lock = NSLock()
    private var claimPending = false
    private var workspacePending = false

    var isFullyCleaned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !claimPending && !workspacePending
    }

    func setClaimPending(_ pending: Bool) {
        lock.lock()
        claimPending = pending
        lock.unlock()
    }

    func setWorkspacePending(_ pending: Bool) {
        lock.lock()
        workspacePending = pending
        lock.unlock()
    }
}

/// Thrown after the copy phase when only mtime/ctime of the same WebDAV file changed.
struct LocalIdentityRefreshRequest: Error {
    let refreshed: LocalFileIdentity
}

/// The preclaim source `openat` kept returning EINTR: a real connection interruption, never an owner conflict.
struct LocalSourceOpenInterruptedError: Error {
    let fileName: String
}

/// Single-use hold of one download permit. `release` / `releaseDetached` are idempotent and only release a
/// permit that was actually acquired, so early exits cannot leak or double-release it.
final class DownloadPermitHold: @unchecked Sendable {
    private let limiter: NASResourceLimiter
    private let lock = NSLock()
    private var held = false
    private var detachedRelease: Task<Void, Never>?

    init(limiter: NASResourceLimiter) {
        self.limiter = limiter
    }

    func acquire() async throws {
        try await limiter.acquire()
        markHeld()
    }

    private func markHeld() {
        lock.lock()
        held = true
        lock.unlock()
    }

    private func takeHeld() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = held
        held = false
        return was
    }

    /// Returns only after the permit is back in the limiter, also when `releaseDetached` already started returning it.
    func release() async {
        if takeHeld() {
            await limiter.release()
        }
        let pending = lock.withLock { detachedRelease }
        await pending?.value
    }

    /// For `defer` blocks that cannot await.
    func releaseDetached() {
        guard takeHeld() else { return }
        let limiter = self.limiter
        let task = Task { await limiter.release() }
        lock.lock()
        detachedRelease = task
        lock.unlock()
    }
}

enum LocalConversionWorker {
    private nonisolated static func isWebDAV(fd: Int32) -> Bool {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return false }
        let name = withUnsafeBytes(of: fs.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        return name == "webdav"
    }

    /// WebDAV can serve cached mtime/ctime that refresh after a read. When a pre-publication check finds ONLY that
    /// (same dev/inode/size, full byte count), the failed attempt is cleaned up completely (claim released, fds
    /// closed, workspace removed, download slot freed) and exactly ONE new whole attempt runs with a fresh
    /// descriptor, attempt ID, claim, and hash, pinned to the refreshed identity. No further refresh is allowed.
    nonisolated static func performConversion(
        context: LocalAttemptContext,
        pinnedRoot: NASPinnedRoot,
        engineBridge: DefaultNASConversionEngineBridge,
        downloadLimiter: NASResourceLimiter,
        encodeLimiter: NASResourceLimiter,
        onProgress: @Sendable @escaping (Double?, String?) -> Void,
        onStageChange: @Sendable @escaping (LocalConversionStage, String) -> Void
    ) async -> LocalWorkerResult {
        let cleanup = LocalAttemptCleanupState()
        let firstPermit = DownloadPermitHold(limiter: downloadLimiter)
        let first = await performSingleAttempt(
            context: context,
            allowIdentityRefresh: true,
            cleanup: cleanup,
            downloadPermit: firstPermit,
            pinnedRoot: pinnedRoot,
            engineBridge: engineBridge,
            encodeLimiter: encodeLimiter,
            onProgress: onProgress,
            onStageChange: onStageChange
        )
        // The first attempt's download permit is back in the limiter before the retry asks for its own.
        await firstPermit.release()
        guard case .identityRefresh(let refreshed) = first else { return first }

        // All defers of the first attempt have run. Without confirmed cleanup (e.g. claim not released) never retry.
        guard cleanup.isFullyCleaned else {
            return .skipped(message: "원본 정보 변경 감지 후 정리를 확인하지 못해 재시도하지 않습니다(원본 유지)")
        }
        if Task.isCancelled { return .cancelled }
        onStageChange(.preparing, "원본 정보 새로 확인 중")
        onProgress(nil, nil)

        let newAttemptID = UUID().uuidString.lowercased()
        let retryContext = LocalAttemptContext(
            itemID: context.itemID,
            folderID: context.folderID,
            sourceURL: context.sourceURL,
            relativePath: context.relativePath,
            relativeComponents: context.relativeComponents,
            fileSize: context.fileSize,
            expectedIdentity: refreshed,
            attemptID: newAttemptID,
            // The first attempt never started the engine, so the coordinator's cancel handle (this ref) stays valid.
            engineRef: context.engineRef,
            // A resume of an already published MP4 must stay a resume (never fall into a fresh encode).
            publishedResume: context.publishedResume
        )
        let second = await performSingleAttempt(
            context: retryContext,
            allowIdentityRefresh: false,
            cleanup: LocalAttemptCleanupState(),
            downloadPermit: DownloadPermitHold(limiter: downloadLimiter),
            pinnedRoot: pinnedRoot,
            engineBridge: engineBridge,
            encodeLimiter: encodeLimiter,
            onProgress: onProgress,
            onStageChange: onStageChange
        )
        if case .identityRefresh = second {
            return .skipped(message: "원본 정보가 다시 바뀌어 건너뜁니다(원본 유지)")
        }
        return second
    }

    /// Nonisolated background worker performing heavy file I/O, hashing, engine execution,
    /// and atomic descriptor-relative publication strictly off the MainActor.
    private nonisolated static func performSingleAttempt(
        context: LocalAttemptContext,
        allowIdentityRefresh: Bool,
        cleanup: LocalAttemptCleanupState,
        downloadPermit: DownloadPermitHold,
        pinnedRoot: NASPinnedRoot,
        engineBridge: DefaultNASConversionEngineBridge,
        encodeLimiter: NASResourceLimiter,
        onProgress: @Sendable @escaping (Double?, String?) -> Void,
        onStageChange: @Sendable @escaping (LocalConversionStage, String) -> Void
    ) async -> LocalWorkerResult {
        let itemID = context.itemID
        let sourceURL = context.sourceURL
        let fileSize = context.fileSize
        let attemptID = context.attemptID
        let engineRef = context.engineRef

        // 0. The download permit covers everything that touches the remote source (volume query, open, lock,
        //    claim, workspace setup, copy). macOS WebDAV downloads eagerly on open, so opening before the permit
        //    let several workers hammer the NAS at once. It is released before encoding starts.
        onStageChange(.preparing, "다운로드 순서 대기 중")
        do {
            try await downloadPermit.acquire()
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
        // Every exit path (return, throw, cancellation) releases the permit exactly once.
        defer { downloadPermit.releaseDetached() }
        if Task.isCancelled { return .cancelled }
        onStageChange(.preparing, "NAS 원본 연결 중")

        // 1. Conservative disk capacity check (at least 2x source size + 500MB headroom).
        //    A resume of an already published MP4 copies and encodes nothing, so it needs no such headroom.
        let requiredSpace = context.publishedResume == nil ? fileSize * 2 + 500_000_000 : 0
        if requiredSpace > 0, let available = LocalVolumeDetector.availableCapacityBytes(for: sourceURL), available < requiredSpace {
            let msg = "디스크 여유 공간 부족 (필요: \(requiredSpace / 1024 / 1024)MB, 사용 가능: \(available / 1024 / 1024)MB)"
            return .failed(message: msg)
        }
        // Download/encode cache lives in the local temporary directory regardless of remote quota reporting.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if requiredSpace > 0, let localAvailable = LocalVolumeDetector.availableCapacityBytes(for: tempURL), localAvailable < requiredSpace {
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

                // Only this preclaim open: a network mount may interrupt it (EINTR). At most 3 retries on the same
                // parentFD with NOFOLLOW; ENOENT and every other errno fail at once, exactly as before.
                var fd: Int32 = -1
                var err: Int32 = 0
                var attempt = 0
                while true {
                    fd = openat(parentFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    if fd >= 0 { break }
                    err = errno
                    guard err == EINTR else { break }
                    if attempt >= 3 {
                        Darwin.close(parentFD)
                        throw LocalSourceOpenInterruptedError(fileName: fileName)
                    }
                    attempt += 1
                    do {
                        try Task.checkCancellation()
                    } catch {
                        Darwin.close(parentFD)
                        throw error
                    }
                }
                guard fd >= 0 else {
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
        } catch is CancellationError {
            return .cancelled
        } catch is LocalSourceOpenInterruptedError {
            return .failed(message: "NAS 연결이 중단되어 원본을 열지 못했습니다 (errno 4, 3회 재시도 후). 네트워크 연결을 확인한 뒤 다시 시도해 주세요. 원본은 변경되지 않았습니다.")
        } catch {
            return .skipped(message: "잠금 획득 불가: \(error.localizedDescription)")
        }
        defer { lock.unlock() }

        // Verify initial identity matches discovered identity
        // Exact match only (nothing tolerated or adopted); the lock identity is what claim and deletion gates later use.
        // NO-DELETE resume of an already published MP4: the original is never changed or deleted here, and a webdav mount may show
        // other mtime/ctime for the same file at every enumeration or open. Only dev/inode/size bind it (and the exact journal is
        // re-proven below); no refresh retry, no skip for time-only differences. Any other difference still skips.
        let resumeKeepsTimeChurn = context.publishedResume != nil && isWebDAV(fd: lock.fd)
            && lock.identity.isSameFile(as: context.expectedIdentity)
        guard lock.identity == context.expectedIdentity || resumeKeepsTimeChurn else {
            if allowIdentityRefresh, isWebDAV(fd: lock.fd),
               lock.identity.isTimestampOnlyDrift(from: context.expectedIdentity) {
                return .identityRefresh(lock.identity)
            }
            let diff = lock.identity.differences(from: context.expectedIdentity).joined(separator: ", ")
            return .skipped(message: "파일 식별 정보가 목록 조회 시점과 달라 건너뜁니다(원본 유지): \(diff)")
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
        cleanup.setClaimPending(true)
        defer {
            if claim.release(success: conversionSucceeded) == nil {
                cleanup.setClaimPending(false)
            }
        }

        // 3b. Resume of an already published MP4 (recovery handed over the proof). The current claim is this attempt's
        //     own; the proof is re-verified from the files under it (original identity, exact journal, MP4 size + SHA-256).
        //     Only the thumbnail is created/verified. The original is NEVER deleted here and nothing is re-encoded,
        //     overwritten or cleaned up; on any failure the claim is released and every file stays.
        if let resume = context.publishedResume {
            onStageChange(.verifying, "이전 발행 MP4 확인 중")
            claim.updatePhase("verifying")
            var previousMP4Verified = false
            do {
                let published = try LocalPublicationManager.verifyResumedPublication(
                    sourceLock: lock, proof: resume, claim: claim
                )
                // The earlier MP4 is now proven under this claim: if anything fails from here on, keep this claim as recovery
                // evidence (existing mutation-started semantics) so the next start can archive it and seed the retry again.
                claim.markSourceMutationStarted()
                previousMP4Verified = true
                try Task.checkCancellation()
                onStageChange(.publishing, "썸네일 생성 중")
                claim.updatePhase("thumbnail")
                let finalURL = sourceURL.deletingLastPathComponent().appendingPathComponent(published.finalFileName)
                _ = try await LocalPublicationManager.createVerifiedThumbnail(
                    sourceLock: lock,
                    published: published,
                    finalURL: finalURL,
                    resumedPublication: true
                )
                conversionSucceeded = true
                return .completed(message: "이전 변환의 MP4·썸네일 확인 완료 (원본 보존, 삭제하지 않음)")
            } catch is CancellationError {
                return .cancelled
            } catch {
                let state = previousMP4Verified
                    ? "이전 MP4는 검증됨·현재 원본은 그대로 보존·기록 보존, 썸네일만 미완료 (다음 시작 때 이어서 시도)"
                    : "이전 MP4·원본·기록은 그대로 보존"
                return .failed(message: "\(error.localizedDescription) [\(state)]")
            }
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

        cleanup.setWorkspacePending(true)
        do {
            try NASPathSecurity.prepareOwnedWorkspaceRoot(at: workspaceURL)
        } catch {
            try? FileManager.default.removeItem(at: workspaceURL)
            if !FileManager.default.fileExists(atPath: workspaceURL.path) {
                cleanup.setWorkspacePending(false)
            }
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
                if !FileManager.default.fileExists(atPath: workspaceURL.path) {
                    cleanup.setWorkspacePending(false)
                }
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
            let (sourceSha256, copiedBytes) = try await { () async throws -> (String, Int64) in
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
                    if allowIdentityRefresh, copied == fileSize, isWebDAV(fd: sourceFD),
                       postCopyIdentity.isTimestampOnlyDrift(from: expectedIdentity) {
                        throw LocalIdentityRefreshRequest(refreshed: postCopyIdentity)
                    }
                    var detail = postCopyIdentity.differences(from: expectedIdentity)
                    if copied != fileSize { detail.append("복사 바이트(\(copied)≠목록 크기 \(fileSize))") }
                    throw NSError(domain: "LocalConversionError", code: 30, userInfo: [NSLocalizedDescriptionKey: "복사 전후 원본 파일 식별 정보 불일치(원본 유지): \(detail.joined(separator: ", "))"])
                }

                onProgress(1, "다운로드 완료 · 인코딩 대기")
                return (sha, copied)
            }()
            // Copy finished: free the download slot so the next file can start while this one encodes.
            await downloadPermit.release()
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
                    allowClockRecovery: true,
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

            // 11b. Repaired-clock output: MP4 and thumbnail are verified and published, but the original is KEPT.
            //      Decided only by the engine's structured flag (deleted only when it is explicitly false), never by message text.
            if engineResult.retain_original != false {
                conversionSucceeded = true
                return .completed(message: "복구 변환 완료 (원본 보존)")
            }

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

        } catch let refresh as LocalIdentityRefreshRequest {
            return .identityRefresh(refresh.refreshed)
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
    @Published private(set) var isRecovering: Bool = false
    /// Per-item reasons and real folder I/O errors of the last cleanup/retry; stays visible until the next run.
    @Published private(set) var recoveryDetails: [String] = []
    /// Sticky notice about reading the saved history file (corrupt / unreadable / rejected records).
    @Published private(set) var historyLoadNotice: String? = nil
    /// Latest failure while saving the history file; cleared by the next successful save.
    @Published private(set) var historySaveNotice: String? = nil

    /// Set by the view: true while the NAS helper is working, so cleanup/retry never overlaps it.
    var isExternalWorkActive: (() -> Bool)?

    var hasActiveWork: Bool {
        isRunning || isPaused || isSearching || !activeItems.isEmpty || !activeTasks.isEmpty || inFlightPulls > 0 || !pendingCandidates.isEmpty || isRecovering
    }

    /// A final denominator is available only after every selected direct folder was fully read.
    var knownTotalCount: Int? {
        if isTargetedRetry { return targetedTotal }
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
    /// Finite retry of an explicit candidate list: never pulls from folder cursors.
    private var isTargetedRetry = false
    private var targetedTotal = 0

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

        LocalConversionHistoryStore.shared.load { [weak self] outcome in
            Task { @MainActor [weak self] in
                self?.applyLoadedHistory(outcome)
            }
        }

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
        guard !isRecovering else {
            statusMessage = "정리·다시 시도 중에는 폴더를 제거할 수 없습니다. 끝난 뒤 다시 시도해 주세요."
            return
        }
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
        guard !isRecovering else {
            statusMessage = "정리·다시 시도 중에는 새로고침할 수 없습니다."
            return
        }
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
        guard !isRecovering else {
            statusMessage = "준비 중입니다. 잠시 후 다시 시작할 수 있습니다."
            return
        }
        guard !hasActiveWork else {
            statusMessage = "진행 중인 작업이 있어 새로 시작하지 않았습니다."
            return
        }

        // Single entry point: safe cleanup of own interrupted markers, then a full scan of all remaining originals.
        recoverAndRetry(includeAllRemaining: true)
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
        isTargetedRetry = false
        targetedTotal = 0
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
        LocalConversionHistoryStore.shared.clear { [weak self] failure in
            Task { @MainActor [weak self] in
                self?.historySaveNotice = failure
            }
        }
        updateQueueSummary()
    }

    private func applyLoadedHistory(_ outcome: LocalHistoryLoadOutcome) {
        historyLoadNotice = outcome.notice
        let knownIDs = Set(recentItems.map(\.id))
        let older = outcome.items.filter { !knownIDs.contains($0.id) }
        guard !older.isEmpty else { return }
        recentItems = (recentItems + older).sorted { $0.addedDate > $1.addedDate }
        pruneRecentItems()
    }

    private func persistIfTerminal(_ item: LocalConversionItem) {
        guard item.stage.isTerminal else { return }
        LocalConversionHistoryStore.shared.upsert([item]) { [weak self] failure in
            Task { @MainActor [weak self] in
                self?.historySaveNotice = failure
            }
        }
    }

    // MARK: - Recovery & Retry Operations

    /// Latest terminal history record of one file, expressed in the CURRENTLY selected folders.
    struct HistoryLocation: Sendable {
        let target: LocalRetryTarget
        let stage: LocalConversionStage
        let addedDate: Date
    }

    /// Re-expresses a persisted record in the currently selected folders (e.g. after the selected root moved from
    /// `.../01-CLIP` up to `.../Caution`). The recorded absolute location must lie strictly INSIDE a selected root
    /// (whole path components, never a string prefix; the most specific selected root wins; the stored folder ID is never
    /// trusted on its own). The derived components are re-validated; anything outside, or whose file name differs from the
    /// recorded one, is rejected. Symlinks are not followed later: the pinned no-follow walk stays authoritative.
    nonisolated static func currentLocation(of item: LocalConversionItem, in folders: [LocalFolderItem]) -> LocalRetryTarget? {
        let recorded = item.sourceURL.standardizedFileURL.pathComponents
        var best: (folder: LocalFolderItem, depth: Int)?
        for folder in folders {
            let root = folder.url.standardizedFileURL.pathComponents
            guard recorded.count > root.count, Array(recorded.prefix(root.count)) == root else { continue }
            if let current = best, current.depth > root.count || (current.depth == root.count && current.folder.id == item.folderID) { continue }
            best = (folder, root.count)
        }
        guard let best else { return nil }

        var derived = Array(recorded.dropFirst(best.depth))
        let recordedTail = item.relativeComponents
        if derived.count >= recordedTail.count, Array(derived.suffix(recordedTail.count)) == recordedTail {
            derived = Array(derived.dropLast(recordedTail.count)) + recordedTail   // keep the exact enumerated names
        }
        guard derived.last == recordedTail.last,
              let validated = LocalConversionRetryInspector.validatedComponents(derived) else { return nil }
        return LocalRetryTarget(folderID: best.folder.id, components: validated)
    }

    /// Latest terminal record per FILE in the current folders (records of removed/moved roots merge with newer ones for the
    /// same absolute file, so a newer completion always wins over an older failure). Oldest first.
    nonisolated static func latestHistoryLocations(from items: [LocalConversionItem], folders: [LocalFolderItem]) -> [HistoryLocation] {
        var latest: [String: (location: HistoryLocation, order: Int)] = [:]
        for (order, item) in items.enumerated() where item.stage.isTerminal {
            guard let target = currentLocation(of: item, in: folders) else { continue }
            let key = "\(target.folderID.uuidString)/\(target.components.joined(separator: "/"))"
            if let existing = latest[key], existing.location.addedDate >= item.addedDate { continue }
            latest[key] = (HistoryLocation(target: target, stage: item.stage, addedDate: item.addedDate), order)
        }
        return latest.values
            .sorted { ($0.location.addedDate, $0.order) < ($1.location.addedDate, $1.order) }
            .map(\.location)
    }

    /// Only a latest failed/skipped record is retried (completed history stays ignored).
    nonisolated static func retryTargets(from locations: [HistoryLocation]) -> [LocalRetryTarget] {
        locations.filter { $0.stage.isFailed || $0.stage.isSkipped }.map(\.target)
    }

    /// Unique parent directories of every known not-completed file (failed/skipped/cancelled) plus each selected root.
    /// Used by the unified start to recover this Mac's own claims WITHOUT walking the whole tree first.
    nonisolated static func recoveryDirectories(from locations: [HistoryLocation], folders: [LocalFolderItem]) -> [UUID: Set<[String]>] {
        var out: [UUID: Set<[String]>] = [:]
        for folder in folders { out[folder.id, default: []].insert([]) }
        for location in locations {
            if case .completed = location.stage { continue }
            out[location.target.folderID, default: []].insert(Array(location.target.components.dropLast()))
        }
        return out
    }

    /// Checks the conversion tools once before any cleanup, claim or download. When they are missing the whole run is
    /// refused with ONE app-level status: no per-file failure records and no source access.
    private func preflightConversionTools() -> Bool {
        let environment = NASToolEnvironment.detect()
        guard environment.isReadyToExecute else {
            let message = "변환을 시작하지 못했습니다. \(environment.diagnosticMessage)"
            onDirectWorkCompleted = nil
            isRecovering = false
            recoveryNotice = message
            statusMessage = message
            return false
        }
        return true
    }

    /// Safe cleanup of this Mac's own interrupted work markers (off the main thread, under the exclusive device
    /// lease), then a finite retry of failed/skipped files. Without any failed/skipped history (e.g. first start after
    /// an upgrade) every remaining eligible original in the selected folders is searched again.
    func recoverAndRetry(includeAllRemaining: Bool = false) {
        guard !hasActiveWork else {
            statusMessage = "진행 중인 작업이 있어 정리·다시 시도를 시작하지 않았습니다."
            return
        }
        if isExternalWorkActive?() == true {
            statusMessage = "이 앱에서 다른 변환이 진행 중이라 정리·다시 시도를 시작하지 않았습니다."
            return
        }
        let readyFolders = folders.filter { $0.status.isReady }
        guard !readyFolders.isEmpty else {
            statusMessage = "작업 가능한 폴더가 없습니다."
            return
        }
        guard preflightConversionTools() else { return }

        // Pinned roots are duplicated now and kept for the WHOLE operation (cleanup and fresh inspection).
        var pins: [UUID: NASPinnedRoot] = [:]
        var pinErrors: [String] = []
        for folder in readyFolders {
            if let pin = folderPins[folder.id]?.duplicate() {
                pins[folder.id] = pin
            } else {
                pinErrors.append("[폴더 오류] \(folder.displayName): 폴더 연결을 열지 못했습니다. 폴더 상태를 확인한 뒤 새로고침해 주세요.")
            }
        }
        guard pinErrors.isEmpty else {
            for pin in pins.values { pin.close() }
            recoveryDetails = pinErrors
            let message = "폴더 접근 오류로 정리·다시 시도를 시작하지 않았습니다 (\(pinErrors.count)개 폴더)."
            recoveryNotice = message
            statusMessage = message
            return
        }

        let finalPins = pins
        let historySnapshot = recentItems
        let locations = Self.latestHistoryLocations(from: historySnapshot, folders: readyFolders)
        let targets = includeAllRemaining ? [] : Self.retryTargets(from: locations)
        let hasRetryHistory = !targets.isEmpty
        // Latest failed/skipped files that may already own a published MP4 (checked candidate-locally, read-only and without reading
        // the MP4 content; the worker proves the full SHA-256 before any thumbnail write). The regular scan is unchanged.
        let resumeTargets = Self.retryTargets(from: locations)
        // Unified start recovers own claims only in known directories (history parents + selected roots), never the whole tree
        // before the first encode. Unknown stale claims elsewhere are skipped untouched by discovery (no claim is taken over);
        // once such a file shows up in history (skipped), the next start recovers it. The manual retry keeps the full scan.
        let recoveryScope: [UUID: Set<[String]>]? = includeAllRemaining ? Self.recoveryDirectories(from: locations, folders: readyFolders) : nil

        isRecovering = true
        recoveryNotice = nil
        recoveryDetails = []
        statusMessage = includeAllRemaining ? "준비 중: 중단된 작업 표시 정리 중..." : "중단된 작업 표시 정리 중..."

        Task { [weak self] in
            let recovery = await LocalConversionRecovery.performRecovery(folders: readyFolders, pins: finalPins, onlyDirectories: recoveryScope)

            var inspection = LocalRetryInspection()
            if hasRetryHistory, recovery.blockedReason == nil {
                inspection = await Task.detached(priority: .userInitiated) {
                    LocalConversionRetryInspector.inspect(targets: targets, folders: readyFolders, pins: finalPins)
                }.value
            }
            if !resumeTargets.isEmpty, recovery.blockedReason == nil {
                let known = await Task.detached(priority: .userInitiated) {
                    LocalConversionRecovery.inspectKnownPublishedResume(targets: resumeTargets, folders: readyFolders, pins: finalPins)
                }.value
                inspection.candidates += known.candidates
                inspection.errors += known.errors
                inspection.notes += known.notes
            }
            for pin in finalPins.values { pin.close() }

            guard let self else { return }
            self.finishRecovery(recovery: recovery, inspection: inspection, hasRetryHistory: hasRetryHistory, unifiedStart: includeAllRemaining)
        }
    }

    private func finishRecovery(
        recovery: LocalConversionRecoveryResult,
        inspection: LocalRetryInspection,
        hasRetryHistory: Bool,
        unifiedStart: Bool = false
    ) {
        recoveryDetails = recovery.detailLines + inspection.errors.map { "[폴더 오류] \($0)" } + inspection.notes.map { "[건너뜀] \($0)" }
        let summary = recovery.summaryMessage
        let errorSuffix = inspection.errors.isEmpty ? "" : " · 다시 시도 대상 확인 오류 \(inspection.errors.count)건"

        guard recovery.blockedReason == nil else {
            isRecovering = false
            recoveryNotice = summary
            statusMessage = summary
            return
        }

        if !hasRetryHistory {
            // No failed/skipped history: search ALL remaining eligible originals (recovered files are found again by this scan).
            // Published MP4s are skipped by discovery (the MP4 exists), so recovery's resume candidates are queued explicitly.
            var seenResume = Set<String>()
            let resumeCandidates = (recovery.recoveredCandidates.filter { $0.publishedResume != nil } + inspection.candidates).filter {
                seenResume.insert("\($0.folderID.uuidString)/\($0.relativeComponents.joined(separator: "/"))").inserted
            }
            let resumeNote = resumeCandidates.isEmpty ? "" : " 발행된 MP4 \(resumeCandidates.count)개는 썸네일 확인만 이어서 진행합니다."
            let message = unifiedStart
                ? "\(summary) · 남은 원본 전체를 찾아 변환합니다.\(resumeNote)"
                : "\(summary) · 실패 기록이 없어 남은 원본 전체를 다시 찾아 변환합니다.\(resumeNote)"
            recoveryNotice = message
            isRecovering = false
            beginFullRescan(message: "남은 원본 영상 전체 탐색 및 변환 시작", seed: resumeCandidates)
            return
        }

        var seen = Set<String>()
        var candidates: [LocalDiscoveredFile] = []
        for candidate in recovery.recoveredCandidates + inspection.candidates {
            let key = "\(candidate.folderID.uuidString)/\(candidate.relativeComponents.joined(separator: "/"))"
            if seen.insert(key).inserted { candidates.append(candidate) }
        }

        isRecovering = false
        guard !candidates.isEmpty else {
            let message = "\(summary) · 다시 시도할 영상이 없습니다\(errorSuffix)."
            recoveryNotice = message
            statusMessage = message
            return
        }
        recoveryNotice = "\(summary) · 실패/건너뜀 및 정리된 영상 \(candidates.count)개만 다시 시도합니다\(errorSuffix)."
        startTargetedRetry(candidates, message: "정리·실패 항목 \(candidates.count)개 다시 시도 시작")
    }

    /// Searches every remaining eligible original again in all selected folders.
    func rescanRemainingEligible() {
        guard !hasActiveWork else {
            statusMessage = "진행 중인 작업이 있어 다시 찾기를 시작하지 않았습니다."
            return
        }
        if isExternalWorkActive?() == true {
            statusMessage = "이 앱에서 다른 변환이 진행 중이라 다시 찾기를 시작하지 않았습니다."
            return
        }
        beginFullRescan(message: "남은 원본 영상 전체 탐색 및 변환 시작")
    }

    private func beginFullRescan(message: String, seed: [LocalDiscoveredFile] = []) {
        guard !isRunning, !isRecovering else { return }
        let readyFolders = folders.filter { $0.status.isReady }
        guard !readyFolders.isEmpty else { return }
        guard preflightConversionTools() else { return }

        currentRunGeneration += 1
        pendingCandidates = seed
        failedIdentitiesInPass.removeAll()
        isTargetedRetry = false
        targetedTotal = 0

        for folder in readyFolders {
            folderCursors[folder.id]?.reset()
        }

        counters = LocalConversionCounters()
        isRunning = true
        isPaused = false
        statusMessage = message
        scheduleWork()
    }

    private func startTargetedRetry(_ candidates: [LocalDiscoveredFile], message: String) {
        guard !candidates.isEmpty, !isRunning, !isRecovering else { return }
        guard preflightConversionTools() else { return }
        currentRunGeneration += 1
        failedIdentitiesInPass.removeAll()
        pendingCandidates = candidates
        targetedTotal = candidates.count
        isTargetedRetry = true

        counters = LocalConversionCounters()
        isRunning = true
        isPaused = false
        statusMessage = message
        scheduleWork()
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

        // Targeted retry is a finite list: it never pulls from folder cursors.
        if isTargetedRetry {
            updateQueueSummary()
            checkOverallCompletion()
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

        // Shared device lease for the whole worker lifecycle: a running cleanup excludes it atomically.
        guard let lease = LocalRecoveryExclusion.shared.acquireShared() else {
            pin.close()
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
                    stage: .skipped("정리 작업이 진행 중이어서 시작하지 않았습니다. 잠시 뒤 다시 시도해 주세요."),
                    statusMessage: "정리 작업 중이라 시작하지 않음"
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
            engineRef: engineRef,
            publishedResume: candidate.publishedResume
        )

        activeItemFolders[itemID] = folderID
        activeEngineRefs[itemID] = engineRef

        let bridge = self.engineBridge
        let downloadLimit = self.downloadLimiter
        let encodeLimit = self.encodeLimiter
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                pin.close()
                lease.release()
            }

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
        case .identityRefresh:
            // Resolved inside the worker; defensively treated as a safe skip (original kept).
            counters.skippedCount += 1
            updateItemStage(itemID, stage: .skipped("원본 정보 변경으로 건너뜀(원본 유지)"), message: "원본 정보 변경으로 건너뜀")
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
        let anyRemaining = !isTargetedRetry && readyFolders.contains { folder in
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
        let wasTargeted = isTargetedRetry
        isRunning = false
        isPaused = false
        isSearching = false
        isTargetedRetry = false

        let folderErrors = wasTargeted ? [] : readyFolders.compactMap { folderCursors[$0.id]?.lastError }
        if wasTargeted {
            statusMessage = "다시 시도 종료: 완료 \(counters.completedCount)개, 실패 \(counters.failedCount)개, 건너뜀 \(counters.skippedCount)개"
        } else if !folderErrors.isEmpty {
            statusMessage = "변환 완료 (일부 폴더 오류 발생: \(folderErrors.first ?? "")) - 처리 \(counters.handledCount)개"
        } else if counters.failedCount > 0 {
            statusMessage = "변환 종료: 완료 \(counters.completedCount)개, 실패 \(counters.failedCount)개, 건너뜀 \(counters.skippedCount)개"
        } else if counters.handledCount > 0 {
            statusMessage = counters.skippedCount > 0
                ? "변환 처리 종료: 완료 \(counters.completedCount)개, 실패 0개, 건너뜀 \(counters.skippedCount)개 (건너뛴 항목은 원본 유지, 기록에서 사유 확인)"
                : "모든 변환 작업 완료 (완료 \(counters.completedCount)개, 실패 0개, 건너뜀 0개)"
        } else {
            statusMessage = "변환 대상 파일을 찾지 못했습니다."
        }
        updateQueueSummary()
        let directDone = onDirectWorkCompleted
        onDirectWorkCompleted = nil
        directDone?()
    }

    // MARK: - History & UI Updates

    private func pruneRecentItems() {
        var completedCount = 0
        var filtered: [LocalConversionItem] = []
        for item in recentItems {
            if item.stage == .completed {
                completedCount += 1
                if completedCount <= 500 {
                    filtered.append(item)
                }
            } else {
                filtered.append(item)
            }
        }
        recentItems = filtered
    }

    private func appendRecentItem(_ item: LocalConversionItem) {
        if let idx = recentItems.firstIndex(where: { $0.id == item.id }) {
            recentItems[idx] = item
        } else {
            recentItems.insert(item, at: 0)
        }
        pruneRecentItems()
        persistIfTerminal(item)
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
            persistIfTerminal(recentItems[idx])
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

    // MARK: - Diagnostics Export

    /// Pasteable plain-text diagnostics. Reads only in-memory state, the persisted history records and executable
    /// existence; it never scans folders or touches the network. File names are shown without their folders, absolute
    /// user locations inside reasons are masked, and no bookmark, URL or credential is ever included.
    func buildDiagnosticReport() async -> String {
        // Every persisted record (failed/skipped are never capped) plus live state; live state wins per record.
        let persisted: [LocalConversionItem] = await withCheckedContinuation { continuation in
            LocalConversionHistoryStore.shared.load { outcome in
                continuation.resume(returning: outcome.items)
            }
        }
        var merged: [UUID: LocalConversionItem] = [:]
        for item in persisted { merged[item.id] = item }
        for item in recentItems { merged[item.id] = item }
        let records = merged.values
            .filter { $0.stage.isFailed || $0.stage.isSkipped }
            .sorted { $0.addedDate > $1.addedDate }

        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "알 수 없음"
        let build = info["CFBundleVersion"] as? String ?? "알 수 없음"
        let stamp = info["BuildStamp"] as? String ?? "알 수 없음"
        let environment = NASToolEnvironment.detect()

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = .current
        dateFormatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("=== NasFinder Super Thumbnail 진단 내용 ===")
        lines.append("생성 시각: \(dateFormatter.string(from: Date()))")
        lines.append("앱 버전: \(version) (빌드 \(build), 표시 \(stamp))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString) · 실행 아키텍처: \(NASDiagnosticRedaction.machineArchitecture) · 앱 빌드 아키텍처: \(NASToolEnvironment.compiledArchitecture)")
        lines.append("")
        lines.append("[변환 도구]")
        lines.append(contentsOf: environment.diagnosticReportLines)
        if !environment.isReadyToExecute {
            lines.append("안내: \(environment.diagnosticMessage)")
        }
        lines.append("")
        lines.append("[현재 상태]")
        lines.append("상태 문구: \(NASDiagnosticRedaction.redact(statusMessage))")
        if let notice = recoveryNotice {
            lines.append("안내 문구: \(NASDiagnosticRedaction.redact(notice))")
        }
        if !recoveryDetails.isEmpty {
            lines.append("[중단 작업 복구 상세 \(recoveryDetails.count)건]")
            lines.append(contentsOf: recoveryDetails.map(NASDiagnosticRedaction.redact))
        }
        lines.append("실행 중: \(isRunning ? "예" : "아니오") · 일시정지: \(isPaused ? "예" : "아니오") · 동시 변환 설정: \(maxConcurrentConversions)")
        lines.append("카운터: 발견 \(counters.discoveredCount) · 완료 \(counters.completedCount) · 실패 \(counters.failedCount) · 건너뜀 \(counters.skippedCount) · 진행 중 \(counters.inProgressCount)")
        let readyCount = folders.filter { $0.status.isReady }.count
        lines.append("선택 폴더: \(folders.count)개 (사용 가능 \(readyCount)개)")
        for (index, folder) in folders.enumerated() {
            lines.append("  폴더 \(index + 1): \(NASDiagnosticRedaction.redact(folder.status.userMessage))")
        }
        if let notice = historyLoadNotice {
            lines.append("기록 읽기 안내: \(NASDiagnosticRedaction.redact(notice))")
        }
        if let notice = historySaveNotice {
            lines.append("기록 저장 안내: \(NASDiagnosticRedaction.redact(notice))")
        }
        lines.append("")
        let failedTotal = records.filter { $0.stage.isFailed }.count
        lines.append("[실패·건너뜀 기록 전체 \(records.count)건 (실패 \(failedTotal) · 건너뜀 \(records.count - failedTotal)), 최신순]")
        if records.isEmpty {
            lines.append("기록 없음")
        }
        for item in records {
            let reason = item.stage.detailText ?? item.statusMessage
            lines.append("\(dateFormatter.string(from: item.addedDate)) | \(item.stage.shortBadge) | \(item.fileName) | \(NASDiagnosticRedaction.redact(reason))")
        }
        return lines.joined(separator: "\n")
    }
}
