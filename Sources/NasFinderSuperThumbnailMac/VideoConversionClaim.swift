import CryptoKit
import Darwin
import Foundation

// MARK: - Video Claim Error

enum VideoClaimError: LocalizedError, Equatable {
    case containerCreationFailed(Int32)
    case containerOpenFailed(Int32)
    case claimAlreadyExists
    case claimAcquisitionFailed(Int32)
    case claimOpenFailed(Int32)
    case ownerSerializationFailed
    case ownerWriteFailed(Int32)
    case heartbeatWriteFailed(Int32)
    case claimVerificationFailed(String)
    case claimDirectoryMissingOrReplaced
    case invalidSourceIdentity
    case parentVerificationFailed

    var errorDescription: String? {
        switch self {
        case .containerCreationFailed(let code):
            return "클레임 상위 컨테이너 생성 실패 (errno \(code))"
        case .containerOpenFailed(let code):
            return "클레임 상위 컨테이너 열기 실패 (errno \(code))"
        case .claimAlreadyExists:
            return "다른 작업에서 이미 변환 소유권을 보유하고 있습니다 (EEXIST)."
        case .claimAcquisitionFailed(let code):
            return "원자적 클레임 획득 실패 (errno \(code))"
        case .claimOpenFailed(let code):
            return "클레임 디렉터리 디스크립터 열기 실패 (errno \(code))"
        case .ownerSerializationFailed:
            return "소유권 JSON 직렬화 실패"
        case .ownerWriteFailed(let code):
            return "소유권 파일 기록 실패 (errno \(code))"
        case .heartbeatWriteFailed(let code):
            return "하트비트 기록 실패 (errno \(code))"
        case .claimVerificationFailed(let reason):
            return "클레임 검증 실패: \(reason)"
        case .claimDirectoryMissingOrReplaced:
            return "클레임 디렉터리 항목이 유실되었거나 교체되었습니다."
        case .invalidSourceIdentity:
            return "원본 파일 식별 정보 검증 실패"
        case .parentVerificationFailed:
            return "상위 디렉터리 격리 검증 실패"
        }
    }
}

// MARK: - Video Claim Schemas

struct VideoClaimOwnerRecord: Codable, Equatable, Sendable {
    let schema: Int
    let operation: String
    let owner_id: String
    let owner_kind: String
    let token: String
    let source_name: String
    let output_name: String
    let backup_name: String
    let started_at_ms: Int64
    let source_fp: SourceFP

    struct SourceFP: Codable, Equatable, Sendable {
        let size: Int64
        let mtime_ns: Int64
        let dev: Int64
        let ino: UInt64
    }
}

struct VideoClaimHeartbeatRecord: Codable, Equatable, Sendable {
    let token: String
    let heartbeat_at_ms: Int64
    let seq: Int
    let phase: String
}

// MARK: - Video Conversion Claim Handle

/// Shared active-only per-output video claim handle conforming to NAS+Mac architecture.
///
/// Contract rules:
/// - Container: Source parent/.NasFinder-Video-v1/<key>.claim/
/// - Key: lowercase SHA256 hex of UTF8('video-mp4-v1\n' + NFC(final MP4 filename)) with exact single LF delimiter.
/// - Atomic POSIX mkdirat returns 0 only acquisition; EEXIST / I/O error means busy, never steal/delete.
/// - Immutable owner-<token>.json with schema:1, operation:'video-mp4-v1', stable device UUID, owner_kind:'mac'.
/// - Mutable hb-<token>.json with seq, phase, display-only, no automatic takeover, single atomic overwrite.
/// - Verify owned token/name and directory entry before MP4 publication and before original deletion; missing/replaced stops the transaction.
/// - Release only own exact hb/owner files after verified completion, or after cancel/failure BEFORE output publication.
///   The claim is held until the final outcome (MP4 + thumbnail verified + original deleted) or retained as evidence.
/// - rmdir only empty owned claim, never recursive deletion.
/// - If I/O/commit state uncertain, retain claim plus existing recovery evidence.
/// - `backup_name` stays in the shared owner record for cross-platform key identity only;
///   the Mac flow never creates that `_원본` entry.
final class VideoConversionClaim: @unchecked Sendable {
    static let containerDirName = ".NasFinder-Video-v1"
    private static let deviceUUIDDefaultsKey = "LocalConversion.deviceUUID.v1"

    let key: String
    let claimDirName: String
    let token: String
    let ownerID: String
    let sourceName: String
    let outputName: String
    let backupName: String
    let startedAtMs: Int64
    let sourceFP: VideoClaimOwnerRecord.SourceFP

    private let parentFD: Int32
    private var containerFD: Int32
    private var claimFD: Int32
    private let containerStatDev: dev_t
    private let containerStatIno: ino_t
    private let claimStatDev: dev_t
    private let claimStatIno: ino_t

    private let stateLock = NSLock()
    private let ioLock = NSLock()

    private var isHeartbeatRunning = false
    private var isStoppingOrStopped = false
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatSeq = 0
    private var currentPhase: String = "preparing"
    private var sourceMutationStarted = false
    private var isReleased = false
    private(set) var cleanupNotice: String? = nil

    // MARK: - Key Derivation

    /// Computes key=lowercase SHA256 hex of UTF8('video-mp4-v1\n' + NFC(final MP4 filename))
    static func computeKey(finalMP4FileName: String) -> String {
        let nfcName = finalMP4FileName.precomposedStringWithCanonicalMapping
        let payload = "video-mp4-v1\n" + nfcName
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Obtains a stable device UUID persisted in app preferences.
    static func stableDeviceUUID() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceUUIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: deviceUUIDDefaultsKey)
        return fresh
    }

    // MARK: - Acquisition

    /// Atomically acquires an active video claim descriptor-relatively from the opened parent directory descriptor.
    /// Returns a valid claim handle on success, or throws on collision (EEXIST) / failure.
    static func acquire(
        parentFD: Int32,
        sourceName: String,
        outputName: String,
        backupName: String,
        sourceIdentity: LocalFileIdentity
    ) throws -> VideoConversionClaim {
        let key = computeKey(finalMP4FileName: outputName)
        let claimDirName = "\(key).claim"

        // 1. Ensure hidden root container .NasFinder-Video-v1 exists under parentFD
        if mkdirat(parentFD, containerDirName, 0o755) != 0 {
            let err = errno
            if err != EEXIST {
                throw VideoClaimError.containerCreationFailed(err)
            }
        }

        // Open container with O_NOFOLLOW | O_DIRECTORY
        let containerFD = openat(parentFD, containerDirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard containerFD >= 0 else {
            let err = errno
            throw VideoClaimError.containerOpenFailed(err)
        }

        var containerStat = stat()
        guard fstat(containerFD, &containerStat) == 0,
              (containerStat.st_mode & S_IFMT) == S_IFDIR else {
            let err = errno
            Darwin.close(containerFD)
            throw VideoClaimError.containerOpenFailed(err)
        }

        // 2. Atomic acquisition via POSIX mkdirat: returns 0 only on true exclusive creation
        if mkdirat(containerFD, claimDirName, 0o755) != 0 {
            let err = errno
            Darwin.close(containerFD)
            if err == EEXIST {
                throw VideoClaimError.claimAlreadyExists
            } else {
                throw VideoClaimError.claimAcquisitionFailed(err)
            }
        }

        // 3. Open newly created claim directory descriptor
        let claimFD = openat(containerFD, claimDirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard claimFD >= 0 else {
            let err = errno
            _ = unlinkat(containerFD, claimDirName, AT_REMOVEDIR)
            Darwin.close(containerFD)
            throw VideoClaimError.claimOpenFailed(err)
        }

        var dirStat = stat()
        guard fstat(claimFD, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            let err = errno
            Darwin.close(claimFD)
            _ = unlinkat(containerFD, claimDirName, AT_REMOVEDIR)
            Darwin.close(containerFD)
            throw VideoClaimError.claimOpenFailed(err)
        }

        let token = UUID().uuidString.lowercased()
        let ownerID = stableDeviceUUID()
        let startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sourceFP = VideoClaimOwnerRecord.SourceFP(
            size: sourceIdentity.size,
            mtime_ns: sourceIdentity.mtimeNanoseconds,
            dev: Int64(sourceIdentity.device),
            ino: UInt64(sourceIdentity.inode)
        )

        let claim = VideoConversionClaim(
            key: key,
            claimDirName: claimDirName,
            token: token,
            ownerID: ownerID,
            sourceName: sourceName,
            outputName: outputName,
            backupName: backupName,
            startedAtMs: startedAtMs,
            sourceFP: sourceFP,
            parentFD: parentFD,
            containerFD: containerFD,
            claimFD: claimFD,
            containerStatDev: containerStat.st_dev,
            containerStatIno: containerStat.st_ino,
            claimStatDev: dirStat.st_dev,
            claimStatIno: dirStat.st_ino
        )

        // 4. Write immutable owner-<token>.json
        do {
            try claim.writeOwnerRecord()
            try claim.writeHeartbeat(phase: "preparing")
        } catch {
            claim.releaseBeforeMutation()
            throw error
        }

        claim.startHeartbeatLoop()
        return claim
    }

    private init(
        key: String,
        claimDirName: String,
        token: String,
        ownerID: String,
        sourceName: String,
        outputName: String,
        backupName: String,
        startedAtMs: Int64,
        sourceFP: VideoClaimOwnerRecord.SourceFP,
        parentFD: Int32,
        containerFD: Int32,
        claimFD: Int32,
        containerStatDev: dev_t,
        containerStatIno: ino_t,
        claimStatDev: dev_t,
        claimStatIno: ino_t
    ) {
        self.key = key
        self.claimDirName = claimDirName
        self.token = token
        self.ownerID = ownerID
        self.sourceName = sourceName
        self.outputName = outputName
        self.backupName = backupName
        self.startedAtMs = startedAtMs
        self.sourceFP = sourceFP
        self.parentFD = parentFD
        self.containerFD = containerFD
        self.claimFD = claimFD
        self.containerStatDev = containerStatDev
        self.containerStatIno = containerStatIno
        self.claimStatDev = claimStatDev
        self.claimStatIno = claimStatIno
    }

    // MARK: - Immutable Owner Record Write

    private func writeOwnerRecord() throws {
        let record = VideoClaimOwnerRecord(
            schema: 1,
            operation: "video-mp4-v1",
            owner_id: ownerID,
            owner_kind: "mac",
            token: token,
            source_name: sourceName,
            output_name: outputName,
            backup_name: backupName,
            started_at_ms: startedAtMs,
            source_fp: sourceFP
        )

        guard let data = try? JSONEncoder().encode(record) else {
            throw VideoClaimError.ownerSerializationFailed
        }

        let fileName = "owner-\(token).json"
        let fd = openat(claimFD, fileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let err = errno
            throw VideoClaimError.ownerWriteFailed(err)
        }

        var written = 0
        let writeError: Error? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            while written < raw.count {
                let res = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if res <= 0 {
                    let err = errno
                    return VideoClaimError.ownerWriteFailed(err)
                }
                written += res
            }
            return nil
        }

        if let writeError {
            Darwin.close(fd)
            unlinkat(claimFD, fileName, 0)
            throw writeError
        }

        if fsync(fd) != 0 {
            let err = errno
            Darwin.close(fd)
            unlinkat(claimFD, fileName, 0)
            throw VideoClaimError.ownerWriteFailed(err)
        }
        Darwin.close(fd)

        if fsync(claimFD) != 0 {
            let err = errno
            unlinkat(claimFD, fileName, 0)
            throw VideoClaimError.ownerWriteFailed(err)
        }
    }

    // MARK: - Mutable Heartbeat

    func updatePhase(_ phase: String) {
        stateLock.lock()
        currentPhase = phase
        let stopped = isStoppingOrStopped || isReleased
        stateLock.unlock()
        guard !stopped else { return }
        try? writeHeartbeat(phase: phase)
    }

    private func writeHeartbeat(phase: String) throws {
        stateLock.lock()
        if isStoppingOrStopped || isReleased {
            stateLock.unlock()
            return
        }
        heartbeatSeq += 1
        let seq = heartbeatSeq
        stateLock.unlock()

        ioLock.lock()
        defer { ioLock.unlock() }

        stateLock.lock()
        let stopped = isStoppingOrStopped || isReleased
        stateLock.unlock()
        if stopped || claimFD < 0 {
            return
        }

        let record = VideoClaimHeartbeatRecord(
            token: token,
            heartbeat_at_ms: Int64(Date().timeIntervalSince1970 * 1000),
            seq: seq,
            phase: phase
        )

        guard let data = try? JSONEncoder().encode(record) else {
            return
        }

        let tmpName = "hb-\(token).json.tmp"
        let finalName = "hb-\(token).json"

        _ = unlinkat(claimFD, tmpName, 0)

        let fd = openat(claimFD, tmpName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let err = errno
            throw VideoClaimError.heartbeatWriteFailed(err)
        }

        var written = 0
        let writeError: Error? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            while written < raw.count {
                let res = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if res <= 0 {
                    let err = errno
                    return VideoClaimError.heartbeatWriteFailed(err)
                }
                written += res
            }
            return nil
        }

        if let writeError {
            Darwin.close(fd)
            unlinkat(claimFD, tmpName, 0)
            throw writeError
        }

        if fsync(fd) != 0 {
            let err = errno
            Darwin.close(fd)
            unlinkat(claimFD, tmpName, 0)
            throw VideoClaimError.heartbeatWriteFailed(err)
        }
        Darwin.close(fd)

        if renameatx_np(claimFD, tmpName, claimFD, finalName, 0) != 0 {
            let err = errno
            unlinkat(claimFD, tmpName, 0)
            throw VideoClaimError.heartbeatWriteFailed(err)
        }

        _ = fsync(claimFD)
    }

    private func startHeartbeatLoop() {
        stateLock.lock()
        guard !isHeartbeatRunning, !isStoppingOrStopped, !isReleased else {
            stateLock.unlock()
            return
        }
        isHeartbeatRunning = true
        stateLock.unlock()

        heartbeatTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // ~10 seconds
                guard !Task.isCancelled, let self else { break }

                self.stateLock.lock()
                let phase = self.currentPhase
                let running = self.isHeartbeatRunning && !self.isStoppingOrStopped && !self.isReleased
                self.stateLock.unlock()

                guard running else { break }
                try? self.writeHeartbeat(phase: phase)
            }
        }
    }

    func stopHeartbeat() {
        stateLock.lock()
        isStoppingOrStopped = true
        isHeartbeatRunning = false
        let task = heartbeatTask
        heartbeatTask = nil
        stateLock.unlock()

        task?.cancel()
    }

    // MARK: - Publication Verification

    /// Verifies owned token/name, container identity, and the current claim directory entry identity
    /// before source preservation and output commit.
    /// A missing/replaced/unreadable claim stops publication.
    func verifyClaimBeforePublication() throws {
        ioLock.lock()
        defer { ioLock.unlock() }

        // 1. Verify parent -> container entry still exists in parentFD and matches original inode/device and is directory
        var parentContainerStat = stat()
        guard fstatat(parentFD, Self.containerDirName, &parentContainerStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VideoClaimError.parentVerificationFailed
        }
        guard (parentContainerStat.st_mode & S_IFMT) == S_IFDIR,
              parentContainerStat.st_dev == containerStatDev,
              parentContainerStat.st_ino == containerStatIno else {
            throw VideoClaimError.parentVerificationFailed
        }

        var openContainerStat = stat()
        guard fstat(containerFD, &openContainerStat) == 0,
              (openContainerStat.st_mode & S_IFMT) == S_IFDIR,
              openContainerStat.st_dev == containerStatDev,
              openContainerStat.st_ino == containerStatIno else {
            throw VideoClaimError.parentVerificationFailed
        }

        // 2. Verify container -> claim directory entry still exists in containerFD and matches original inode/device and is directory
        var currentClaimStat = stat()
        guard fstatat(containerFD, claimDirName, &currentClaimStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw VideoClaimError.claimDirectoryMissingOrReplaced
        }
        guard (currentClaimStat.st_mode & S_IFMT) == S_IFDIR,
              currentClaimStat.st_dev == claimStatDev,
              currentClaimStat.st_ino == claimStatIno else {
            throw VideoClaimError.claimDirectoryMissingOrReplaced
        }

        var openClaimStat = stat()
        guard fstat(claimFD, &openClaimStat) == 0,
              (openClaimStat.st_mode & S_IFMT) == S_IFDIR,
              openClaimStat.st_dev == claimStatDev,
              openClaimStat.st_ino == claimStatIno else {
            throw VideoClaimError.claimDirectoryMissingOrReplaced
        }

        // 3. Bounded directory inspection only of tiny claim directory (no folder scan)
        let dupFD = dup(claimFD)
        guard dupFD >= 0 else {
            throw VideoClaimError.claimVerificationFailed("클레임 디스크립터 복제 실패")
        }
        guard let dirStream = fdopendir(dupFD) else {
            Darwin.close(dupFD)
            throw VideoClaimError.claimVerificationFailed("클레임 디렉터리 스트림 열기 실패")
        }
        defer { closedir(dirStream) }
        // dup()된 FD는 claimFD와 파일 오프셋을 공유하므로, 이전 검증이 소비한 스트림이 EOF로 보이지 않게 처음부터 읽는다.
        rewinddir(dirStream)

        var ownerFileNames: [String] = []
        var totalEntries = 0
        let maxEntries = 32

        while let entry = readdir(dirStream) {
            totalEntries += 1
            if totalEntries > maxEntries {
                throw VideoClaimError.claimVerificationFailed("클레임 디렉터리 항목 수 한도 초과")
            }

            let entryName = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
                return String(cString: base)
            }

            if entryName == "." || entryName == ".." {
                continue
            }

            if entryName.hasPrefix("owner-") && entryName.hasSuffix(".json") {
                ownerFileNames.append(entryName)
            } else if entryName.hasPrefix("hb-") {
                continue
            } else {
                throw VideoClaimError.claimVerificationFailed("클레임 디렉터리 내 예기치 않은 항목 발견: \(entryName)")
            }
        }

        guard ownerFileNames.count == 1, ownerFileNames.first == "owner-\(token).json" else {
            throw VideoClaimError.claimVerificationFailed("단일 소유자 파일 불일치 (발견된 항목: \(ownerFileNames))")
        }

        // 4. Verify owner file is bounded regular file and matches exact schema, operation, owner_kind, token/names/source_fp
        let ownerFileName = "owner-\(token).json"
        let fd = openat(claimFD, ownerFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw VideoClaimError.claimVerificationFailed("소유권 파일 열기 실패: \(ownerFileName)")
        }
        defer { Darwin.close(fd) }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw VideoClaimError.claimVerificationFailed("소유권 파일 상태 확인 실패")
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_nlink == 1,
              fileStat.st_size > 0,
              fileStat.st_size <= 65536 else {
            throw VideoClaimError.claimVerificationFailed("소유권 파일이 유효한 단일 링크 일반 파일(<=64KB)이 아닙니다.")
        }

        let count = Int(fileStat.st_size)
        var buffer = [UInt8](repeating: 0, count: count)
        var readBytes = 0
        while readBytes < count {
            let res = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: readBytes), count - readBytes)
            }
            if res <= 0 {
                throw VideoClaimError.claimVerificationFailed("소유권 파일 읽기 실패")
            }
            readBytes += res
        }

        guard let record = try? JSONDecoder().decode(VideoClaimOwnerRecord.self, from: Data(buffer)) else {
            throw VideoClaimError.claimVerificationFailed("소유권 파일 JSON 파싱 실패")
        }

        guard record.schema == 1,
              record.operation == "video-mp4-v1",
              record.owner_kind == "mac",
              record.token == token,
              record.owner_id == ownerID,
              record.source_name == sourceName,
              record.output_name == outputName,
              record.backup_name == backupName,
              record.source_fp.size == sourceFP.size,
              record.source_fp.mtime_ns == sourceFP.mtime_ns,
              record.source_fp.dev == sourceFP.dev,
              record.source_fp.ino == sourceFP.ino else {
            throw VideoClaimError.claimVerificationFailed("소유권 레코드 필수 필드(schema, operation, owner_kind, token, names, source_fp) 불일치")
        }
    }

    /// Same verification before irreversible original deletion (claim ownership, container and claim entry identity).
    func verifyClaimBeforeSourceDeletion() throws {
        try verifyClaimBeforePublication()
    }

    /// Mark that the irreversible phase (final MP4 publication, then original deletion) has started.
    /// After this point, the claim is NOT released on failure or cancel so recovery evidence is safely retained.
    func markSourceMutationStarted() {
        stateLock.lock()
        sourceMutationStarted = true
        stateLock.unlock()
    }

    /// Resets the mutation flag under stateLock ONLY when the failed MP4 publication rename is positively
    /// known not to have happened (staging entry still present) and the source is unchanged.
    func resetSourceMutationStarted() {
        stateLock.lock()
        sourceMutationStarted = false
        stateLock.unlock()
    }

    // MARK: - Safe Release

    /// Releases own exact hb and owner files and rmdir's the empty claim directory.
    /// Called only after verified success, or cancel/failure BEFORE output publication.
    @discardableResult
    func release(success: Bool) -> String? {
        stopHeartbeat()

        ioLock.lock()
        defer { ioLock.unlock() }

        stateLock.lock()
        if isReleased {
            let notice = cleanupNotice
            stateLock.unlock()
            return notice
        }
        isReleased = true
        let mutationStarted = sourceMutationStarted
        stateLock.unlock()

        if !success && mutationStarted {
            // Output publication / original deletion began or I/O state uncertain: retain claim + recovery evidence
            let notice = "MP4 발행 이후 작업 중단: 소유권 및 복구 증적 보존됨"
            stateLock.lock()
            cleanupNotice = notice
            stateLock.unlock()
            closeDescriptors()
            return notice
        }

        // Before cleanup, verify path containment and ownership: do not cleanup another owner's path
        var parentContainerStat = stat()
        let pcOk = fstatat(parentFD, Self.containerDirName, &parentContainerStat, AT_SYMLINK_NOFOLLOW) == 0
        var currentClaimStat = stat()
        let ccOk = fstatat(containerFD, claimDirName, &currentClaimStat, AT_SYMLINK_NOFOLLOW) == 0

        guard pcOk, (parentContainerStat.st_mode & S_IFMT) == S_IFDIR,
              parentContainerStat.st_dev == containerStatDev,
              parentContainerStat.st_ino == containerStatIno,
              ccOk, (currentClaimStat.st_mode & S_IFMT) == S_IFDIR,
              currentClaimStat.st_dev == claimStatDev,
              currentClaimStat.st_ino == claimStatIno else {
            let notice = "클레임 상위 경로 변경 감지: 다른 소유자 보호를 위해 정리 중단 및 증적 유지"
            stateLock.lock()
            cleanupNotice = notice
            stateLock.unlock()
            closeDescriptors()
            return notice
        }

        // Clean up own files
        let hbTmpRes = unlinkat(claimFD, "hb-\(token).json.tmp", 0)
        let hbTmpErr = errno
        let hbTmpOk = (hbTmpRes == 0 || hbTmpErr == ENOENT)

        let hbRes = unlinkat(claimFD, "hb-\(token).json", 0)
        let hbErr = errno
        let hbOk = (hbRes == 0 || hbErr == ENOENT)

        guard hbTmpOk && hbOk else {
            let notice = "하트비트 파일 정리 미완료 (hbTmpErr=\(hbTmpErr), hbErr=\(hbErr)): 소유권 및 증적 파일 보존됨"
            stateLock.lock()
            cleanupNotice = notice
            stateLock.unlock()
            closeDescriptors()
            return notice
        }

        let ownerRes = unlinkat(claimFD, "owner-\(token).json", 0)
        let ownerErr = errno
        let ownerOk = (ownerRes == 0 || ownerErr == ENOENT)
        _ = fsync(claimFD)

        guard ownerOk else {
            let notice = "소유권 파일 정리 미완료 (errno=\(ownerErr)): 증적 파일 보존됨"
            stateLock.lock()
            cleanupNotice = notice
            stateLock.unlock()
            closeDescriptors()
            return notice
        }

        let rmdirRes = unlinkat(containerFD, claimDirName, AT_REMOVEDIR)
        let rmdirErr = errno
        let rmdirOk = (rmdirRes == 0 || rmdirErr == ENOENT)
        _ = fsync(containerFD)

        closeDescriptors()

        guard rmdirOk else {
            let notice = "클레임 디렉터리 정리 미완료 (errno=\(rmdirErr)): 디렉터리 보존됨"
            stateLock.lock()
            cleanupNotice = notice
            stateLock.unlock()
            return notice
        }

        return nil
    }

    func releaseBeforeMutation() {
        _ = release(success: false)
    }

    private func closeDescriptors() {
        if claimFD >= 0 {
            Darwin.close(claimFD)
            claimFD = -1
        }
        if containerFD >= 0 {
            Darwin.close(containerFD)
            containerFD = -1
        }
    }

    deinit {
        _ = release(success: false)
    }
}
