import AppKit
import CryptoKit
import Darwin
import Foundation

// MARK: - Device-Local Kernel Exclusion

/// One held lease on the device-local exclusion file. Dropping the descriptor releases the kernel lock.
final class LocalExclusionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    private let exclusive: Bool

    fileprivate init(fd: Int32, exclusive: Bool) {
        self.fd = fd
        self.exclusive = exclusive
    }

    func release() {
        lock.lock()
        let old = fd
        fd = -1
        lock.unlock()
        guard old >= 0 else { return }
        _ = flock(old, LOCK_UN)
        Darwin.close(old)
        LocalRecoveryExclusion.shared.leaseReleased(exclusive: exclusive)
    }

    deinit {
        release()
    }
}

/// Kernel `flock` on a file in Application Support (a local disk, never the shared folder), combined with
/// in-process bookkeeping done under one mutex so that "check" and "acquire" are a single atomic step.
/// - Every conversion worker holds a SHARED lease for its whole lifecycle.
/// - Recovery holds the EXCLUSIVE lease until it is completely finished (cancellation does not release it early).
/// Separate open file descriptions conflict even inside one process, so the kernel arbitrates both
/// between threads and between app instances that use this lock.
final class LocalRecoveryExclusion: @unchecked Sendable {
    static let shared = LocalRecoveryExclusion()

    private let lock = NSLock()
    private var sharedCount = 0
    private var exclusiveActive = false

    private init() {}

    var isExclusive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exclusiveActive
    }

    private static func openLockFile() -> Int32 {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return -1
        }
        let dir = base.appendingPathComponent("NasFinderSuperThumbnailMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("local-conversion.lock").path
        return Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }

    /// Worker lease. Returns nil when a recovery is running (in this process or any lock-aware process).
    func acquireShared() -> LocalExclusionLease? {
        lock.lock()
        defer { lock.unlock() }
        guard !exclusiveActive else { return nil }
        let fd = Self.openLockFile()
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        sharedCount += 1
        return LocalExclusionLease(fd: fd, exclusive: false)
    }

    /// Recovery lease. Returns nil when any worker or another recovery holds a lease.
    func acquireExclusive() -> LocalExclusionLease? {
        lock.lock()
        defer { lock.unlock() }
        guard !exclusiveActive, sharedCount == 0 else { return nil }
        let fd = Self.openLockFile()
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return nil
        }
        exclusiveActive = true
        return LocalExclusionLease(fd: fd, exclusive: true)
    }

    fileprivate func leaseReleased(exclusive: Bool) {
        lock.lock()
        if exclusive {
            exclusiveActive = false
        } else {
            sharedCount = max(0, sharedCount - 1)
        }
        lock.unlock()
    }
}

// MARK: - Other-Instance (legacy build) Guard

/// Builds before this lock existed never take the lease, so the lease alone cannot prove that no other
/// copy of the app is working. Any other process running this app's executable keeps recovery blocked.
enum LocalLegacyProcessGuard {
    /// nil: no other instance found. Otherwise the reason recovery must not run (live or unknown state).
    static func blockingReason() -> String? {
        let ownPID = getpid()
        let ownName = Bundle.main.executableURL?.lastPathComponent ?? ProcessInfo.processInfo.processName

        if let bundleID = Bundle.main.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.processIdentifier != ownPID {
                return "다른 SuperThumbnail 앱이 실행 중입니다 (pid \(app.processIdentifier)). 모두 종료한 뒤 다시 시도해 주세요."
            }
        }

        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else {
            return "실행 중인 프로세스 목록을 확인할 수 없어 안전을 위해 정리하지 않았습니다."
        }
        var pids = [pid_t](repeating: 0, count: Int(needed) + 128)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else {
            return "실행 중인 프로세스 목록을 읽지 못해 안전을 위해 정리하지 않았습니다."
        }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids where pid > 0 && pid != ownPID {
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard length > 0 else { continue }
            let path = String(cString: pathBuffer)
            if (path as NSString).lastPathComponent == ownName {
                return "같은 앱(\(ownName))의 다른 실행이 있습니다 (pid \(pid)). 이전 버전일 수 있어 안전을 위해 정리하지 않았습니다."
            }
        }
        return nil
    }
}

// MARK: - Recovery Result

struct LocalConversionRecoveryResult: Sendable {
    enum ProtectCategory: Sendable {
        case active, originalAbsent, mp4Present, foreignDevice, other
    }

    static let maxDetailLines = 300

    var recoveredClaimCount: Int = 0
    /// 삭제하지 않고 보관 이름으로 옮겨 둔 자기 작업 표시. 정리(recovered)와 따로 센다.
    var archivedSourceChangedCount: Int = 0
    var archivedPublishedCount: Int = 0
    /// 발행된 MP4와 기록이 모두 검증되어, 원본·MP4를 건드리지 않고 썸네일 확인만 이어서 진행하도록 넘긴 개수.
    var archivedResumeCount: Int = 0
    var archivedDetails: [String] = []
    var protectedClaimCount: Int = 0
    var protectedActiveCount: Int = 0
    var protectedOriginalAbsentCount: Int = 0
    var protectedMP4PresentCount: Int = 0
    var protectedForeignDeviceCount: Int = 0
    var folderErrorCount: Int = 0
    var blockedReason: String? = nil
    var protectedDetails: [String] = []
    var errorDetails: [String] = []
    var recoveredCandidates: [LocalDiscoveredFile] = []

    var detailLines: [String] { errorDetails + archivedDetails + protectedDetails }

    mutating func protect(_ name: String, _ reason: String, category: ProtectCategory = .other) {
        protectedClaimCount += 1
        switch category {
        case .active: protectedActiveCount += 1
        case .originalAbsent: protectedOriginalAbsentCount += 1
        case .mp4Present: protectedMP4PresentCount += 1
        case .foreignDevice: protectedForeignDeviceCount += 1
        case .other: break
        }
        if protectedDetails.count < Self.maxDetailLines {
            protectedDetails.append("[보존] \(name): \(reason)")
        }
    }

    mutating func archive(_ name: String, _ archived: RecoveryArchived) {
        switch archived.kind {
        case .sourceTimestampChanged: archivedSourceChangedCount += 1
        case .publishedOutputKept: archivedPublishedCount += 1
        case .publishedOutputResume: archivedResumeCount += 1
        }
        if archivedDetails.count < Self.maxDetailLines {
            archivedDetails.append("[보관] \(name): \(archived.detail)")
        }
    }

    mutating func addError(_ message: String) {
        folderErrorCount += 1
        if errorDetails.count < Self.maxDetailLines {
            errorDetails.append("[폴더 오류] \(message)")
        }
    }

    var summaryMessage: String {
        if let blockedReason {
            return "정리하지 않음: \(blockedReason)"
        }
        // 세부 분류는 상세 기록에서 확인한다. 알림은 짧게 유지한다.
        let protectedText = protectedClaimCount > 0 ? " (건드리지 않고 남겨 둔 표시 \(protectedClaimCount)개)" : ""
        var errorText = folderErrorCount > 0 ? " · 일부 폴더 확인 오류 \(folderErrorCount)건" : ""
        if archivedSourceChangedCount > 0 {
            errorText += " · 원본 시각만 바뀐 중단 표시 \(archivedSourceChangedCount)개는 삭제하지 않고 보관 후 새로 변환 대상으로 넘김"
        }
        if archivedPublishedCount > 0 {
            errorText += " · MP4 보존 · 썸네일/원본 정리 필요 \(archivedPublishedCount)개 (완료 아님, 원본·MP4·기록 그대로 보존)"
        }

        if archivedResumeCount > 0 {
            errorText += " · 발행된 MP4 \(archivedResumeCount)개는 검증 후 원본·MP4를 그대로 두고 썸네일 확인만 이어서 진행 (원본 삭제 안 함)"
        }

        if recoveredClaimCount > 0 {
            return "중단된 작업 표시 \(recoveredClaimCount)개 정리 완료\(protectedText)\(errorText)"
        }
        if protectedClaimCount > 0 || archivedSourceChangedCount + archivedPublishedCount + archivedResumeCount > 0 {
            return "정리한 항목 없음\(protectedText)\(errorText)"
        }
        if folderErrorCount > 0 {
            return "정리할 중단된 작업 표시를 찾지 못함\(errorText)"
        }
        return "정리할 중단된 작업 표시가 없습니다."
    }
}

// MARK: - Safe Local Conversion Recovery

private struct RecoveryProtect: Error {
    let reason: String
    let category: LocalConversionRecoveryResult.ProtectCategory
}

/// 삭제 없이 보관 이름으로 옮긴 자기 작업 표시. 정상 정리(recovered)와 구분한다.
struct RecoveryArchived: Error {
    enum Kind: Sendable {
        case sourceTimestampChanged
        case publishedOutputKept
        case publishedOutputResume
    }

    let kind: Kind
    let detail: String
    let candidate: LocalDiscoveredFile?
}

private enum ArchiveMethod {
    case renamed
    case copiedAndReleased
}

private struct MemberStamp: Equatable {
    let dev: dev_t
    let ino: ino_t
    let size: Int64
    let mtimeSec: Int
    let mtimeNsec: Int
}

private struct NodeID: Equatable {
    let dev: dev_t
    let ino: ino_t
}

private struct FileSnapshot: Equatable {
    let dev: dev_t
    let ino: ino_t
    let size: Int64
    let mtimeSec: Int
    let mtimeNsec: Int
    let bytes: [UInt8]
}

private struct DirEntryInfo {
    let name: String
    let isDirectory: Bool
}

private struct ClaimContext {
    let folder: LocalFolderItem
    let rootFD: Int32
    let components: [String]
    let parentFD: Int32
    let parentID: NodeID
    let parentNames: Set<String>
    let containerFD: Int32
    let containerID: NodeID
}

enum LocalConversionRecovery {
    private static let maxDirectoriesVisited = 20_000
    private static let maxClaimEntries = 34

    /// Own-claim recovery strictly off the MainActor. The caller owns `pins` (duplicated pinned roots) and keeps
    /// them open until this returns. The exclusive device lease is taken and released inside the detached task, so it is
    /// held until the work is really finished even when the awaiting task is cancelled.
    /// `onlyDirectories == nil` walks the whole selected trees (manual recovery). Otherwise ONLY the listed directories
    /// (components relative to each root) are inspected, without queueing any child directory.
    static func performRecovery(
        folders: [LocalFolderItem],
        pins: [UUID: NASPinnedRoot],
        onlyDirectories: [UUID: Set<[String]>]? = nil
    ) async -> LocalConversionRecoveryResult {
        await Task.detached(priority: .userInitiated) { () -> LocalConversionRecoveryResult in
            var result = LocalConversionRecoveryResult()

            guard let lease = LocalRecoveryExclusion.shared.acquireExclusive() else {
                result.blockedReason = "변환 작업이나 다른 정리 작업이 진행 중이어서 시작하지 않았습니다."
                return result
            }
            defer { lease.release() }

            if let reason = LocalLegacyProcessGuard.blockingReason() {
                result.blockedReason = reason
                return result
            }

            for folder in folders where folder.status.isReady {
                guard let pin = pins[folder.id] else {
                    result.addError("\(folder.displayName): 폴더 연결을 열지 못했습니다.")
                    continue
                }
                if let onlyDirectories {
                    scanDirectories(onlyDirectories[folder.id] ?? [], folder: folder, pin: pin, result: &result)
                } else {
                    scanFolder(folder: folder, pin: pin, result: &result)
                }
            }
            return result
        }.value
    }

    // MARK: Small helpers

    private static func fail(_ reason: String, _ category: LocalConversionRecoveryResult.ProtectCategory = .other) -> RecoveryProtect {
        RecoveryProtect(reason: reason, category: category)
    }

    private static func posix(_ err: Int32, _ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "\(what) 실패 (errno \(err))"])
    }

    private static func guarded<T>(_ what: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let protect as RecoveryProtect {
            throw protect
        } catch {
            throw fail("\(what): \(error.localizedDescription)")
        }
    }

    private static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }

    /// Reopens the pinned directory with its own offset, so repeated starts see all entries again.
    /// readdir errors are surfaced, never treated as "end of directory".
    private static func listEntries(of fd: Int32, limit: Int? = nil) throws -> [DirEntryInfo] {
        let dupFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dupFD >= 0 else { throw posix(errno, "디렉터리 복제") }
        var pinned = stat()
        var reopened = stat()
        guard fstat(fd, &pinned) == 0, fstat(dupFD, &reopened) == 0,
              pinned.st_dev == reopened.st_dev, pinned.st_ino == reopened.st_ino else {
            Darwin.close(dupFD)
            throw fail("디렉터리가 다시 여는 사이 바뀌어 확인하지 않음")
        }
        guard let stream = fdopendir(dupFD) else {
            let err = errno
            Darwin.close(dupFD)
            throw posix(err, "디렉터리 열기")
        }
        defer { closedir(stream) }

        var out: [DirEntryInfo] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let err = errno
                if err != 0 { throw posix(err, "디렉터리 읽기") }
                break
            }
            let name = entryName(entry)
            if name == "." || name == ".." || name.isEmpty { continue }
            var isDir = entry.pointee.d_type == UInt8(DT_DIR)
            if entry.pointee.d_type == UInt8(DT_UNKNOWN) {
                var st = stat()
                isDir = fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }
            out.append(DirEntryInfo(name: name, isDirectory: isDir))
            if let limit, out.count > limit {
                throw fail("항목이 너무 많아 확인하지 않음")
            }
        }
        return out
    }

    private static func nodeID(fd: Int32, directory: Bool, _ label: String) throws -> NodeID {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw fail("\(label) 상태 확인 실패 (errno \(errno))") }
        if directory, (st.st_mode & S_IFMT) != S_IFDIR { throw fail("\(label)이(가) 폴더가 아님") }
        return NodeID(dev: st.st_dev, ino: st.st_ino)
    }

    private static func nodeID(at dirFD: Int32, _ name: String, directory: Bool, _ label: String) throws -> NodeID {
        var st = stat()
        guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw fail("\(label) 확인 실패 (errno \(errno))")
        }
        if directory, (st.st_mode & S_IFMT) != S_IFDIR { throw fail("\(label)이(가) 폴더가 아님") }
        return NodeID(dev: st.st_dev, ino: st.st_ino)
    }

    /// Bounded, nonblocking regular-file read with identity bound to its directory entry.
    /// A missing file is reported as nil only for a positive ENOENT and only when `allowMissing`.
    private static func readSnapshot(dirFD: Int32, name: String, label: String, allowMissing: Bool) throws -> FileSnapshot? {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if allowMissing && err == ENOENT { return nil }
            throw fail("\(label) 열기 실패 (errno \(err))")
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw fail("\(label) 상태 확인 실패 (errno \(errno))") }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size > 0, st.st_size <= 65536 else {
            throw fail("\(label) 형식이 올바르지 않음")
        }

        let count = Int(st.st_size)
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("\(label) 읽기 실패 또는 짧게 읽힘") }
            got += n
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw fail("\(label)을(를) 읽는 중 내용이 바뀜") }

        var after = stat()
        guard fstat(fd, &after) == 0,
              after.st_size == st.st_size,
              after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec else {
            throw fail("\(label)을(를) 읽는 중 내용이 바뀜")
        }
        var entry = stat()
        guard fstatat(dirFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_dev == st.st_dev, entry.st_ino == st.st_ino else {
            throw fail("\(label) 항목이 읽는 중 교체됨")
        }
        return FileSnapshot(
            dev: st.st_dev,
            ino: st.st_ino,
            size: Int64(st.st_size),
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNsec: Int(st.st_mtimespec.tv_nsec),
            bytes: buffer
        )
    }

    static func isValidClaimDirName(_ name: String) -> Bool {
        guard name.utf8.count == 70, name.hasSuffix(".claim") else { return false }
        return name.dropLast(6).allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 36 && token == token.lowercased() && UUID(uuidString: token) != nil
    }

    // MARK: Folder traversal

    static func scanFolder(folder: LocalFolderItem, pin: NASPinnedRoot, result: inout LocalConversionRecoveryResult) {
        var queue: [[String]] = [[]]
        var visited = 0

        while !queue.isEmpty {
            let components = queue.removeFirst()
            visited += 1
            if visited > maxDirectoriesVisited {
                result.addError("\(folder.displayName): 하위 폴더가 너무 많아 일부만 확인했습니다.")
                break
            }
            do {
                try pin.withDirectoryFD { rootFD in
                    try scanDirectory(rootFD: rootFD, components: components, folder: folder, queue: &queue, result: &result)
                }
            } catch {
                let location = components.isEmpty ? folder.displayName : "\(folder.displayName)/\(components.joined(separator: "/"))"
                result.addError("\(location): \(error.localizedDescription)")
            }
        }
    }

    /// Targeted mode: each requested directory is inspected once, children are never traversed.
    static func scanDirectories(
        _ directories: Set<[String]>,
        folder: LocalFolderItem,
        pin: NASPinnedRoot,
        result: inout LocalConversionRecoveryResult
    ) {
        for components in directories.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
            var unused: [[String]] = []
            do {
                try pin.withDirectoryFD { rootFD in
                    try scanDirectory(rootFD: rootFD, components: components, folder: folder, queue: &unused, expandChildren: false, result: &result)
                }
            } catch {
                let location = components.isEmpty ? folder.displayName : "\(folder.displayName)/\(components.joined(separator: "/"))"
                result.addError("\(location): \(error.localizedDescription)")
            }
        }
    }

    private static func scanDirectory(
        rootFD: Int32,
        components: [String],
        folder: LocalFolderItem,
        queue: inout [[String]],
        expandChildren: Bool = true,
        result: inout LocalConversionRecoveryResult
    ) throws {
        let dirFD = try NASPinnedFS.openDirectoryChain(rootFD, components, create: false)
        defer { Darwin.close(dirFD) }

        var rootStat = stat()
        var dirStat = stat()
        guard fstat(rootFD, &rootStat) == 0 else { throw posix(errno, "루트 상태 확인") }
        guard fstat(dirFD, &dirStat) == 0 else { throw posix(errno, "폴더 상태 확인") }
        // A different filesystem mounted below the selected root is never entered.
        guard dirStat.st_dev == rootStat.st_dev else { return }

        let entries = try listEntries(of: dirFD)
        let names = Set(entries.map(\.name))

        if names.contains(VideoConversionClaim.containerDirName) {
            let location = components.isEmpty ? folder.displayName : "\(folder.displayName)/\(components.joined(separator: "/"))"
            do {
                try inspectContainer(
                    rootFD: rootFD, components: components, folder: folder,
                    parentFD: dirFD, parentNames: names, location: location, result: &result
                )
            } catch let protect as RecoveryProtect {
                result.addError("\(location): 작업 표시 보관 폴더 확인 중단 - \(protect.reason)")
            } catch {
                result.addError("\(location): 작업 표시 보관 폴더 확인 실패 - \(error.localizedDescription)")
            }
        }

        guard expandChildren else { return }
        var sawSelf = false
        for entry in entries where entry.isDirectory {
            let name = entry.name
            if name.hasPrefix(".") { continue }
            // WebDAV가 폴더를 자기 자신의 하위 항목으로 나열하는 가짜 항목은 제외한다. 실제 하위 폴더는 유지.
            // 루트(components 비어 있음)에서는 선택한 폴더 자신의 이름과 비교한다.
            let selfName = components.last ?? folder.url.lastPathComponent
            if !sawSelf, name == selfName, isPhantomSelf(dirFD: dirFD, dirStat: dirStat, name: name) {
                sawSelf = true
                continue
            }
            if name.contains(LocalConversionConstants.excludedOriginalMarker) { continue }
            if name == LocalConversionConstants.vaultDirName || name == LocalConversionConstants.handoffDirName { continue }
            queue.append(components + [name])
        }
    }

    /// 이름이 현재 폴더와 같은 항목이 현재 폴더 자신(동일 dev/ino)이거나 WebDAV 가짜 자기 항목일 때만 true.
    /// 서로 다른 inode의 실제 하위 폴더는 false.
    private static func isPhantomSelf(dirFD: Int32, dirStat: stat, name: String) -> Bool {
        var st = stat()
        if fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
           (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == dirStat.st_dev, st.st_ino == dirStat.st_ino {
            return true
        }
        // 가짜 자기 항목 판별은 webdav 파일시스템에서만 허용한다.
        var fs = statfs()
        guard fstatfs(dirFD, &fs) == 0 else { return false }
        let fsName = withUnsafeBytes(of: fs.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
        guard fsName == "webdav" else { return false }
        return VideoConversionClaim.isWebDAVPhantomSelfEntry(parentFD: dirFD, name: name)
    }

    /// 빈(0바이트) 자기 토큰 임시 AppleDouble 사이드카(`._hb-<token>.json.tmp`)만 해당한다.
    /// nofollow, 일반 파일, nlink 1, 크기 0이며 열린 파일이 디렉터리 항목과 같은 dev/ino일 때만 그 식별 값을 돌려준다.
    private static func emptyTempSidecarID(dirFD: Int32, name: String) -> NodeID? {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size == 0 else { return nil }
        var entry = stat()
        guard fstatat(dirFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_dev == st.st_dev, entry.st_ino == st.st_ino,
              (entry.st_mode & S_IFMT) == S_IFREG, entry.st_nlink == 1, entry.st_size == 0 else { return nil }
        return NodeID(dev: st.st_dev, ino: st.st_ino)
    }

    private static func inspectContainer(
        rootFD: Int32,
        components: [String],
        folder: LocalFolderItem,
        parentFD: Int32,
        parentNames: Set<String>,
        location: String,
        result: inout LocalConversionRecoveryResult
    ) throws {
        let containerName = VideoConversionClaim.containerDirName
        let entryID = try nodeID(at: parentFD, containerName, directory: true, "작업 표시 보관 폴더")
        let containerFD = openat(parentFD, containerName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard containerFD >= 0 else { throw fail("작업 표시 보관 폴더 열기 실패 (errno \(errno))") }
        defer { Darwin.close(containerFD) }
        let containerID = try nodeID(fd: containerFD, directory: true, "작업 표시 보관 폴더")
        guard containerID == entryID else { throw fail("작업 표시 보관 폴더가 열리는 중 교체됨") }

        let parentID = try nodeID(fd: parentFD, directory: true, "상위 폴더")
        let containerEntries = try listEntries(of: containerFD)

        let context = ClaimContext(
            folder: folder,
            rootFD: rootFD,
            components: components,
            parentFD: parentFD,
            parentID: parentID,
            parentNames: parentNames,
            containerFD: containerFD,
            containerID: containerID
        )

        for entry in containerEntries where entry.name.hasSuffix(".claim") {
            // 네트워크 마운트가 만든 ._<hash>.claim AppleDouble 보조 파일은 작업 표시가 아니므로 건드리지 않고 건너뜀.
            if !entry.isDirectory, entry.name.hasPrefix("._"), isValidClaimDirName(String(entry.name.dropFirst(2))) {
                continue
            }
            guard isValidClaimDirName(entry.name), entry.isDirectory else {
                result.protect("\(location)/작업 표시 보관 폴더", "알 수 없는 이름 또는 형식의 항목이라 건드리지 않음: \(entry.name)")
                continue
            }
            var displayName = entry.name
            do {
                let candidate = try recoverClaim(context: context, claimName: entry.name, displayName: &displayName)
                result.recoveredClaimCount += 1
                result.recoveredCandidates.append(candidate)
            } catch let archived as RecoveryArchived {
                result.archive(displayName, archived)
                if let candidate = archived.candidate { result.recoveredCandidates.append(candidate) }
            } catch let protect as RecoveryProtect {
                result.protect(displayName, protect.reason, category: protect.category)
            } catch {
                result.protect(displayName, "확인 중 오류: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Single claim

    private static func claimEntryNames(claimFD: Int32, claimName: String, isWebDAV: Bool) throws -> [String] {
        let entries = try guarded("작업 표시 폴더 읽기") { try listEntries(of: claimFD, limit: maxClaimEntries) }
        var names: [String] = []
        var sawSelf = false
        for entry in entries {
            if isWebDAV, !sawSelf, entry.name == claimName, entry.isDirectory,
               VideoConversionClaim.isWebDAVPhantomSelfEntry(parentFD: claimFD, name: claimName) {
                sawSelf = true
                continue
            }
            names.append(entry.name)
        }
        return names
    }

    private static func validatedSourceParts(_ name: String) -> (stem: String, ext: String)? {
        guard (try? NASPathSecurity.checkedComponents([name])) != nil else { return nil }
        guard !name.hasPrefix("."), !name.contains(LocalConversionConstants.excludedOriginalMarker) else { return nil }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        guard !stem.isEmpty,
              LocalConversionConstants.supportedLegacyExtensions.contains(ext.lowercased()) else { return nil }
        return (stem, ext)
    }

    private static func requireFinalMP4Absent(parentFD: Int32, name: String, displayName: String) throws {
        var st = stat()
        if fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            throw fail("완성된 MP4(\(name))가 이미 있어 변환 완료 상태로 보고 남겨 둠", .mp4Present)
        }
        let err = errno
        guard err == ENOENT else { throw fail("MP4 존재 여부 확인 오류 (errno \(err))") }
    }

    private static func filesystemName(fd: Int32) -> String {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return "" }
        return withUnsafeBytes(of: fs.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        }
    }

    private static func memberStamps(dirFD: Int32, names: [String]) throws -> [String: MemberStamp] {
        var out: [String: MemberStamp] = [:]
        for name in names {
            var st = stat()
            guard fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                throw fail("작업 표시 구성 파일(\(name))을 일반 파일로 확인하지 못함")
            }
            out[name] = MemberStamp(
                dev: st.st_dev, ino: st.st_ino, size: Int64(st.st_size),
                mtimeSec: Int(st.st_mtimespec.tv_sec), mtimeNsec: Int(st.st_mtimespec.tv_nsec)
            )
        }
        return out
    }

    /// 정확히 하나의 스키마 2 `outputPublished`(또는 원본이 남은 `deletionStarted`) 저널이 이 작업 표시의 이름·원본 식별 값(dev/ino/크기)과 맞을 때만 돌려준다.
    /// 원본 mtime은 WebDAV가 바꿔 보일 수 있어 비교하지 않는다. 그 외에는 기존처럼 남겨 둔다.
    /// 확정(`.json`로 끝나는) 저널은 정확히 하나여야 한다. 같은 시도가 남긴 `*.json.tmp-<uuid>` 임시 파일은
    /// `validateAttemptJournalTemps`로 읽기만 해 증명된 것만 건너뛰고(삭제·수정 없음), 그 외 이름은 모두 막는다.
    private static func verifyPublishedJournal(
        parentFD: Int32,
        parentNames: Set<String>,
        journalPrefix: String,
        stem: String,
        sourceName: String,
        sourceDevice: Int64,
        sourceInode: UInt64,
        sourceSize: Int64,
        expectedOutput: String,
        expectedBackup: String
    ) throws -> (record: LocalJournalRecord, ignoredTemps: [String]) {
        let journalNames = parentNames.filter { $0.hasPrefix(journalPrefix) }
        let committedNames = journalNames.filter { $0.hasSuffix(".json") }
        guard committedNames.count == 1, let journalName = committedNames.first,
              let snapshot = try readSnapshot(dirFD: parentFD, name: journalName, label: "발행 기록", allowMissing: true),
              let record = try? JSONDecoder().decode(LocalJournalRecord.self, from: Data(snapshot.bytes)) else {
            throw fail("발행 기록(저널)이 남아 있어 남겨 둠")
        }
        // `deletionStarted`(-deleting.json)는 삭제 시도 중 원본이 그대로 남은 경우의 이어받기용이다. 아래의 원본 식별·MP4 SHA-256 검증은 동일하게 적용되며 원본은 삭제하지 않는다.
        let isDeleting = record.state == .deletionStarted
        guard record.schema == LocalJournalRecord.currentSchema, record.state == .outputPublished || isDeleting,
              let attempt = UUID(uuidString: record.attemptID), attempt.uuidString.lowercased() == record.attemptID,
              journalName == ".\(stem).journal-\(record.attemptID)-\(isDeleting ? "deleting" : "published").json",
              record.thumbnailFileName.map({ !$0.isEmpty && (try? NASPathSecurity.checkedComponents([$0])) != nil }) ?? true,
              record.originalFileName == sourceName,
              record.finalFileName == expectedOutput,
              record.backupFileName == expectedBackup,
              record.stagedFileName == ".\(stem).stage-\(record.attemptID).mp4",
              record.sourceDevice == sourceDevice,
              record.sourceInode == sourceInode,
              record.sourceSize == sourceSize,
              record.outputSize > 0,
              record.outputSha256.utf8.count == 64,
              record.outputSha256.allSatisfy({ "0123456789abcdef".contains($0) }),
              !parentNames.contains(record.stagedFileName) else {
            throw fail("발행 기록(저널)이 이 작업 표시와 정확히 맞지 않아 남겨 둠")
        }
        let tempNames = journalNames.subtracting(committedNames).sorted()
        let ignored = try validateAttemptJournalTemps(parentFD: parentFD, names: tempNames, stem: stem, published: record)
        return (record, ignored)
    }

    /// 같은 시도(attemptID)가 저널 기록 중 남긴 `-deleting|-published.json.tmp-<소문자 uuid>` 임시 파일만 인정한다.
    /// - 0바이트: 이름이 정확히 이 시도의 생성 규칙과 맞고 일반 파일이면 내용 없이 건너뛴다.
    /// - 내용 있음: 스키마 2, 이름 접미사와 맞는 상태, 같은 시도·같은 원본 식별 값·같은 이름들·같은 MP4 크기/SHA-256·같은 생성 시각이어야 한다.
    /// 인정된 파일도 열어서 읽기만 하며 삭제·수정하지 않는다. 하나라도 맞지 않으면 전체를 막는다. 건너뛴 이름 목록을 돌려준다.
    static func validateAttemptJournalTemps(
        parentFD: Int32,
        names: [String],
        stem: String,
        published: LocalJournalRecord
    ) throws -> [String] {
        let base = ".\(stem).journal-\(published.attemptID)-"
        var ignored: [String] = []
        for name in names {
            let kinds: [(marker: String, state: LocalJournalRecord.State)] = [
                ("deleting.json.tmp-", .deletionStarted),
                ("published.json.tmp-", .outputPublished)
            ]
            guard let kind = kinds.first(where: { name.hasPrefix(base + $0.marker) }) else {
                throw fail("알 수 없는 저널 관련 파일이 있어 남겨 둠: \(name)")
            }
            let suffix = String(name.dropFirst((base + kind.marker).count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString.lowercased() == suffix else {
                throw fail("저널 임시 파일 이름이 이 시도의 생성 규칙과 맞지 않아 남겨 둠: \(name)")
            }

            let fd = openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw fail("저널 임시 파일 열기 실패 (errno \(errno)): \(name)") }
            defer { Darwin.close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
                  st.st_size >= 0, st.st_size <= maxMemberBytes else {
                throw fail("저널 임시 파일 형식이 올바르지 않아 남겨 둠: \(name)")
            }
            let count = Int(st.st_size)
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), count - got) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw fail("저널 임시 파일 읽기 실패 또는 짧게 읽힘: \(name)") }
                got += n
            }
            var extra: UInt8 = 0
            var after = stat()
            var entry = stat()
            guard Darwin.read(fd, &extra, 1) == 0,
                  fstat(fd, &after) == 0, after.st_size == st.st_size,
                  fstatat(parentFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                  entry.st_dev == st.st_dev, entry.st_ino == st.st_ino else {
                throw fail("저널 임시 파일을 읽는 중 바뀌거나 교체됨: \(name)")
            }
            if count == 0 {
                ignored.append(name)
                continue
            }

            guard let temp = try? JSONDecoder().decode(LocalJournalRecord.self, from: Data(buffer)),
                  temp.schema == LocalJournalRecord.currentSchema,
                  temp.state == kind.state,
                  temp.attemptID == published.attemptID,
                  temp.originalFileName == published.originalFileName,
                  temp.backupFileName == published.backupFileName,
                  temp.finalFileName == published.finalFileName,
                  temp.stagedFileName == published.stagedFileName,
                  temp.sourceDevice == published.sourceDevice,
                  temp.sourceInode == published.sourceInode,
                  temp.sourceSize == published.sourceSize,
                  temp.sourceMtime == published.sourceMtime,
                  temp.outputSize == published.outputSize,
                  temp.outputSha256 == published.outputSha256,
                  temp.retainedOriginalReason == published.retainedOriginalReason,
                  temp.createdAt == published.createdAt else {
                throw fail("내용이 있는 저널 임시 파일이 이 시도의 발행 기록과 정확히 맞지 않아 남겨 둠: \(name)")
            }
            if let thumb = temp.thumbnailFileName {
                guard kind.state == .deletionStarted, !thumb.isEmpty,
                      (try? NASPathSecurity.checkedComponents([thumb])) != nil else {
                    throw fail("저널 임시 파일의 썸네일 이름이 올바르지 않아 남겨 둠: \(name)")
                }
            }
            ignored.append(name)
        }
        return ignored
    }

    /// 저널이 말하는 최종 MP4를 디스크립터로 열어 일반 파일·크기·전체 SHA-256을 직접 확인한다. 확인 못 하면 남겨 둔다.
    /// WebDAV는 일시적으로 짧게 읽히거나 해시가 틀어질 수 있어 그 마운트에서만 한 번 다시 열어 확인한다.
    /// 기대 크기·해시는 그대로이며 어긋난 값은 절대 받아들이지 않는다. 실패 시 기대/실제 바이트와 해시 일부를 알린다.
    private static func verifyPublishedOutput(parentFD: Int32, journal: LocalJournalRecord) throws -> LocalFileIdentity {
        func shortHash(_ hash: String) -> String { String(hash.prefix(12)) }
        func attemptOnce() -> (identity: LocalFileIdentity?, problem: String?) {
            let fd = openat(parentFD, journal.finalFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return (nil, "열기 실패 (errno \(errno))") }
            defer { Darwin.close(fd) }
            guard let identity = try? LocalFileIdentity.inspect(fd: fd) else { return (nil, "일반 파일 상태 확인 실패") }
            guard identity.size == journal.outputSize else {
                return (identity, "크기 불일치(기록 \(journal.outputSize)바이트, 실제 \(identity.size)바이트)")
            }
            do {
                let hashed = try LocalPublicationManager.sha256Streaming(fd: fd)
                guard hashed.bytes == journal.outputSize, hashed.digest == journal.outputSha256 else {
                    return (identity, "읽은 \(hashed.bytes)/기록 \(journal.outputSize)바이트, SHA-256 기록 \(shortHash(journal.outputSha256))… 실제 \(shortHash(hashed.digest))…")
                }
            } catch {
                return (identity, "읽기 실패: \(error.localizedDescription)")
            }
            return (identity, nil)
        }

        let attempts = filesystemName(fd: parentFD) == "webdav" ? 2 : 1
        var identity: LocalFileIdentity?
        var problems: [String] = []
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(200_000) }
            let outcome = attemptOnce()
            if let problem = outcome.problem {
                problems.append("시도 \(attempt + 1): \(problem)")
                continue
            }
            identity = outcome.identity
            break
        }
        guard let identity else {
            throw fail("발행된 MP4 확인 실패 (\(problems.joined(separator: " → "))): MP4·원본·기록은 그대로 두고 활성 표시를 그대로 둠")
        }
        let entry = try guarded("발행된 MP4 항목 확인") { try LocalFileIdentity.inspect(dirFD: parentFD, name: journal.finalFileName) }
        // WebDAV는 읽기만 해도 시각 정보가 바뀌어 보일 수 있다. 같은 파일(dev/ino/크기)이고 시각만 다를 때만 허용한다.
        let metadataOnly = filesystemName(fd: parentFD) == "webdav" && entry.isTimestampOnlyDrift(from: identity)
        guard entry == identity || metadataOnly else { throw fail("발행된 MP4가 읽는 중 바뀌어 활성 표시를 그대로 둠") }
        return entry
    }

    /// 자기 작업 표시 폴더를 내용 변경 없이 `<key>.retired-<kind>-<token>` 이름으로 옮긴다.
    /// RENAME_EXCL(덮어쓰기 불가)만 쓰며 지원되지 않거나 실패하면 아무것도 바꾸지 않고 남겨 둔다. 이동 후에도 삭제·롤백하지 않는다.
    private static func archiveOwnClaim(
        context: ClaimContext,
        claimFD: Int32,
        claimName: String,
        claimID: NodeID,
        isWebDAV: Bool,
        token: String,
        names: [String],
        stamps: [String: MemberStamp],
        kindName: String,
        verify: () throws -> Void
    ) throws -> ArchiveMethod {
        let containerFD = context.containerFD
        let archiveName = "\(claimName.dropLast(".claim".count)).retired-\(kindName)-\(token)"
        guard !archiveName.hasSuffix(".claim") else { throw fail("보관 이름이 활성 이름과 겹쳐 남겨 둠") }

        guard try memberStamps(dirFD: claimFD, names: names) == stamps else {
            throw fail("작업 표시 구성 파일이 확인하는 사이 바뀌어 남겨 둠", .active)
        }
        try verify()
        guard try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID,
              try nodeID(fd: claimFD, directory: true, "작업 표시 폴더") == claimID else {
            throw fail("작업 표시 폴더가 보관 직전 교체되어 남겨 둠")
        }

        // RENAME_EXCL = 0x00000004
        guard renameatx_np(containerFD, claimName, containerFD, archiveName, 0x00000004) == 0 else {
            let err = errno
            if err == ENOTSUP || err == EOPNOTSUPP {
                try archiveByCopy(
                    context: context, claimFD: claimFD, claimName: claimName, claimID: claimID, isWebDAV: isWebDAV,
                    token: token, names: names, stamps: stamps, kindName: kindName, verify: verify
                )
                return .copiedAndReleased
            }
            throw fail("보관 이름 변경 실패 (errno \(err)): 작업 표시를 그대로 둠")
        }

        // 이동 이후 확인. 실패해도 이미 옮겨진 폴더를 지우거나 되돌리지 않고 그대로 둔다.
        var leftover = stat()
        guard fstatat(containerFD, claimName, &leftover, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              try nodeID(at: containerFD, archiveName, directory: true, "보관된 작업 표시") == claimID else {
            throw fail("보관 후 폴더 확인 실패: \(archiveName) 를 그대로 두었으니 사람이 확인해야 함")
        }
        let archiveFD = openat(containerFD, archiveName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard archiveFD >= 0 else { throw fail("보관 후 폴더 열기 실패 (errno \(errno)): \(archiveName) 를 그대로 둠") }
        defer { Darwin.close(archiveFD) }
        guard try nodeID(fd: archiveFD, directory: true, "보관된 작업 표시") == claimID,
              Set(try claimEntryNames(claimFD: archiveFD, claimName: archiveName, isWebDAV: isWebDAV)) == Set(names),
              try memberStamps(dirFD: archiveFD, names: names) == stamps else {
            throw fail("보관 후 내용 확인 실패: \(archiveName) 를 그대로 두었으니 사람이 확인해야 함")
        }
        _ = fsync(containerFD)
        try verify()
        return .renamed
    }

    private static let maxMemberBytes: Int64 = 65536

    /// 구성 파일 하나를 제한된 크기로 읽는다. 0바이트 파일도 허용한다. 식별 값과 내용을 함께 돌려준다.
    private static func readMemberCopy(dirFD: Int32, name: String) throws -> (stamp: MemberStamp, bytes: [UInt8]) {
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw fail("작업 표시 구성 파일(\(name)) 열기 실패 (errno \(errno))") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
              st.st_size >= 0, Int64(st.st_size) <= maxMemberBytes else {
            throw fail("작업 표시 구성 파일(\(name)) 형식이 올바르지 않아 보관하지 않음")
        }
        let count = Int(st.st_size)
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("작업 표시 구성 파일(\(name)) 읽기 실패 또는 짧게 읽힘") }
            got += n
        }
        var extra: UInt8 = 0
        guard Darwin.read(fd, &extra, 1) == 0 else { throw fail("작업 표시 구성 파일(\(name))을 읽는 중 내용이 바뀜") }
        var after = stat()
        var entry = stat()
        guard fstat(fd, &after) == 0, after.st_size == st.st_size,
              after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec,
              fstatat(dirFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
              entry.st_dev == st.st_dev, entry.st_ino == st.st_ino else {
            throw fail("작업 표시 구성 파일(\(name))을 읽는 중 바뀌거나 교체됨")
        }
        let stamp = MemberStamp(
            dev: st.st_dev, ino: st.st_ino, size: Int64(st.st_size),
            mtimeSec: Int(st.st_mtimespec.tv_sec), mtimeNsec: Int(st.st_mtimespec.tv_nsec)
        )
        return (stamp, buffer)
    }

    /// 새 파일만 만든다(O_EXCL, 심볼릭 링크 불허). 덮어쓰지 않는다.
    private static func writeNewMember(dirFD: Int32, name: String, bytes: [UInt8]) throws {
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("보관본 파일(\(name)) 만들기 실패 (errno \(errno))") }
        defer { Darwin.close(fd) }
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), bytes.count - written) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw fail("보관본 파일(\(name)) 쓰기 실패 (errno \(errno))") }
            written += n
        }
        _ = fsync(fd) // 네트워크 마운트는 지원하지 않을 수 있어 최선만 시도한다. 내용은 다시 읽어 확인한다.
    }

    /// RENAME_EXCL을 지원하지 않는 폴더용. 고유한 보관 폴더(mkdirat)에 구성 파일을 복사·재확인한 뒤에만,
    /// 처음 확인한 그대로인 자기 구성 파일을 지우고(소유자 파일 마지막) 비면 활성 폴더를 rmdir한다. 재귀 삭제·덮어쓰기 없음.
    /// 보관본은 어떤 실패에서도 지우지 않고 증거로 남긴다. 복사 전 실패는 활성 표시를 그대로 둔다.
    private static func archiveByCopy(
        context: ClaimContext,
        claimFD: Int32,
        claimName: String,
        claimID: NodeID,
        isWebDAV: Bool,
        token: String,
        names: [String],
        stamps: [String: MemberStamp],
        kindName: String,
        verify: () throws -> Void
    ) throws {
        let containerFD = context.containerFD
        let archiveName = "\(claimName.dropLast(".claim".count)).retired-\(kindName)-\(token)-copy-\(UUID().uuidString.lowercased())"
        guard !archiveName.hasSuffix(".claim"), Set(names) == Set(stamps.keys) else {
            throw fail("보관 이름 또는 구성 파일 정보가 올바르지 않아 활성 표시를 그대로 둠")
        }

        /// 원본·MP4(verify), 상위 폴더 포함 관계, 구성 파일 목록, 구성 파일의 식별 값과 바이트(소유자·진행 신호 포함)를 다시 확인한다.
        func ensureUnchanged() throws -> [String: [UInt8]] {
            try verify()
            try guarded("상위 폴더 재확인") {
                let reopened = try NASPinnedFS.openDirectoryChain(context.rootFD, context.components, create: false)
                defer { Darwin.close(reopened) }
                guard try nodeID(fd: reopened, directory: true, "상위 폴더") == context.parentID else {
                    throw fail("상위 폴더가 확인하는 사이 교체됨")
                }
            }
            guard try nodeID(fd: context.parentFD, directory: true, "상위 폴더") == context.parentID,
                  try nodeID(at: context.parentFD, VideoConversionClaim.containerDirName, directory: true, "작업 표시 보관 폴더") == context.containerID,
                  try nodeID(fd: containerFD, directory: true, "작업 표시 보관 폴더") == context.containerID,
                  try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID,
                  try nodeID(fd: claimFD, directory: true, "작업 표시 폴더") == claimID else {
                throw fail("폴더 구성이 보관 중 바뀌어 남겨 둠", .active)
            }
            guard Set(try claimEntryNames(claimFD: claimFD, claimName: claimName, isWebDAV: isWebDAV)) == Set(names) else {
                throw fail("작업 표시 폴더 내용이 보관 중 바뀌어 남겨 둠", .active)
            }
            var out: [String: [UInt8]] = [:]
            for name in names {
                let member = try readMemberCopy(dirFD: claimFD, name: name)
                guard member.stamp == stamps[name] else {
                    throw fail("작업 표시 구성 파일(\(name))이 보관 중 바뀌어 남겨 둠 (소유자·진행 신호 포함)", .active)
                }
                out[name] = member.bytes
            }
            return out
        }

        // 1) 활성 표시를 건드리지 않고 내용만 읽어 둔다.
        let contents = try ensureUnchanged()

        // 2) 고유 보관 폴더를 원자적으로 만들고 같은 디스크립터에 묶는다.
        guard mkdirat(containerFD, archiveName, 0o700) == 0 else {
            throw fail("보관 폴더 만들기 실패 (errno \(errno)): 활성 표시를 그대로 둠")
        }
        let archiveFD = openat(containerFD, archiveName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard archiveFD >= 0 else {
            throw fail("보관 폴더 열기 실패 (errno \(errno)): \(archiveName) 를 그대로 두고 활성 표시도 그대로 둠")
        }
        defer { Darwin.close(archiveFD) }
        let evidence = "보관 폴더 \(archiveName) 은 증거로 그대로 둠"

        do {
            let archiveID = try nodeID(fd: archiveFD, directory: true, "보관 폴더")
            guard archiveID != claimID, try nodeID(at: containerFD, archiveName, directory: true, "보관 폴더") == archiveID else {
                throw fail("보관 폴더가 만드는 중 교체됨")
            }
            // 3) 복사 후 보관본을 다시 읽어 바이트까지 대조한다.
            // WebDAV가 ._ 보조 파일을 자동 생성하므로 원래 이름을 그대로 복사하지 않는다.
            // 내용은 독립 이름에 보관하고 원래 이름과의 대응표도 함께 보존한다.
            let orderedNames = names.sorted()
            let mapping = Dictionary(uniqueKeysWithValues: orderedNames.enumerated().map { ($0.element, "member-\($0.offset).bin") })
            let indexData = try guarded("보관 이름 대응표 생성") { try JSONEncoder().encode(mapping) }
            try writeNewMember(dirFD: archiveFD, name: "index.json", bytes: Array(indexData))
            for name in orderedNames { try writeNewMember(dirFD: archiveFD, name: mapping[name]!, bytes: contents[name] ?? []) }
            guard try readMemberCopy(dirFD: archiveFD, name: "index.json").bytes == Array(indexData) else {
                throw fail("보관 이름 대응표가 원본과 다름")
            }
            for name in orderedNames {
                let copy = try readMemberCopy(dirFD: archiveFD, name: mapping[name]!)
                guard copy.bytes == contents[name], copy.stamp.size == stamps[name]?.size else {
                    throw fail("보관본 파일(\(name))이 원본과 다름")
                }
            }
            guard try nodeID(fd: archiveFD, directory: true, "보관 폴더") == archiveID else {
                throw fail("보관 폴더가 확인 중 교체됨")
            }
            _ = fsync(archiveFD)
            _ = fsync(containerFD)
        } catch let protect as RecoveryProtect {
            throw fail("\(protect.reason) (활성 표시는 건드리지 않음, \(evidence))")
        }

        // 4) 해제 직전: 원본·MP4·상위 폴더·소유자·진행 신호·구성 파일을 다시 확인한다. 하나라도 다르면 아무것도 지우지 않는다.
        do {
            let latest = try ensureUnchanged()
            guard latest == contents else { throw fail("작업 표시 내용이 해제 직전 바뀌어 남겨 둠", .active) }
        } catch let protect as RecoveryProtect {
            throw RecoveryProtect(reason: "\(protect.reason) (활성 표시는 건드리지 않음, \(evidence))", category: protect.category)
        }

        // 5) 처음 확인한 그대로인 자기 파일만 삭제한다. 소유자 파일은 마지막. 모두 지워진 뒤에만 빈 폴더를 rmdir한다.
        let ownerNames = names.filter { $0.hasPrefix("owner-") && $0.hasSuffix(".json") }
        let order = names.filter { !ownerNames.contains($0) } + ownerNames
        var remaining = order
        func matchesStamp(_ name: String) -> Bool? {
            var st = stat()
            if fstatat(claimFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT ? nil : false }
            guard let stamp = stamps[name], (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1,
                  st.st_dev == stamp.dev, st.st_ino == stamp.ino, Int64(st.st_size) == stamp.size,
                  Int(st.st_mtimespec.tv_sec) == stamp.mtimeSec,
                  Int(st.st_mtimespec.tv_nsec) == stamp.mtimeNsec,
                  let current = try? readMemberCopy(dirFD: claimFD, name: name),
                  current.stamp == stamp, current.bytes == contents[name] else { return false }
            return true
        }
        do {
            for name in order where matchesStamp(name) == false {
                throw fail("해제 직전 항목이 달라짐(\(name))")
            }
            for name in order {
                guard try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID else {
                    throw fail("해제 중 작업 표시 폴더가 교체됨")
                }
                if matchesStamp(name) == false { throw fail("해제 중 항목이 달라짐(\(name))") }
                if unlinkat(claimFD, name, 0) != 0, errno != ENOENT {
                    throw fail("해제 중 삭제 실패(\(name), errno \(errno))")
                }
                remaining.removeAll { $0 == name }
            }
            _ = fsync(claimFD)
            guard try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID else {
                throw fail("해제 중 작업 표시 폴더가 교체됨")
            }
            guard unlinkat(containerFD, claimName, AT_REMOVEDIR) == 0 else {
                throw fail("활성 폴더 삭제 실패 (errno \(errno))")
            }
            _ = fsync(containerFD)
        } catch let protect as RecoveryProtect {
            let left = remaining.isEmpty ? "구성 파일은 모두 지웠으나 빈 활성 폴더가 남음" : "남은 활성 파일: \(remaining.joined(separator: ", "))"
            throw fail("\(protect.reason): 일부만 해제됨 (\(left), \(evidence))")
        }

        do {
            try verify()
        } catch let protect as RecoveryProtect {
            throw fail("\(protect.reason) (활성 표시는 이미 해제됨, \(evidence))")
        }
    }

    private static func recoverClaim(
        context: ClaimContext,
        claimName: String,
        displayName: inout String
    ) throws -> LocalDiscoveredFile {
        let containerFD = context.containerFD
        let parentFD = context.parentFD

        var claimFD = openat(containerFD, claimName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard claimFD >= 0 else { throw fail("작업 표시 폴더 열기 실패 (errno \(errno))") }
        defer { if claimFD >= 0 { Darwin.close(claimFD) } }

        let claimID = try nodeID(fd: claimFD, directory: true, "작업 표시 폴더")
        guard try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID else {
            throw fail("작업 표시 폴더가 열리는 중 교체됨")
        }

        var fsInfo = statfs()
        let fsKnown = fstatfs(claimFD, &fsInfo) == 0
        let fsName = fsKnown ? withUnsafeBytes(of: fsInfo.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return "" }
            return String(cString: base)
        } : ""
        let isWebDAV = fsName == "webdav"
        let isNetwork = VideoConversionClaim.isNetworkFilesystem(fd: claimFD)

        let names = try claimEntryNames(claimFD: claimFD, claimName: claimName, isWebDAV: isWebDAV)

        // Exactly one owner file; its token defines the ONLY names this recovery may accept and delete.
        let ownerNames = names.filter { $0.hasPrefix("owner-") && $0.hasSuffix(".json") }
        guard ownerNames.count == 1, let ownerFileName = ownerNames.first else {
            throw fail("소유자 정보 파일이 \(ownerNames.count)개라 확인할 수 없어 남겨 둠")
        }
        let token = String(ownerFileName.dropFirst("owner-".count).dropLast(".json".count))
        guard isValidToken(token) else { throw fail("소유자 정보 파일 이름 형식이 올바르지 않아 남겨 둠") }

        let hbFileName = "hb-\(token).json"
        let hbTmpName = "hb-\(token).json.tmp"
        let appleDoubleNames = isNetwork ? VideoConversionClaim.ownAppleDoubleNames(token: token) : []
        let allowed = Set([ownerFileName, hbFileName, hbTmpName] + appleDoubleNames)
        if let foreign = names.first(where: { !allowed.contains($0) }) {
            throw fail("이 작업의 것이 아닌 파일이 있어 남겨 둠: \(foreign)")
        }

        // 보관 분기 전용: 구성 파일 전체의 첫 식별 값. 읽지 못하면 보관 분기만 쓰지 않는다.
        let initialStamps = try? memberStamps(dirFD: claimFD, names: names)

        // Owner record snapshot (bytes + inode).
        guard let ownerSnapshot = try readSnapshot(dirFD: claimFD, name: ownerFileName, label: "소유자 정보", allowMissing: false) else {
            throw fail("소유자 정보를 읽지 못함")
        }
        guard let ownerRecord = try? JSONDecoder().decode(VideoClaimOwnerRecord.self, from: Data(ownerSnapshot.bytes)) else {
            throw fail("소유자 정보를 해석하지 못해 남겨 둠")
        }

        if ownerRecord.source_name.count < 400 { displayName = ownerRecord.source_name }

        guard ownerRecord.schema == 1, ownerRecord.operation == "video-mp4-v1" else {
            throw fail("알 수 없는 형식의 작업 표시라 남겨 둠")
        }
        guard ownerRecord.owner_kind == "mac" else {
            throw fail("NAS 또는 다른 종류의 작업 표시라 건드리지 않음", .foreignDevice)
        }
        guard ownerRecord.owner_id == VideoConversionClaim.stableDeviceUUID() else {
            throw fail("다른 Mac의 작업 표시라 건드리지 않음", .foreignDevice)
        }
        guard ownerRecord.token == token else { throw fail("소유자 정보의 식별 값이 파일 이름과 달라 남겨 둠") }

        guard let parts = validatedSourceParts(ownerRecord.source_name) else {
            throw fail("원본 이름이 지원되는 영상 형식이 아니거나 안전하지 않아 남겨 둠")
        }
        let expectedOutput = "\(parts.stem).\(LocalConversionConstants.finalExtension)"
        let expectedBackup = "\(parts.stem)\(LocalConversionConstants.backupSuffix).\(parts.ext)"
        guard ownerRecord.output_name == expectedOutput, ownerRecord.backup_name == expectedBackup,
              (try? NASPathSecurity.checkedComponents([expectedOutput])) != nil else {
            throw fail("원본과 결과 파일 이름이 서로 맞지 않아 남겨 둠")
        }
        guard claimName == "\(VideoConversionClaim.computeKey(finalMP4FileName: expectedOutput)).claim" else {
            throw fail("작업 표시 폴더 이름이 결과 파일과 맞지 않아 남겨 둠")
        }
        guard ownerRecord.source_fp.size >= 0 else { throw fail("원본 정보 값이 올바르지 않아 남겨 둠") }

        let sourceName = ownerRecord.source_name
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if ownerRecord.started_at_ms < 0 || ownerRecord.started_at_ms > nowMs || nowMs - ownerRecord.started_at_ms < 120_000 {
            throw fail("방금 시작된 작업으로 보여 남겨 둠", .active)
        }

        // Heartbeat: any read problem protects. Missing is accepted only because the device lease and the
        // other-instance guard (both held by the caller) demonstrate that no local worker can be alive.
        let hbSnapshot = try readSnapshot(dirFD: claimFD, name: hbFileName, label: "진행 신호", allowMissing: true)
        if let hbSnapshot {
            guard let hb = try? JSONDecoder().decode(VideoClaimHeartbeatRecord.self, from: Data(hbSnapshot.bytes)),
                  hb.token == token else {
                throw fail("진행 신호를 해석하지 못해 남겨 둠")
            }
            guard hb.heartbeat_at_ms >= 0, hb.heartbeat_at_ms <= nowMs else {
                throw fail("진행 시각을 확인할 수 없어 남겨 둠", .active)
            }
            let ageMs = nowMs - hb.heartbeat_at_ms
            if ageMs < 120_000 {
                throw fail("최근 진행 신호(\(max(0, ageMs / 1000))초 전)가 있어 작업 중으로 보고 남겨 둠", .active)
            }
        }

        // Other files of this stem that indicate a published or conflicting state.
        if context.parentNames.contains(expectedBackup) {
            throw fail("보존 이름 파일(\(expectedBackup))이 있어 남겨 둠")
        }
        let journalPrefix = ".\(parts.stem).journal-"
        var publishedJournal: LocalJournalRecord?
        var ignoredJournalTemps: [String] = []
        if context.parentNames.contains(where: { $0.hasPrefix(journalPrefix) }) {
            let verified = try verifyPublishedJournal(
                parentFD: parentFD, parentNames: context.parentNames, journalPrefix: journalPrefix,
                stem: parts.stem, sourceName: ownerRecord.source_name, sourceDevice: ownerRecord.source_fp.dev,
                sourceInode: ownerRecord.source_fp.ino, sourceSize: ownerRecord.source_fp.size,
                expectedOutput: expectedOutput, expectedBackup: expectedBackup
            )
            publishedJournal = verified.record
            ignoredJournalTemps = verified.ignoredTemps
        }

        // Source: must still be the exact recorded file (size / mtime / device / inode).
        let sourceFD = openat(parentFD, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else {
            let err = errno
            if err == ENOENT {
                throw fail("원본 파일이 없어 완료 또는 불확실한 상태로 보고 남겨 둠", .originalAbsent)
            }
            throw fail("원본 파일 열기 실패 (errno \(err))")
        }
        defer { Darwin.close(sourceFD) }

        let sourceIdentity = try guarded("원본 파일 확인") { try LocalFileIdentity.inspect(fd: sourceFD) }

        func sourceMatchesRecord(_ identity: LocalFileIdentity) -> Bool {
            identity.size == ownerRecord.source_fp.size
                && identity.mtimeNanoseconds == ownerRecord.source_fp.mtime_ns
                && Int64(identity.device) == ownerRecord.source_fp.dev
                && UInt64(identity.inode) == ownerRecord.source_fp.ino
        }
        func sourceSameFileIgnoringTime(_ identity: LocalFileIdentity) -> Bool {
            identity.size == ownerRecord.source_fp.size
                && Int64(identity.device) == ownerRecord.source_fp.dev
                && UInt64(identity.inode) == ownerRecord.source_fp.ino
        }
        // WebDAV가 시각만 바꿔 보여 주는 경우에 한해(같은 dev/ino/크기) 삭제 없는 보관 분기만 허용한다.
        let timestampDrift = !sourceMatchesRecord(sourceIdentity)
        if timestampDrift {
            guard sourceSameFileIgnoringTime(sourceIdentity), filesystemName(fd: sourceFD) == "webdav" else {
                throw fail("원본 파일이 기록된 것과 달라(수정 또는 교체됨) 남겨 둠")
            }
        }
        let archiveMode = timestampDrift || publishedJournal != nil
        let sourceEntryID = try nodeID(at: parentFD, sourceName, directory: false, "원본 항목")
        guard sourceEntryID.dev == sourceIdentity.device, sourceEntryID.ino == sourceIdentity.inode else {
            throw fail("원본 항목이 열린 파일과 달라 남겨 둠")
        }

        // Advisory source lock: kept for the whole mutation when acquired. Unsupported advisory locking on a
        // network mount is acceptable only because the exclusive device lease is in effect; every other error protects.
        var sourceLockHeld = false
        if flock(sourceFD, LOCK_EX | LOCK_NB) == 0 {
            sourceLockHeld = true
        } else {
            let err = errno
            if err == EWOULDBLOCK || err == EAGAIN {
                throw fail("다른 프로세스가 원본을 사용 중이라 남겨 둠", .active)
            }
            guard (err == ENOTSUP || err == EOPNOTSUPP), VideoConversionClaim.isNetworkFilesystem(fd: sourceFD) else {
                throw fail("원본 잠금 확인 오류 (errno \(err))")
            }
        }
        defer { if sourceLockHeld { _ = flock(sourceFD, LOCK_UN) } }

        var publishedOutput: LocalFileIdentity?
        if let publishedJournal {
            publishedOutput = try verifyPublishedOutput(parentFD: parentFD, journal: publishedJournal)
        } else {
            try requireFinalMP4Absent(parentFD: parentFD, name: expectedOutput, displayName: sourceName)
        }

        // ---- Immediately before mutation: everything is verified again from the path entries. ----
        try guarded("상위 폴더 재확인") {
            let reopened = try NASPinnedFS.openDirectoryChain(context.rootFD, context.components, create: false)
            defer { Darwin.close(reopened) }
            guard try nodeID(fd: reopened, directory: true, "상위 폴더") == context.parentID else {
                throw fail("상위 폴더가 확인하는 사이 교체됨")
            }
        }
        guard try nodeID(fd: parentFD, directory: true, "상위 폴더") == context.parentID,
              try nodeID(at: parentFD, VideoConversionClaim.containerDirName, directory: true, "작업 표시 보관 폴더") == context.containerID,
              try nodeID(fd: containerFD, directory: true, "작업 표시 보관 폴더") == context.containerID,
              try nodeID(at: containerFD, claimName, directory: true, "작업 표시 폴더") == claimID,
              try nodeID(fd: claimFD, directory: true, "작업 표시 폴더") == claimID else {
            throw fail("폴더 구성이 확인하는 사이 바뀌어 남겨 둠")
        }

        guard let ownerAgain = try readSnapshot(dirFD: claimFD, name: ownerFileName, label: "소유자 정보", allowMissing: false),
              ownerAgain == ownerSnapshot else {
            throw fail("소유자 정보가 확인하는 사이 바뀌어 남겨 둠")
        }
        let hbAgain = try readSnapshot(dirFD: claimFD, name: hbFileName, label: "진행 신호", allowMissing: true)
        guard hbAgain == hbSnapshot else { throw fail("진행 신호가 확인하는 사이 바뀌어 남겨 둠", .active) }

        let sourceNow = try guarded("원본 재확인") { try LocalFileIdentity.inspect(dirFD: parentFD, name: sourceName) }
        guard archiveMode ? sourceNow == sourceIdentity
                : (sourceMatchesRecord(sourceNow) && sourceNow.device == sourceIdentity.device && sourceNow.inode == sourceIdentity.inode) else {
            throw fail("원본이 확인하는 사이 바뀌어 남겨 둠")
        }

        // Claim directory content must be exactly what was inspected, through a freshly opened descriptor.
        let recheckFD = openat(containerFD, claimName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard recheckFD >= 0 else { throw fail("작업 표시 폴더 재열기 실패 (errno \(errno))") }
        let namesAgain: [String]
        do {
            defer { Darwin.close(recheckFD) }
            guard try nodeID(fd: recheckFD, directory: true, "작업 표시 폴더") == claimID else {
                throw fail("작업 표시 폴더가 확인하는 사이 교체됨")
            }
            namesAgain = try claimEntryNames(claimFD: recheckFD, claimName: claimName, isWebDAV: isWebDAV)
        }
        guard Set(namesAgain) == Set(names) else { throw fail("작업 표시 폴더 내용이 확인하는 사이 바뀌어 남겨 둠") }

        // 빈 자기 토큰 임시 사이드카는 정확한 dev/ino에 묶어 두고 삭제 직전에 다시 확인한다. 그 외 사이드카는 기존 검증 그대로.
        var boundEmptySidecars: [String: NodeID] = [:]
        for adName in appleDoubleNames where names.contains(adName) {
            if adName == "._\(hbTmpName)", let id = emptyTempSidecarID(dirFD: claimFD, name: adName) {
                boundEmptySidecars[adName] = id
                continue
            }
            guard VideoConversionClaim.isValidAppleDoubleFile(dirFD: claimFD, name: adName) else {
                throw fail("네트워크 폴더가 만든 보조 파일(\(adName))이 올바르지 않아 남겨 둠")
            }
        }

        // 발행된 MP4: WebDAV는 같은 파일(dev/ino/크기)의 시각 정보만 바꿔 보일 수 있다. 전체 SHA-256은 이미 확인했으므로
        // 그 경우에 한해 짧게 재시도하여 연속 두 번 같게 관찰된 값을 새 기준으로 쓴다. 안정되지 않으면 남겨 둔다.
        let outputIsWebDAV = filesystemName(fd: parentFD) == "webdav"
        func outputUnchanged(_ current: LocalFileIdentity?) -> Bool {
            guard let current, let publishedOutput else { return false }
            return current == publishedOutput || (outputIsWebDAV && current.isTimestampOnlyDrift(from: publishedOutput))
        }
        if publishedJournal != nil {
            var stable = false
            var last = try? LocalFileIdentity.inspect(dirFD: parentFD, name: expectedOutput)
            for _ in 0..<3 {
                guard let first = last, outputUnchanged(first) else { break }
                usleep(150_000)
                let second = try? LocalFileIdentity.inspect(dirFD: parentFD, name: expectedOutput)
                if let second, second == first {
                    publishedOutput = second
                    stable = true
                    break
                }
                last = second
            }
            guard stable else { throw fail("보존할 MP4가 확인하는 사이 바뀌어 남겨 둠") }
        } else {
            try requireFinalMP4Absent(parentFD: parentFD, name: expectedOutput, displayName: sourceName)
        }

        // ---- 보관 분기: 삭제·수정 없이 활성 이름(*.claim) 밖으로 통째로 옮기기만 한다. ----
        if archiveMode {
            guard let initialStamps else { throw fail("작업 표시 구성 파일을 확인하지 못해 남겨 둠") }
            var relativeComponents = context.components
            relativeComponents.append(sourceName)
            var url = context.folder.url
            for component in relativeComponents { url.appendPathComponent(component) }
            let candidate = LocalDiscoveredFile(
                folderID: context.folder.id,
                url: url,
                relativePath: relativeComponents.joined(separator: "/"),
                relativeComponents: relativeComponents,
                fileSize: sourceNow.size,
                identity: sourceNow
            )
            func verifySourceAndOutput() throws {
                guard (try? LocalFileIdentity.inspect(fd: sourceFD)) == sourceIdentity,
                      (try? LocalFileIdentity.inspect(dirFD: parentFD, name: sourceName)) == sourceIdentity else {
                    throw fail("원본이 보관 작업 중 바뀌어 확인이 필요함")
                }
                if publishedJournal != nil {
                    guard outputUnchanged(try? LocalFileIdentity.inspect(dirFD: parentFD, name: expectedOutput)) else {
                        throw fail("MP4가 보관 작업 중 바뀌어 확인이 필요함")
                    }
                }
            }
            let method = try archiveOwnClaim(
                context: context, claimFD: claimFD, claimName: claimName, claimID: claimID, isWebDAV: isWebDAV,
                token: token, names: names, stamps: initialStamps,
                kindName: publishedJournal != nil ? "published" : "source-time", verify: verifySourceAndOutput
            )
            if let publishedJournal {
                // MP4가 안정적으로 검증된 경우에만 발행 증거를 후보에 붙인다. 작업자가 새 작업 표시 아래에서 다시 검증한 뒤
                // 썸네일만 만든다. 삭제는 하지 않는다. 원본이 WebDAV 시각 흔들림(같은 dev/ino/크기)이면 증거에 그 사실을
                // 명시하며, 이 경우에도 원본은 현재 상태 그대로 보존만 한다.
                if let verifiedOutput = publishedOutput {
                    let resume = LocalDiscoveredFile(
                        id: candidate.id, folderID: candidate.folderID, url: candidate.url,
                        relativePath: candidate.relativePath, relativeComponents: candidate.relativeComponents,
                        fileSize: candidate.fileSize, identity: candidate.identity,
                        publishedResume: LocalPublishedResumeProof(
                            record: publishedJournal, outputIdentity: verifiedOutput, sourceTimestampDrift: timestampDrift
                        )
                    )
                    let tempNote = ignoredJournalTemps.isEmpty
                        ? ""
                        : " · 같은 시도가 남긴 저널 임시 파일 \(ignoredJournalTemps.count)개는 읽기만 하고 그대로 둠"
                    throw RecoveryArchived(
                        kind: .publishedOutputResume,
                        detail: "발행된 MP4(크기·SHA-256 확인)와 기록이 맞아 이전 작업 표시만 \(method == .renamed ? "보관 이름으로 옮기고" : "보관 폴더에 복사·재확인한 뒤 활성 표시를 해제하고") 새 작업 표시 아래에서 썸네일 생성/확인만 이어서 진행함 (원본 보존, 삭제·재인코딩·MP4 덮어쓰기 없음)\(timestampDrift ? " · 원본은 파일 번호·크기가 같고 WebDAV 시각만 달라 현재 상태 그대로 보존" : "")\(tempNote)",
                        candidate: resume
                    )
                }
                throw RecoveryArchived(
                    kind: .publishedOutputKept,
                    detail: method == .renamed
                        ? "MP4 보존 · 썸네일/원본 정리 필요: 원본·MP4·발행 기록은 그대로 두었고 이전 작업 표시만 보관 이름으로 옮김 (완료 처리 아님)"
                        : "MP4 보존 · 썸네일/원본 정리 필요: 원본·MP4·발행 기록은 그대로 두었고 이전 작업 표시는 보관 폴더에 복사·재확인한 뒤 활성 표시만 해제함 (완료 처리 아님)",
                    candidate: nil
                )
            }
            throw RecoveryArchived(
                kind: .sourceTimestampChanged,
                detail: method == .renamed
                    ? "원본의 파일 번호·크기는 같고 WebDAV 시각만 달라 이전 작업 표시를 삭제 없이 보관하고 새 식별 값으로 다시 변환함 (원본은 변경하지 않음)"
                    : "원본의 파일 번호·크기는 같고 WebDAV 시각만 달라 이전 작업 표시를 보관 폴더에 복사·재확인한 뒤 활성 표시만 해제하고 새 식별 값으로 다시 변환함 (원본은 변경하지 않음)",
                candidate: candidate
            )
        }

        // ---- Mutation: ONLY the exact own names; owner last; rmdir only if empty; never recursive. ----
        func removeOwnFile(_ name: String) throws {
            var st = stat()
            if fstatat(claimFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                let err = errno
                if err == ENOENT { return }
                throw fail("정리 중 항목 확인 오류(\(name), errno \(err)): 일부만 정리되어 남겨 둠")
            }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                throw fail("정리 중 항목 형식이 달라짐(\(name)): 일부만 정리되어 남겨 둠")
            }
            if unlinkat(claimFD, name, 0) != 0 {
                let err = errno
                if err != ENOENT {
                    throw fail("정리 중 삭제 실패(\(name), errno \(err)): 일부만 정리되어 남겨 둠")
                }
            }
        }

        /// 빈 임시 사이드카: 바인딩된 dev/ino, 일반 파일, nlink 1, 크기 0이 그대로일 때만 삭제한다.
        func removeBoundEmptySidecar(_ name: String, _ id: NodeID) throws {
            var st = stat()
            if fstatat(claimFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                let err = errno
                if err == ENOENT { return }
                throw fail("정리 중 항목 확인 오류(\(name), errno \(err)): 일부만 정리되어 남겨 둠")
            }
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size == 0,
                  st.st_dev == id.dev, st.st_ino == id.ino else {
                throw fail("보조 파일(\(name))이 확인 후 바뀌어 남겨 둠")
            }
            if unlinkat(claimFD, name, 0) != 0 {
                let err = errno
                if err != ENOENT {
                    throw fail("정리 중 삭제 실패(\(name), errno \(err)): 일부만 정리되어 남겨 둠")
                }
            }
        }

        // 아무것도 지우기 전에 바인딩된 빈 사이드카를 먼저 모두 다시 확인해 부분 정리를 피한다.
        for (name, id) in boundEmptySidecars {
            guard emptyTempSidecarID(dirFD: claimFD, name: name) == id else {
                throw fail("보조 파일(\(name))이 확인 후 바뀌어 남겨 둠")
            }
        }

        let removable = [hbTmpName, hbFileName] + appleDoubleNames
        for name in removable where names.contains(name) {
            if let id = boundEmptySidecars[name] {
                try removeBoundEmptySidecar(name, id)
            } else {
                try removeOwnFile(name)
            }
        }
        try removeOwnFile(ownerFileName)
        _ = fsync(claimFD)

        Darwin.close(claimFD)
        claimFD = -1

        if unlinkat(containerFD, claimName, AT_REMOVEDIR) != 0 {
            let err = errno
            throw fail("작업 표시 폴더 삭제 실패 (errno \(err)): 폴더가 비어 있지 않거나 읽기 전용일 수 있어 남겨 둠")
        }
        _ = fsync(containerFD)

        var relativeComponents = context.components
        relativeComponents.append(sourceName)
        var url = context.folder.url
        for component in relativeComponents {
            url.appendPathComponent(component)
        }
        return LocalDiscoveredFile(
            folderID: context.folder.id,
            url: url,
            relativePath: relativeComponents.joined(separator: "/"),
            relativeComponents: relativeComponents,
            fileSize: sourceNow.size,
            identity: sourceNow
        )
    }
}

// MARK: - Known Failed Publication Resume (candidate-local, read-only)

extension LocalConversionRecovery {
    private enum KnownResumeOutcome {
        case skip(String?)
        case candidate(LocalDiscoveredFile)
    }

    /// Read-only inspection of originals whose LATEST history record is a failure and that already have a published MP4 plus
    /// a valid schema-2 published/deleting journal but NO active claim (e.g. an earlier resume failed and dropped its claim).
    /// Only the listed candidates' own directories are listed; no tree scan, no claim is created or faked, nothing is written.
    /// A candidate is produced only when: the journal is the single, exactly matching one (unknown/conflicting journal, stage or
    /// `_원본` names block); the original's dev/inode/size equal the journal (mtime may differ ONLY on a real webdav mount, the
    /// original is then just kept); and the MP4 is a regular file of the journal size. The MP4 content is NOT read here: the candidate
    /// is "unverified" (`outputHashVerifiedByRecovery == false`) and the worker proves the full SHA-256 against the journal under a NEW
    /// shared claim before trusting the MP4 or writing any thumbnail, and never deletes anything.
    static func inspectKnownPublishedResume(
        targets: [LocalRetryTarget],
        folders: [LocalFolderItem],
        pins: [UUID: NASPinnedRoot]
    ) -> LocalRetryInspection {
        var out = LocalRetryInspection()
        var seenKeys = Set<String>()
        var namesCache: [String: Set<String>] = [:]

        for target in targets {
            guard let folder = folders.first(where: { $0.id == target.folderID }),
                  let components = LocalConversionRetryInspector.validatedComponents(target.components),
                  let fileName = components.last,
                  let pin = pins[folder.id] else { continue }
            let key = "\(folder.id.uuidString)/\(components.joined(separator: "/"))"
            guard seenKeys.insert(key).inserted else { continue }
            do {
                let outcome = try pin.withDirectoryFD { rootFD in
                    try knownPublishedResume(rootFD: rootFD, folder: folder, components: components, namesCache: &namesCache, cacheKey: folder.id.uuidString)
                }
                switch outcome {
                case .candidate(let file): out.candidates.append(file)
                case .skip(let note): if let note { out.notes.append("\(fileName): \(note)") }
                }
            } catch let protect as RecoveryProtect {
                out.notes.append("\(fileName): 이전 MP4는 보존하고 이어서 진행하지 않음: \(protect.reason)")
            } catch {
                out.errors.append("\(fileName): \(error.localizedDescription)")
            }
        }
        return out
    }

    private static func knownPublishedResume(
        rootFD: Int32,
        folder: LocalFolderItem,
        components: [String],
        namesCache: inout [String: Set<String>],
        cacheKey: String
    ) throws -> KnownResumeOutcome {
        guard let sourceName = components.last, let parts = validatedSourceParts(sourceName) else {
            return .skip(nil)
        }
        let parentFD = try NASPinnedFS.openDirectoryChain(rootFD, Array(components.dropLast()), create: false)
        defer { Darwin.close(parentFD) }
        var rootStat = stat()
        var parentStat = stat()
        guard fstat(rootFD, &rootStat) == 0, fstat(parentFD, &parentStat) == 0, parentStat.st_dev == rootStat.st_dev else {
            throw fail("다른 파일시스템으로 이어진 폴더라 확인하지 않음")
        }

        let finalName = "\(parts.stem).\(LocalConversionConstants.finalExtension)"
        let backupName = "\(parts.stem)\(LocalConversionConstants.backupSuffix).\(parts.ext)"
        var st = stat()
        guard fstatat(parentFD, finalName, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            return .skip(nil)   // no MP4: the regular retry inspection owns this file
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw fail("MP4가 일반 파일이 아님") }
        if fstatat(parentFD, backupName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            throw fail("보존 이름 파일(\(backupName))이 있음")
        }
        guard errno == ENOENT else { throw fail("보존 이름 확인 실패 (errno \(errno))") }

        let parentKey = "\(cacheKey)/\(components.dropLast().joined(separator: "/"))"
        let parentNames: Set<String>
        if let cached = namesCache[parentKey] {
            parentNames = cached
        } else {
            parentNames = Set(try listEntries(of: parentFD).map(\.name))
            namesCache[parentKey] = parentNames
        }
        let journalPrefix = ".\(parts.stem).journal-"
        guard parentNames.contains(where: { $0.hasPrefix(journalPrefix) }) else { return .skip(nil) }

        let sourceFD = openat(parentFD, sourceName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard sourceFD >= 0 else {
            if errno == ENOENT { return .skip("원본이 없어 완료 또는 불확실한 상태로 보고 남겨 둠") }
            throw fail("원본 열기 실패 (errno \(errno))")
        }
        defer { Darwin.close(sourceFD) }
        let sourceIdentity = try guarded("원본 파일 확인") { try LocalFileIdentity.inspect(fd: sourceFD) }
        let sourceIsWebDAV = filesystemName(fd: sourceFD) == "webdav"
        // A real webdav mount may show other mtime/ctime for the same file on every read; the original is only kept here, so there
        // dev/inode/size bind it. Elsewhere the exact identity is still required.
        func sameSource(_ other: LocalFileIdentity?) -> Bool {
            guard let other else { return false }
            return other == sourceIdentity || (sourceIsWebDAV && other.isSameFile(as: sourceIdentity))
        }
        guard sameSource(try? LocalFileIdentity.inspect(dirFD: parentFD, name: sourceName)) else {
            throw fail("원본 항목이 열린 파일과 달라 남겨 둠")
        }

        let verified = try verifyPublishedJournal(
            parentFD: parentFD, parentNames: parentNames, journalPrefix: journalPrefix, stem: parts.stem,
            sourceName: sourceName, sourceDevice: Int64(sourceIdentity.device), sourceInode: UInt64(sourceIdentity.inode),
            sourceSize: sourceIdentity.size, expectedOutput: finalName, expectedBackup: backupName
        )
        let record = verified.record
        let timestampDrift = Int64(sourceIdentity.mtime) != record.sourceMtime
        if timestampDrift, !sourceIsWebDAV {
            throw fail("원본 수정 시각이 기록과 달라(WebDAV 아님) 남겨 둠")
        }

        // Unverified candidate: no full SHA-256 read here (it used to block the first job for minutes). Only the cheap journal
        // facts are matched (regular file, size). The worker re-proves the full SHA-256 against the journal under its own claim
        // BEFORE any thumbnail write; a wrong hash there fails without writing anything.
        let output = try guarded("발행된 MP4 항목 확인") { try LocalFileIdentity.inspect(dirFD: parentFD, name: finalName) }
        guard output.size == record.outputSize else {
            throw fail("MP4 크기가 기록과 달라 남겨 둠(기록 \(record.outputSize)바이트, 실제 \(output.size)바이트)")
        }
        let outputIsWebDAV = filesystemName(fd: parentFD) == "webdav"
        guard let outputNow = try? LocalFileIdentity.inspect(dirFD: parentFD, name: finalName),
              outputNow == output || (outputIsWebDAV && outputNow.isSameFile(as: output)),
              sameSource(try? LocalFileIdentity.inspect(fd: sourceFD)),
              sameSource(try? LocalFileIdentity.inspect(dirFD: parentFD, name: sourceName)) else {
            throw fail("확인하는 사이 원본 또는 MP4가 바뀌어 남겨 둠")
        }

        var url = folder.url
        for component in components { url.appendPathComponent(component) }
        return .candidate(LocalDiscoveredFile(
            folderID: folder.id,
            url: url,
            relativePath: components.joined(separator: "/"),
            relativeComponents: components,
            fileSize: sourceIdentity.size,
            identity: sourceIdentity,
            publishedResume: LocalPublishedResumeProof(
                record: record, outputIdentity: output, sourceTimestampDrift: timestampDrift, outputHashVerifiedByRecovery: false
            )
        ))
    }
}

// MARK: - Fresh Targeted Retry Inspection

struct LocalRetryTarget: Sendable, Hashable {
    let folderID: UUID
    let components: [String]
}

struct LocalRetryInspection: Sendable {
    var candidates: [LocalDiscoveredFile] = []
    var errors: [String] = []
    var notes: [String] = []
}

enum LocalConversionRetryInspector {
    /// Strict component check for names that came from persisted history (never trusted as-is).
    static func validatedComponents(_ components: [String]) -> [String]? {
        guard !components.isEmpty, components.count <= 64,
              let checked = try? NASPathSecurity.checkedComponents(components) else { return nil }
        for component in checked {
            if component.hasPrefix(".") || component.contains(LocalConversionConstants.excludedOriginalMarker) { return nil }
        }
        guard let fileName = checked.last else { return nil }
        let ns = fileName as NSString
        guard !ns.deletingPathExtension.isEmpty,
              LocalConversionConstants.supportedLegacyExtensions.contains(ns.pathExtension.lowercased()) else { return nil }
        return checked
    }

    /// Blocking: call strictly off the MainActor. `pins` are duplicated pinned roots owned by the caller for the whole
    /// operation. URLs are rebuilt from the selected folder and the validated components; fresh identities are read now.
    static func inspect(
        targets: [LocalRetryTarget],
        folders: [LocalFolderItem],
        pins: [UUID: NASPinnedRoot]
    ) -> LocalRetryInspection {
        var out = LocalRetryInspection()
        var seenKeys = Set<String>()
        var seenIdentities = Set<String>()

        for target in targets {
            guard let folder = folders.first(where: { $0.id == target.folderID }) else {
                out.notes.append("\(target.components.last ?? "?"): 연결된 작업 폴더가 없어 건너뜀")
                continue
            }
            guard let components = validatedComponents(target.components), let fileName = components.last else {
                out.notes.append("\(target.components.last ?? "?"): 기록된 경로가 올바르지 않아 건너뜀")
                continue
            }
            let key = "\(folder.id.uuidString)/\(components.joined(separator: "/"))"
            guard seenKeys.insert(key).inserted else { continue }
            guard let pin = pins[folder.id] else {
                out.errors.append("\(fileName): 폴더 연결을 열지 못해 확인하지 못했습니다.")
                continue
            }

            do {
                let found = try pin.withDirectoryFD { rootFD -> (LocalDiscoveredFile?, String?) in
                    let parentComponents = Array(components.dropLast())
                    let parentFD = try NASPinnedFS.openDirectoryChain(rootFD, parentComponents, create: false)
                    defer { Darwin.close(parentFD) }

                    var rootStat = stat()
                    var parentStat = stat()
                    guard fstat(rootFD, &rootStat) == 0, fstat(parentFD, &parentStat) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "폴더 상태 확인 실패 (errno \(errno))"])
                    }
                    guard parentStat.st_dev == rootStat.st_dev else {
                        throw NSError(domain: "LocalConversionError", code: 41, userInfo: [NSLocalizedDescriptionKey: "다른 파일시스템으로 이어진 폴더라 확인하지 않았습니다."])
                    }

                    let ns = fileName as NSString
                    let stem = ns.deletingPathExtension
                    let finalName = "\(stem).\(LocalConversionConstants.finalExtension)"
                    let backupName = "\(stem)\(LocalConversionConstants.backupSuffix).\(ns.pathExtension)"

                    var st = stat()
                    if fstatat(parentFD, finalName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                        return (nil, "MP4가 이미 있어 건너뜀")
                    }
                    guard errno == ENOENT else {
                        let err = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "MP4 존재 여부 확인 실패 (errno \(err))"])
                    }
                    if fstatat(parentFD, backupName, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                        return (nil, "보존 이름 파일이 있어 건너뜀")
                    }
                    guard errno == ENOENT else {
                        let err = errno
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "보존 이름 확인 실패 (errno \(err))"])
                    }

                    let identity: LocalFileIdentity
                    do {
                        identity = try LocalFileIdentity.inspect(dirFD: parentFD, name: fileName)
                    } catch {
                        let ns = error as NSError
                        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) {
                            return (nil, "원본이 더 이상 없어 건너뜀")
                        }
                        throw error
                    }

                    var url = folder.url
                    for component in components { url.appendPathComponent(component) }
                    let file = LocalDiscoveredFile(
                        folderID: folder.id,
                        url: url,
                        relativePath: components.joined(separator: "/"),
                        relativeComponents: components,
                        fileSize: identity.size,
                        identity: identity
                    )
                    return (file, nil)
                }

                if let file = found.0 {
                    let identityKey = "\(file.identity.device)/\(file.identity.inode)"
                    if seenIdentities.insert(identityKey).inserted {
                        out.candidates.append(file)
                    }
                } else if let note = found.1 {
                    out.notes.append("\(fileName): \(note)")
                }
            } catch {
                out.errors.append("\(fileName): \(error.localizedDescription)")
            }
        }
        return out
    }
}
