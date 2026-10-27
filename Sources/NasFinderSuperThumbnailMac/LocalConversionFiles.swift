import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

// MARK: - Constants

enum LocalConversionConstants {
    /// Supported legacy video extensions aligned with ConversionEngine worker.py
    static let supportedLegacyExtensions: Set<String> = [
        "avi", "mkv", "wmv", "vob", "mpg", "mpeg",
        "asf", "mov", "flv", "mts", "m2ts", "ts",
        "3gp", "webm", "rm", "rmvb", "divx", "m4v"
    ]
    static let excludedOriginalMarker = "_원본"
    static let backupSuffix = "_원본"
    static let finalExtension = "mp4"
    static let handoffDirName = ".NasFinder-Handoff"
    static let vaultDirName = ".NasFinder-Vault"
    static let defaultsKey = "LocalConversion.rememberedFolders.v1"
    static let concurrencyDefaultsKey = "LocalConversion.concurrency.v1"
    static let maxRememberedFolders = 64
    static let defaultConcurrency = 2
}

// MARK: - Local Volume Status & Detection

enum LocalVolumeStatus: Equatable, Sendable {
    case localReady
    case notLocalVolume(String)
    case requiresSharedCoordination(String)
    case volumeMetadataUnavailable(String)

    var isReady: Bool {
        if case .localReady = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .localReady:
            return "변환 준비 완료"
        case .notLocalVolume(let reason):
            return "원격 볼륨 대기: \(reason)"
        case .requiresSharedCoordination(let reason):
            return "NAS 협업 대기: \(reason)"
        case .volumeMetadataUnavailable(let reason):
            return "볼륨 상태 확인 불가: \(reason)"
        }
    }
}

enum LocalVolumeDetector {
    struct VolCapabilitiesBuffer {
        var length: UInt32 = 0
        var capabilities: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var valid: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
    }

    /// Read-only descriptor-bound check using fgetattrlist for ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES.
    /// Requires VOL_CAP_INT_RENAME_EXCL (0x00080000) to be both VALID and supported.
    static func verifyRenameExclusionCapability(at path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = UInt16(5) // ATTR_BIT_MAP_COUNT
        attrList.volattr = attrgroup_t(UInt32(0x80000000) | UInt32(0x00020000)) // ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES

        var buf = VolCapabilitiesBuffer()
        let ret = fgetattrlist(fd, &attrList, &buf, MemoryLayout<VolCapabilitiesBuffer>.size, 0)
        guard ret == 0 else { return false }

        let renameExcl = UInt32(0x00080000) // VOL_CAP_INT_RENAME_EXCL
        // capabilities.1 and valid.1 correspond to VOL_CAPABILITIES_INTERFACES
        let isValid = (buf.valid.1 & renameExcl) != 0
        let isSupported = (buf.capabilities.1 & renameExcl) != 0
        return isValid && isSupported
    }

    /// Inspect only the selected volume off MainActor. Mounted SMB uses the common
    /// per-file claim and the existing vault publication protocol; stale handoff
    /// metadata never requires an active NAS job. Other volumes retain capability checks.
    static func inspectVolume(at url: URL) async -> LocalVolumeStatus {
        await Task.detached(priority: .userInitiated) {
            let path = url.path
            guard !path.isEmpty else {
                return .volumeMetadataUnavailable("경로가 비어 있습니다.")
            }

            // 2. Kernel statfs metadata verification
            var fs = statfs()
            guard statfs(path, &fs) == 0 else {
                let err = errno
                return .volumeMetadataUnavailable("statfs 조회 실패 (errno \(err))")
            }

            // Mounted SMB uses the same per-file claim and atomic publication as the vault.
            // An old handoff marker must not make Mac encoding depend on a running NAS job.
            if isDirectClaimNetworkFilesystem(fs) {
                return .localReady
            }

            // 3. Verify exclusive atomic rename capability (fgetattrlist ATTR_VOL_CAPABILITIES)
            let hasRenameExcl = verifyRenameExclusionCapability(at: path)
            guard hasRenameExcl else {
                // Unsupported filesystem: absence of NAS marker must not magically make unsupported FS local.
                return .notLocalVolume("배타적 원자적 파일 연산(RENAME_EXCL)을 지원하지 않는 볼륨입니다.")
            }

            let isLocalFlag = (fs.f_flags & UInt32(MNT_LOCAL)) != 0
            if !isLocalFlag {
                // Known suitable mounted SMB with valid+support can use DIRECT route + commonclaim
                if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
                   let isLocal = values.volumeIsLocal, !isLocal {
                    return .localReady
                }
            }

            return .localReady
        }.value
    }

    /// smbfs and webdav mounts use the common per-file claim directly, without NAS marker/job.
    static func isDirectClaimNetworkFilesystem(_ fs: statfs) -> Bool {
        let name = withUnsafeBytes(of: fs.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name == "smbfs" || name == "webdav"
    }

    /// Available bytes on the volume containing the given URL.
    static func availableCapacityBytes(for url: URL) -> Int64? {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return nil }
        // smbfs/webdav that report no quota (total blocks 0) are unknown, not full.
        if isDirectClaimNetworkFilesystem(fs), fs.f_blocks == 0 { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
}

// MARK: - Remembered Folder Record & Store

struct LocalRememberedFolderRecord: Codable, Equatable, Sendable {
    var id: UUID
    var bookmark: Data
    var addedDate: Date
    var lastPath: String

    init(id: UUID = UUID(), bookmark: Data, addedDate: Date = Date(), lastPath: String) {
        self.id = id
        self.bookmark = bookmark
        self.addedDate = addedDate
        self.lastPath = lastPath
    }
}

struct LocalFolderItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let addedDate: Date
    var status: LocalVolumeStatus
    var isScopeStarted: Bool

    init(
        id: UUID = UUID(),
        url: URL,
        addedDate: Date = Date(),
        status: LocalVolumeStatus = .localReady,
        isScopeStarted: Bool = false
    ) {
        self.id = id
        self.url = url
        self.addedDate = addedDate
        self.status = status
        self.isScopeStarted = isScopeStarted
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var path: String {
        url.path
    }
}

enum LocalRememberedFolderStore {
    static func loadRecords() -> [LocalRememberedFolderRecord] {
        guard let data = UserDefaults.standard.data(forKey: LocalConversionConstants.defaultsKey),
              let records = try? JSONDecoder().decode([LocalRememberedFolderRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func saveRecords(_ records: [LocalRememberedFolderRecord]) {
        let trimmed = Array(records.prefix(LocalConversionConstants.maxRememberedFolders))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: LocalConversionConstants.defaultsKey)
        }
    }

    static func createBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolveRecord(_ record: LocalRememberedFolderRecord) -> (url: URL?, scopeStarted: Bool, refreshedBookmark: Data?) {
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return (nil, false, nil)
        }

        let scopeStarted = resolvedURL.startAccessingSecurityScopedResource()
        var refreshedBookmark: Data? = nil
        if isStale {
            refreshedBookmark = createBookmark(for: resolvedURL)
        }
        return (resolvedURL, scopeStarted, refreshedBookmark)
    }
}

// MARK: - File Identity & Discovery

struct LocalFileIdentity: Hashable, Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let mtime: time_t
    let mtime_nsec: Int
    let ctime: time_t
    let ctime_nsec: Int

    var mtimeNanoseconds: Int64 {
        Int64(mtime) * 1_000_000_000 + Int64(mtime_nsec)
    }

    init(
        device: dev_t,
        inode: ino_t,
        size: Int64,
        mtime: time_t,
        mtime_nsec: Int = 0,
        ctime: time_t = 0,
        ctime_nsec: Int = 0
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.mtime = mtime
        self.mtime_nsec = mtime_nsec
        self.ctime = ctime
        self.ctime_nsec = ctime_nsec
    }

    static func inspect(fd: Int32) throws -> LocalFileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "fstat 실패 (errno \(err))"])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "LocalConversionError", code: 2, userInfo: [NSLocalizedDescriptionKey: "일반 파일이 아닙니다."])
        }
        guard info.st_nlink == 1 else {
            throw NSError(domain: "LocalConversionError", code: 3, userInfo: [NSLocalizedDescriptionKey: "다중 링크 파일(nlink > 1)은 원본 보호를 위해 건너뜁니다: 링크 수 \(info.st_nlink)"])
        }
        return LocalFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            mtime: info.st_mtimespec.tv_sec,
            mtime_nsec: Int(info.st_mtimespec.tv_nsec),
            ctime: info.st_ctimespec.tv_sec,
            ctime_nsec: Int(info.st_ctimespec.tv_nsec)
        )
    }

    static func inspect(dirFD: Int32, name: String) throws -> LocalFileIdentity {
        var info = stat()
        guard fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "fstatat 실패 (errno \(err)): \(name)"])
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw NSError(domain: "LocalConversionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "심볼릭 링크는 보안상 지원되지 않습니다: \(name)"])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "LocalConversionError", code: 2, userInfo: [NSLocalizedDescriptionKey: "일반 파일이 아닙니다: \(name)"])
        }
        guard info.st_nlink == 1 else {
            throw NSError(domain: "LocalConversionError", code: 3, userInfo: [NSLocalizedDescriptionKey: "다중 링크 파일(nlink > 1)은 원본 보호를 위해 건너뜁니다: \(name)"])
        }
        return LocalFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            mtime: info.st_mtimespec.tv_sec,
            mtime_nsec: Int(info.st_mtimespec.tv_nsec),
            ctime: info.st_ctimespec.tv_sec,
            ctime_nsec: Int(info.st_ctimespec.tv_nsec)
        )
    }

    static func inspect(path: String) throws -> LocalFileIdentity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "lstat 실패 (errno \(err))"])
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw NSError(domain: "LocalConversionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "심볼릭 링크는 보안상 지원되지 않습니다: \(path)"])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "LocalConversionError", code: 2, userInfo: [NSLocalizedDescriptionKey: "일반 파일이 아닙니다: \(path)"])
        }
        guard info.st_nlink == 1 else {
            throw NSError(domain: "LocalConversionError", code: 3, userInfo: [NSLocalizedDescriptionKey: "다중 링크 파일(nlink > 1)은 원본 보호를 위해 건너뜁니다: \(path)"])
        }
        return LocalFileIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            size: info.st_size,
            mtime: info.st_mtimespec.tv_sec,
            mtime_nsec: Int(info.st_mtimespec.tv_nsec),
            ctime: info.st_ctimespec.tv_sec,
            ctime_nsec: Int(info.st_ctimespec.tv_nsec)
        )
    }
}

struct LocalDiscoveredFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let folderID: UUID
    let url: URL
    let relativePath: String
    let relativeComponents: [String]
    let fileSize: Int64
    let identity: LocalFileIdentity

    init(
        id: UUID = UUID(),
        folderID: UUID,
        url: URL,
        relativePath: String,
        relativeComponents: [String],
        fileSize: Int64,
        identity: LocalFileIdentity
    ) {
        self.id = id
        self.folderID = folderID
        self.url = url
        self.relativePath = relativePath
        self.relativeComponents = relativeComponents
        self.fileSize = fileSize
        self.identity = identity
    }
}

// MARK: - Retained Incremental Folder Cursor

/// Retained incremental directory cursor for on-demand candidate discovery.
/// Avoids materializing whole-folder file queues or shared pending/done manifests.
/// Pulls candidates one at a time as conversion capacity becomes available.
final class LocalIncrementalFolderCursor: @unchecked Sendable {
    let folderID: UUID
    let rootURL: URL

    private let lock = NSLock()
    private var enumerator: FileManager.DirectoryEnumerator?
    private var isStarted = false
    private(set) var isExhausted = false
    private(set) var lastError: String? = nil

    init(folderID: UUID, rootURL: URL) {
        self.folderID = folderID
        self.rootURL = rootURL.standardizedFileURL
    }

    /// Resets the cursor to restart traversal on a new conversion pass.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        enumerator = nil
        isStarted = false
        isExhausted = false
        lastError = nil
    }

    /// Pulls ONE eligible legacy video candidate off MainActor.
    /// Returns nil when exhausted, on error, or when no eligible candidate remains.
    func pullNextCandidate(
        activeIdentities: Set<LocalFileIdentity>,
        failedIdentitiesInPass: Set<LocalFileIdentity>
    ) async -> LocalDiscoveredFile? {
        await Task.detached(priority: .userInitiated) { [self] () -> LocalDiscoveredFile? in
            self.lock.lock()
            defer { self.lock.unlock() }

            if self.isExhausted || self.lastError != nil {
                return nil
            }

            if !self.isStarted {
                self.isStarted = true
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: self.rootURL.path) else {
                    self.lastError = "폴더 경로를 찾을 수 없습니다: \(self.rootURL.lastPathComponent)"
                    return nil
                }

                guard let dirEnum = fileManager.enumerator(
                    at: self.rootURL,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                        .isDirectoryKey,
                        .fileSizeKey,
                        .contentModificationDateKey
                    ],
                    options: [.skipsPackageDescendants]
                ) else {
                    self.lastError = "폴더 탐색기를 열 수 없습니다: \(self.rootURL.lastPathComponent)"
                    return nil
                }
                self.enumerator = dirEnum
            }

            guard let enumerator = self.enumerator else {
                return nil
            }

            let rootPath = self.rootURL.path
            let fileManager = FileManager.default

            while let fileURL = enumerator.nextObject() as? URL {
                let relativePath: String
                if fileURL.path.hasPrefix(rootPath) {
                    let dropCount = rootPath.hasSuffix("/") ? rootPath.count : rootPath.count + 1
                    relativePath = String(fileURL.path.dropFirst(dropCount))
                } else {
                    relativePath = fileURL.lastPathComponent
                }

                let components = relativePath.split(separator: "/").map(String.init)

                // Validate components using lexical helper
                guard let checkedComponents = try? NASPathSecurity.checkedComponents(components) else {
                    continue
                }

                // Exclude hidden control/cache folders and files (starting with '.')
                if checkedComponents.contains(where: { $0.hasPrefix(".") }) {
                    if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Exclude paths containing '_원본'
                if checkedComponents.contains(where: { $0.contains(LocalConversionConstants.excludedOriginalMarker) }) {
                    if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Exclude vaults (.NasFinder-Vault, .NasFinder-Handoff)
                if checkedComponents.contains(where: { $0 == LocalConversionConstants.vaultDirName || $0 == LocalConversionConstants.handoffDirName }) {
                    if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) {
                    if values.isDirectory == true {
                        continue
                    }
                    if values.isSymbolicLink == true {
                        continue
                    }
                    guard values.isRegularFile == true else {
                        continue
                    }
                }

                // Exclude .mp4 (already final/MP4 format)
                let ext = fileURL.pathExtension.lowercased()
                guard ext != LocalConversionConstants.finalExtension else {
                    continue
                }

                // Only supported legacy video formats
                guard LocalConversionConstants.supportedLegacyExtensions.contains(ext) else {
                    continue
                }

                // Conflict pre-check in parent directory:
                // If stem.mp4 or stem_원본.ext already exists, skip
                let fileName = fileURL.lastPathComponent
                let stem = (fileName as NSString).deletingPathExtension
                let originalExt = (fileName as NSString).pathExtension
                guard !stem.isEmpty, !originalExt.isEmpty else { continue }

                let parentDir = fileURL.deletingLastPathComponent()
                let finalURL = parentDir.appendingPathComponent("\(stem).\(LocalConversionConstants.finalExtension)")
                if fileManager.fileExists(atPath: finalURL.path) {
                    continue
                }

                let backupURL = parentDir.appendingPathComponent("\(stem)\(LocalConversionConstants.backupSuffix).\(originalExt)")
                if fileManager.fileExists(atPath: backupURL.path) {
                    continue
                }

                // Strict lstat to verify regular file and capture stable identity
                guard let identity = try? LocalFileIdentity.inspect(path: fileURL.path) else {
                    continue
                }

                // Skip if currently active in another conversion slot
                if activeIdentities.contains(identity) {
                    continue
                }

                // Skip if previously failed in the current pass (do not reattempt indefinitely)
                if failedIdentitiesInPass.contains(identity) {
                    continue
                }

                // Found ONE eligible candidate
                return LocalDiscoveredFile(
                    folderID: self.folderID,
                    url: fileURL,
                    relativePath: relativePath,
                    relativeComponents: checkedComponents,
                    fileSize: identity.size,
                    identity: identity
                )
            }

            self.isExhausted = true
            return nil
        }.value
    }
}

// MARK: - Kernel Advisory Locking & Mutual Exclusion

final class LocalFileLock: @unchecked Sendable {
    let fd: Int32
    let parentFD: Int32
    let fileName: String
    let identity: LocalFileIdentity
    let relativeComponents: [String]
    private let lock = NSLock()
    private var released = false

    fileprivate init(
        fd: Int32,
        parentFD: Int32,
        fileName: String,
        identity: LocalFileIdentity,
        relativeComponents: [String]
    ) {
        self.fd = fd
        self.parentFD = parentFD
        self.fileName = fileName
        self.identity = identity
        self.relativeComponents = relativeComponents
    }

    func unlock() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        _ = flock(fd, LOCK_UN)
        Darwin.close(fd)
        Darwin.close(parentFD)
        LocalFileLockManager.shared.removeInProcessLock(identity)
    }

    deinit {
        unlock()
    }
}

final class LocalFileLockManager: @unchecked Sendable {
    static let shared = LocalFileLockManager()

    private let lock = NSLock()
    private var inProcessLocks: Set<LocalFileIdentity> = []

    private init() {}

    private static func isDirectClaimNetworkFD(_ fd: Int32) -> Bool {
        var volume = statfs()
        return fstatfs(fd, &volume) == 0 && LocalVolumeDetector.isDirectClaimNetworkFilesystem(volume)
    }

    fileprivate func removeInProcessLock(_ identity: LocalFileIdentity) {
        lock.lock()
        inProcessLocks.remove(identity)
        lock.unlock()
    }

    /// Acquires an in-process deduplication lock and a kernel-held advisory lock on the source file descriptor.
    /// Modifies no bytes or metadata of the original file; automatically released on close/process exit.
    func acquireLock(
        parentFD: Int32,
        fd: Int32,
        fileName: String,
        relativeComponents: [String]
    ) throws -> LocalFileLock {
        let identity: LocalFileIdentity
        do {
            identity = try LocalFileIdentity.inspect(fd: fd)
        } catch {
            Darwin.close(fd)
            Darwin.close(parentFD)
            throw error
        }

        lock.lock()
        if inProcessLocks.contains(identity) {
            lock.unlock()
            Darwin.close(fd)
            Darwin.close(parentFD)
            throw NSError(domain: "LocalConversionError", code: 2, userInfo: [NSLocalizedDescriptionKey: "동일 앱 인스턴스 내 다른 작업에서 이미 잠금 처리 중입니다."])
        }
        inProcessLocks.insert(identity)
        lock.unlock()

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            // WebDAV/SMB may reject advisory flock; only then the common per-file claim is the primary exclusion.
            if (err == ENOTSUP || err == EOPNOTSUPP) && Self.isDirectClaimNetworkFD(fd) {
                return LocalFileLock(
                    fd: fd,
                    parentFD: parentFD,
                    fileName: fileName,
                    identity: identity,
                    relativeComponents: relativeComponents
                )
            }
            removeInProcessLock(identity)
            Darwin.close(fd)
            Darwin.close(parentFD)
            if err == EWOULDBLOCK || err == EAGAIN {
                throw NSError(domain: "LocalConversionError", code: 3, userInfo: [NSLocalizedDescriptionKey: "다른 프로세스 또는 앱 인스턴스에서 이미 해당 파일을 잠그고 변환 중입니다."])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "커널 flock 잠금 실패 (errno \(err))"])
        }

        return LocalFileLock(
            fd: fd,
            parentFD: parentFD,
            fileName: fileName,
            identity: identity,
            relativeComponents: relativeComponents
        )
    }
}

// MARK: - Journaling, Publication & Recovery

/// Journal records. Schema 1 (staged/sourceRenamed/published) belongs to the retired `_원본` rename flow:
/// it is only ever read, never reinterpreted as deletion authorization.
/// Schema 2 records the keep-original-until-verified transaction (original keeps its name until the end).
struct LocalJournalRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        // schema 1 (read-only, legacy)
        case staged
        case sourceRenamed
        case published
        // schema 2
        case outputStaged      // MP4 staged next to the original; original untouched
        case outputPublished   // final MP4 exclusively published and verified; thumbnail/deletion pending
        case deletionStarted   // thumbnail verified; original unlink about to run or ran (outcome uncertain if crashed)
    }

    static let currentSchema = 2

    let schema: Int
    let attemptID: String
    let originalFileName: String
    let backupFileName: String
    let finalFileName: String
    let stagedFileName: String
    let sourceDevice: Int64
    let sourceInode: UInt64
    let sourceSize: Int64
    let sourceMtime: Int64
    let outputSize: Int64
    let outputSha256: String
    var state: State
    let createdAt: Date
    /// Vault thumbnail file name (schema 2, set once the thumbnail is verified).
    var thumbnailFileName: String?

    init(
        schema: Int = LocalJournalRecord.currentSchema,
        attemptID: String,
        originalFileName: String,
        backupFileName: String,
        finalFileName: String,
        stagedFileName: String,
        sourceDevice: Int64,
        sourceInode: UInt64,
        sourceSize: Int64,
        sourceMtime: Int64,
        outputSize: Int64,
        outputSha256: String,
        state: State,
        createdAt: Date = Date(),
        thumbnailFileName: String? = nil
    ) {
        self.schema = schema
        self.attemptID = attemptID
        self.originalFileName = originalFileName
        self.backupFileName = backupFileName
        self.finalFileName = finalFileName
        self.stagedFileName = stagedFileName
        self.sourceDevice = sourceDevice
        self.sourceInode = sourceInode
        self.sourceSize = sourceSize
        self.sourceMtime = sourceMtime
        self.outputSize = outputSize
        self.outputSha256 = outputSha256
        self.state = state
        self.createdAt = createdAt
        self.thumbnailFileName = thumbnailFileName
    }
}

/// Thrown when the outcome of the irreversible original deletion cannot be positively established.
/// The worker retains the private workspace (holds a verified copy of the original) and the claim/journal evidence.
struct LocalDeletionUncertainError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

/// Result of the verified, exclusive, durable MP4 publication (original still untouched).
struct LocalPublishedMP4: Sendable {
    let finalFileName: String
    let identity: LocalFileIdentity
    let record: LocalJournalRecord
}

/// Result of the verified Vault thumbnail for the published MP4.
struct LocalPublishedThumbnail: Sendable {
    let fileName: String
    let identity: LocalFileIdentity
    let vaultDevice: dev_t
    let vaultInode: ino_t
}

enum LocalPublicationManager {
    private static let vaultDirName = LocalConversionConstants.vaultDirName

    /// Publishers already hold the common per-output claim. SMB supports atomic rename,
    /// but not Darwin's RENAME_EXCL; use the vault's existing check-then-rename protocol.
    private static func renameClaimed(_ dirFD: Int32, _ source: String, _ destination: String) -> Int32 {
        if renameatx_np(dirFD, source, dirFD, destination, 0x00000004) == 0 {
            return 0
        }
        let exclusiveError = errno
        guard exclusiveError == ENOTSUP || exclusiveError == EOPNOTSUPP else {
            return -1
        }
        var volume = statfs()
        guard fstatfs(dirFD, &volume) == 0, LocalVolumeDetector.isDirectClaimNetworkFilesystem(volume) else {
            errno = exclusiveError
            return -1
        }
        var existing = stat()
        if fstatat(dirFD, destination, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            errno = EEXIST
            return -1
        }
        guard errno == ENOENT else { return -1 }
        return renameat(dirFD, source, dirFD, destination)
    }

    /// Flushes to stable storage: F_FULLFSYNC when supported, otherwise plain fsync. Failure means not durable.
    private static func fullSync(_ fd: Int32) -> Bool {
        if fcntl(fd, F_FULLFSYNC) == 0 { return true }
        return fsync(fd) == 0
    }

    private static func posixError(_ err: Int32, _ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "\(message) (errno \(err))"])
    }

    private static func conversionError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "LocalConversionError", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func journalName(stem: String, attemptID: String, suffix: String) -> String {
        ".\(stem).journal-\(attemptID)-\(suffix).json"
    }

    /// Writes the next-state journal exclusively, then removes the previous one and syncs the directory.
    private static func advanceJournal(
        _ record: LocalJournalRecord,
        to newName: String,
        replacing oldName: String,
        dirFD: Int32
    ) throws {
        try writeJournalRecord(record, fileName: newName, dirFD: dirFD)
        if unlinkat(dirFD, oldName, 0) != 0 && errno != ENOENT {
            throw posixError(errno, "이전 저널 정리 실패")
        }
        guard fullSync(dirFD) else {
            throw posixError(errno, "저널 갱신 디렉터리 sync 실패")
        }
    }

    /// Phase 1. Stages the engine-verified MP4 next to the original descriptor-relatively, verifies the active
    /// video claim, and exclusively publishes STEM.mp4 (no overwrite). The original keeps its own name:
    /// nothing is renamed to `_원본`. Afterwards the published file is re-opened, re-hashed and identity-bound.
    /// Any failure after the publication rename retains the valid final MP4, journal and claim.
    static func publishMP4(
        sourceLock: LocalFileLock,
        engineOutputURL: URL,
        outputExpectedSize: Int64,
        outputExpectedSha256: String,
        attemptID: String,
        claim: VideoConversionClaim? = nil,
        onCopyProgress: (@Sendable (Double) -> Void)? = nil
    ) throws -> LocalPublishedMP4 {
        let dirFD = sourceLock.parentFD
        let originalFileName = sourceLock.fileName
        let stem = (originalFileName as NSString).deletingPathExtension
        let ext = (originalFileName as NSString).pathExtension
        guard !stem.isEmpty, !ext.isEmpty else {
            throw conversionError(20, "유효하지 않은 원본 파일 이름입니다.")
        }
        guard ext.lowercased() != LocalConversionConstants.finalExtension else {
            throw conversionError(21, "MP4 원본은 변환/삭제 대상이 아닙니다.")
        }

        // The Mac flow never creates this name; an existing entry is a conflict signal and stays untouched.
        let backupFileName = "\(stem)\(LocalConversionConstants.backupSuffix).\(ext)"
        let finalFileName = "\(stem).\(LocalConversionConstants.finalExtension)"
        let stagedFileName = ".\(stem).stage-\(attemptID).mp4"
        let stagedJournalName = journalName(stem: stem, attemptID: attemptID, suffix: "staged")
        let publishedJournalName = journalName(stem: stem, attemptID: attemptID, suffix: "published")

        // Validate all single-component names
        _ = try NASPathSecurity.checkedComponents([
            originalFileName,
            backupFileName,
            finalFileName,
            stagedFileName,
            stagedJournalName,
            publishedJournalName
        ])

        // 1. Collision pre-check: fail closed if a `_원본` leftover or the final name already exists
        var statBuf = stat()
        if fstatat(dirFD, backupFileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0 {
            throw NSError(domain: "LocalConversionError", code: 10, userInfo: [NSLocalizedDescriptionKey: "보존 파일 이름(\(backupFileName))이 이미 존재합니다. 원본 보호를 위해 건너뜁니다."])
        }
        if fstatat(dirFD, finalFileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0 {
            throw NSError(domain: "LocalConversionError", code: 11, userInfo: [NSLocalizedDescriptionKey: "최종 발행 대상 파일(\(finalFileName))이 이미 존재합니다. 원본 보호를 위해 건너뜁니다."])
        }
        if fstatat(dirFD, stagedFileName, &statBuf, AT_SYMLINK_NOFOLLOW) == 0 {
            throw NSError(domain: "LocalConversionError", code: 12, userInfo: [NSLocalizedDescriptionKey: "스테이징 파일이 이미 존재합니다."])
        }

        // 2. Verify source identity and directory entry match locked descriptor
        let currentFDIdentity = try LocalFileIdentity.inspect(fd: sourceLock.fd)
        guard currentFDIdentity == sourceLock.identity else {
            throw NSError(domain: "LocalConversionError", code: 13, userInfo: [NSLocalizedDescriptionKey: "원본 파일 식별 정보 변경 감지"])
        }

        let currentEntryIdentity = try LocalFileIdentity.inspect(dirFD: dirFD, name: originalFileName)
        guard currentEntryIdentity == sourceLock.identity else {
            throw NSError(domain: "LocalConversionError", code: 14, userInfo: [NSLocalizedDescriptionKey: "디렉터리 내 원본 파일이 다른 파일로 교체되었거나 수정되었습니다."])
        }

        // 3. Stage output MP4 descriptor-relative with O_CREAT | O_EXCL | O_NOFOLLOW
        let stagedFD = openat(dirFD, stagedFileName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard stagedFD >= 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "스테이징 파일 생성 실패 (errno \(err)): \(stagedFileName)"])
        }

        var stagedFDClosed = false
        func closeStagedFD() {
            if !stagedFDClosed && stagedFD >= 0 {
                stagedFDClosed = true
                Darwin.close(stagedFD)
            }
        }

        var copyError: Error? = nil
        do {
            let engineHandle = try FileHandle(forReadingFrom: engineOutputURL)
            defer { try? engineHandle.close() }

            var hasher = SHA256()
            var totalBytes: Int64 = 0
            var lastReportedCopyPercent = -1
            while true {
                let chunk = try engineHandle.read(upToCount: 512 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                totalBytes += Int64(chunk.count)

                var written = 0
                try chunk.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    while written < raw.count {
                        let res = Darwin.write(stagedFD, base.advanced(by: written), raw.count - written)
                        if res <= 0 {
                            let err = errno
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "스테이징 파일 쓰기 실패 (errno \(err))"])
                        }
                        written += res
                    }
                }
                if let onCopyProgress, outputExpectedSize > 0 {
                    // flush/close/rename checks remain after the last byte, so never report 100% here.
                    let fraction = min(0.99, Double(totalBytes) / Double(outputExpectedSize))
                    let percent = Int(fraction * 100)
                    if percent > lastReportedCopyPercent {
                        lastReportedCopyPercent = percent
                        onCopyProgress(fraction)
                    }
                }
            }

            if !fullSync(stagedFD) {
                let err = errno
                closeStagedFD()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "스테이징 sync 실패 (errno \(err))"])
            }
            closeStagedFD()

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard totalBytes == outputExpectedSize, digest.lowercased() == outputExpectedSha256.lowercased() else {
                throw NSError(domain: "LocalConversionError", code: 15, userInfo: [NSLocalizedDescriptionKey: "스테이징 파일 크기 또는 SHA-256 불일치"])
            }
        } catch {
            copyError = error
        }

        if let copyError {
            closeStagedFD()
            unlinkat(dirFD, stagedFileName, 0)
            throw copyError
        }

        guard fullSync(dirFD) else {
            let err = errno
            unlinkat(dirFD, stagedFileName, 0)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "디렉터리 sync 실패 (errno \(err))"])
        }

        // 4. Write staged journal record (original untouched)
        let stagedJournal = LocalJournalRecord(
            attemptID: attemptID,
            originalFileName: originalFileName,
            backupFileName: backupFileName,
            finalFileName: finalFileName,
            stagedFileName: stagedFileName,
            sourceDevice: Int64(sourceLock.identity.device),
            sourceInode: UInt64(sourceLock.identity.inode),
            sourceSize: sourceLock.identity.size,
            sourceMtime: Int64(sourceLock.identity.mtime),
            outputSize: outputExpectedSize,
            outputSha256: outputExpectedSha256,
            state: .outputStaged
        )
        try writeJournalRecord(stagedJournal, fileName: stagedJournalName, dirFD: dirFD)

        // 5. Cancellation check before irreversible publication
        try Task.checkCancellation()

        // 6. Verify active claim identity and directory entry before publication
        if let claim {
            try claim.verifyClaimBeforePublication()
        }

        // Validate full source identity again immediately before publication, including nanosecond fields; keep source nlink1 admission
        guard let finalFDIdentity = try? LocalFileIdentity.inspect(fd: sourceLock.fd),
              finalFDIdentity == sourceLock.identity else {
            unlinkat(dirFD, stagedFileName, 0)
            unlinkat(dirFD, stagedJournalName, 0)
            throw conversionError(16, "발행 직전 원본 항목 식별 정보 변경 감지")
        }

        guard let finalEntryIdentity = try? LocalFileIdentity.inspect(dirFD: dirFD, name: originalFileName),
              finalEntryIdentity == sourceLock.identity else {
            unlinkat(dirFD, stagedFileName, 0)
            unlinkat(dirFD, stagedJournalName, 0)
            throw conversionError(16, "발행 직전 원본 디렉터리 항목 식별 정보 변경 감지")
        }

        claim?.markSourceMutationStarted()

        // 7. Exclusive no-overwrite publication of STEM.mp4 (Darwin RENAME_EXCL = 0x00000004). Original is NOT touched.
        if renameClaimed(dirFD, stagedFileName, finalFileName) != 0 {
            let renameErr = errno

            // Ambiguous I/O must retain all recovery evidence and claim. Cleanup/mutation flag reset is allowed
            // only when the staged entry is positively still present (rename did not happen) and the source is unchanged.
            var stagedStat = stat()
            let stagedStillPresent = fstatat(dirFD, stagedFileName, &stagedStat, AT_SYMLINK_NOFOLLOW) == 0
            let currentFDIdentity = try? LocalFileIdentity.inspect(fd: sourceLock.fd)
            let currentEntryIdentity = try? LocalFileIdentity.inspect(dirFD: dirFD, name: originalFileName)

            if stagedStillPresent,
               currentFDIdentity == sourceLock.identity,
               currentEntryIdentity == sourceLock.identity {
                let unlinkStagedRes = unlinkat(dirFD, stagedFileName, 0)
                let unlinkStagedErr = errno
                let unlinkJournalRes = unlinkat(dirFD, stagedJournalName, 0)
                let unlinkJournalErr = errno
                let syncOK = fullSync(dirFD)

                let stagedCleaned = (unlinkStagedRes == 0 || unlinkStagedErr == ENOENT)
                let journalCleaned = (unlinkJournalRes == 0 || unlinkJournalErr == ENOENT)
                if stagedCleaned && journalCleaned && syncOK {
                    claim?.resetSourceMutationStarted()
                }
            }
            // Otherwise: retain staged MP4, staged journal and claim as recovery evidence.

            throw posixError(renameErr, "최종 MP4 발행 실패 (원본은 그대로 보존됨)")
        }

        // From here the final MP4 exists: never roll it back; keep claim/journal evidence on any failure.
        guard fullSync(dirFD) else {
            throw posixError(errno, "최종 MP4 발행 후 디렉터리 sync 실패 (MP4는 발행되었을 수 있으며 원본은 보존됨)")
        }

        // 8. Independently verify the PUBLISHED entry: regular, nlink 1, exact size and SHA-256 re-read.
        let finalFD = openat(dirFD, finalFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard finalFD >= 0 else {
            throw posixError(errno, "발행된 MP4 열기 실패 (원본은 보존됨)")
        }
        defer { Darwin.close(finalFD) }

        let fdIdentity = try LocalFileIdentity.inspect(fd: finalFD)
        guard fdIdentity.size == outputExpectedSize else {
            throw conversionError(22, "발행된 MP4 크기 불일치 (원본은 보존됨)")
        }
        var finalHasher = SHA256()
        var finalTotal: Int64 = 0
        var readBuffer = [UInt8](repeating: 0, count: 512 * 1024)
        while true {
            try Task.checkCancellation()
            let n = readBuffer.withUnsafeMutableBytes { Darwin.read(finalFD, $0.baseAddress, $0.count) }
            if n < 0 {
                throw posixError(errno, "발행된 MP4 재검증 읽기 실패 (원본은 보존됨)")
            }
            if n == 0 { break }
            finalHasher.update(data: Data(readBuffer[0..<n]))
            finalTotal += Int64(n)
        }
        let finalDigest = finalHasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard finalTotal == outputExpectedSize, finalDigest.lowercased() == outputExpectedSha256.lowercased() else {
            throw conversionError(23, "발행된 MP4 SHA-256 재검증 불일치 (원본은 보존됨)")
        }
        let entryIdentity = try LocalFileIdentity.inspect(dirFD: dirFD, name: finalFileName)
        guard fdIdentity == entryIdentity else {
            throw conversionError(24, "발행된 MP4 디렉터리 항목 식별 정보 불일치 (원본은 보존됨)")
        }

        // 9. Journal -> outputPublished (final MP4 durable and verified; original untouched)
        var publishedJournal = stagedJournal
        publishedJournal.state = .outputPublished
        do {
            try advanceJournal(publishedJournal, to: publishedJournalName, replacing: stagedJournalName, dirFD: dirFD)
        } catch {
            throw conversionError(17, "저널 상태 갱신 실패 (\(error.localizedDescription)). 최종 MP4는 보존되었고 원본도 그대로입니다.")
        }

        return LocalPublishedMP4(finalFileName: finalFileName, identity: entryIdentity, record: publishedJournal)
    }

    /// Phase 2. Creates the Super Thumbnail from the actual published MP4 using the existing VaultProcessor
    /// algorithm and Vault file naming (fresh name/size/mtime of the NEW file). The JPEG is written
    /// descriptor-relatively with exclusive publication, then re-read and fully validated. A pre-existing
    /// artifact at the exact key is accepted only if it is itself a valid JPEG; zero-byte/corrupt entries fail closed.
    static func createVerifiedThumbnail(
        sourceLock: LocalFileLock,
        published: LocalPublishedMP4,
        finalURL: URL
    ) async throws -> LocalPublishedThumbnail {
        let dirFD = sourceLock.parentFD

        func verifyFinalUnchanged() throws {
            let current = try LocalFileIdentity.inspect(dirFD: dirFD, name: published.finalFileName)
            guard current == published.identity else {
                throw conversionError(25, "썸네일 생성 중 MP4 식별 정보가 변경되었습니다 (원본은 보존됨)")
            }
            // The URL used by AVFoundation must resolve to the very same file.
            let probeFD = open(finalURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard probeFD >= 0 else {
                throw posixError(errno, "MP4 경로 확인 실패 (원본은 보존됨)")
            }
            defer { Darwin.close(probeFD) }
            var st = stat()
            guard fstat(probeFD, &st) == 0,
                  st.st_dev == published.identity.device,
                  st.st_ino == published.identity.inode else {
                throw conversionError(26, "MP4 경로가 발행된 파일과 일치하지 않습니다 (원본은 보존됨)")
            }
        }

        try verifyFinalUnchanged()
        try Task.checkCancellation()

        // Fresh metadata of the NEW MP4 (never the old source identity).
        let values = try finalURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let freshSize = values.fileSize, Int64(freshSize) == published.identity.size,
              let freshMTime = values.contentModificationDate,
              abs(Int64(freshMTime.timeIntervalSince1970 * 1000) - published.identity.mtimeNanoseconds / 1_000_000) <= 1 else {
            throw conversionError(27, "MP4 최신 메타데이터 불일치 (원본은 보존됨)")
        }
        let thumbnailName = try NasFinderVaultCompatibility.thumbnailFilename(for: finalURL)
        _ = try NASPathSecurity.checkedComponents([vaultDirName, thumbnailName])

        // Vault directory, opened descriptor-relatively without following links.
        if mkdirat(dirFD, vaultDirName, 0o755) != 0 && errno != EEXIST {
            throw posixError(errno, "Vault 폴더 생성 실패 (원본은 보존됨)")
        }
        let vaultFD = openat(dirFD, vaultDirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard vaultFD >= 0 else {
            throw posixError(errno, "Vault 폴더 열기 실패 (원본은 보존됨)")
        }
        defer { Darwin.close(vaultFD) }
        var vaultStat = stat()
        guard fstat(vaultFD, &vaultStat) == 0, (vaultStat.st_mode & S_IFMT) == S_IFDIR else {
            throw conversionError(28, "Vault 폴더가 유효하지 않습니다 (원본은 보존됨)")
        }

        var existing = stat()
        if fstatat(vaultFD, thumbnailName, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw posixError(errno, "썸네일 항목 확인 실패 (원본은 보존됨)")
            }
            let data = try await VaultProcessor.videoThumbnailData(for: finalURL)
            try Task.checkCancellation()
            guard VaultProcessor.isValidJPEGThumbnail(data) else {
                throw VaultProcessorError.cannotEncode
            }
            try verifyFinalUnchanged()

            let tempName = ".upload-\(UUID().uuidString).tmp"
            let tmpFD = openat(vaultFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard tmpFD >= 0 else {
                throw posixError(errno, "썸네일 임시 파일 생성 실패 (원본은 보존됨)")
            }
            var written = 0
            var writeFailure: Error?
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while written < raw.count {
                    let res = Darwin.write(tmpFD, base.advanced(by: written), raw.count - written)
                    if res <= 0 {
                        writeFailure = posixError(errno, "썸네일 쓰기 실패")
                        return
                    }
                    written += res
                }
            }
            if writeFailure == nil, !fullSync(tmpFD) {
                writeFailure = posixError(errno, "썸네일 sync 실패")
            }
            Darwin.close(tmpFD)
            if let writeFailure {
                unlinkat(vaultFD, tempName, 0)
                throw writeFailure
            }
            if renameClaimed(vaultFD, tempName, thumbnailName) != 0 {
                let err = errno
                unlinkat(vaultFD, tempName, 0)
                // A concurrent client may have published the same key; it is validated below, never trusted.
                guard err == EEXIST else {
                    throw posixError(err, "썸네일 배타적 발행 실패 (원본은 보존됨)")
                }
            }
            guard fullSync(vaultFD), fullSync(dirFD) else {
                throw posixError(errno, "썸네일 디렉터리 sync 실패 (원본은 보존됨)")
            }
        }

        let thumbnailIdentity = try readValidatedThumbnail(vaultFD: vaultFD, name: thumbnailName)
        try verifyFinalUnchanged()

        return LocalPublishedThumbnail(
            fileName: thumbnailName,
            identity: thumbnailIdentity,
            vaultDevice: vaultStat.st_dev,
            vaultInode: vaultStat.st_ino
        )
    }

    /// Re-opens the thumbnail by exact name (no symlink), requires a regular nlink-1 nonempty file whose bytes
    /// are a complete decodable JPEG, and returns its identity.
    private static func readValidatedThumbnail(vaultFD: Int32, name: String) throws -> LocalFileIdentity {
        let fd = openat(vaultFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw posixError(errno, "생성된 썸네일 열기 실패 (원본은 보존됨)")
        }
        defer { Darwin.close(fd) }
        let identity = try LocalFileIdentity.inspect(fd: fd)
        guard identity.size > 0, identity.size <= Int64(VaultProcessor.maxThumbnailBytes) else {
            throw conversionError(29, "썸네일 크기가 유효하지 않습니다 (원본은 보존됨)")
        }
        var data = Data(capacity: Int(identity.size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                throw posixError(errno, "썸네일 읽기 실패 (원본은 보존됨)")
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > VaultProcessor.maxThumbnailBytes { break }
        }
        guard Int64(data.count) == identity.size, VaultProcessor.isValidJPEGThumbnail(data) else {
            throw conversionError(29, "썸네일이 손상되었거나 읽을 수 없는 JPEG입니다 (원본은 보존됨)")
        }
        return identity
    }

    /// Phase 3. Deletes ONLY this attempt's pinned original entry, after the final MP4 and its thumbnail are
    /// re-verified. Immediately before the unlink the claim, parent pin, original (fd + exact entry),
    /// final MP4 and thumbnail identities are rechecked. The MP4, `_원본` leftovers and other entries are never touched.
    /// Any outcome that cannot be positively established throws `LocalDeletionUncertainError` (evidence retained).
    static func deleteVerifiedOriginal(
        sourceLock: LocalFileLock,
        published: LocalPublishedMP4,
        thumbnail: LocalPublishedThumbnail,
        attemptID: String,
        claim: VideoConversionClaim?,
        verifyParentPinned: () throws -> Void
    ) throws {
        let dirFD = sourceLock.parentFD
        let originalFileName = sourceLock.fileName
        let stem = (originalFileName as NSString).deletingPathExtension
        let ext = (originalFileName as NSString).pathExtension
        guard !stem.isEmpty, !ext.isEmpty,
              ext.lowercased() != LocalConversionConstants.finalExtension,
              originalFileName != published.finalFileName,
              !originalFileName.contains("/"),
              !originalFileName.hasPrefix(".") else {
            throw conversionError(50, "원본 삭제 대상 이름이 유효하지 않아 삭제하지 않습니다.")
        }

        let publishedJournalName = journalName(stem: stem, attemptID: attemptID, suffix: "published")
        let deletingJournalName = journalName(stem: stem, attemptID: attemptID, suffix: "deleting")
        _ = try NASPathSecurity.checkedComponents([publishedJournalName, deletingJournalName])

        // Last cancellation point: after the deletion journal is written no cancellation is honoured.
        try Task.checkCancellation()

        // Recheck everything that can be rechecked without I/O ambiguity BEFORE the journal and unlink.
        func recheckAll() throws {
            try claim?.verifyClaimBeforeSourceDeletion()
            try verifyParentPinned()

            guard let finalIdentity = try? LocalFileIdentity.inspect(dirFD: dirFD, name: published.finalFileName),
                  finalIdentity == published.identity else {
                throw conversionError(52, "삭제 직전 MP4 식별 정보 변경 감지: 원본을 삭제하지 않습니다.")
            }

            let vaultFD = openat(dirFD, vaultDirName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard vaultFD >= 0 else {
                throw posixError(errno, "삭제 직전 Vault 폴더 확인 실패: 원본을 삭제하지 않습니다")
            }
            defer { Darwin.close(vaultFD) }
            var vaultStat = stat()
            guard fstat(vaultFD, &vaultStat) == 0,
                  vaultStat.st_dev == thumbnail.vaultDevice,
                  vaultStat.st_ino == thumbnail.vaultInode else {
                throw conversionError(53, "삭제 직전 Vault 폴더 변경 감지: 원본을 삭제하지 않습니다.")
            }
            let thumbIdentity = try readValidatedThumbnail(vaultFD: vaultFD, name: thumbnail.fileName)
            guard thumbIdentity == thumbnail.identity else {
                throw conversionError(54, "삭제 직전 썸네일 변경 감지: 원본을 삭제하지 않습니다.")
            }

            guard let fdIdentity = try? LocalFileIdentity.inspect(fd: sourceLock.fd),
                  fdIdentity == sourceLock.identity,
                  let entryIdentity = try? LocalFileIdentity.inspect(dirFD: dirFD, name: originalFileName),
                  entryIdentity == sourceLock.identity else {
                throw conversionError(51, "삭제 직전 원본 식별 정보/디렉터리 항목 변경 감지: 원본을 삭제하지 않습니다.")
            }
        }
        try recheckAll()

        // Deletion-started journal first (a crash afterwards is reported as uncertain, never as authorization).
        var deletingJournal = published.record
        deletingJournal.state = .deletionStarted
        deletingJournal.thumbnailFileName = thumbnail.fileName
        try advanceJournal(deletingJournal, to: deletingJournalName, replacing: publishedJournalName, dirFD: dirFD)

        // Immediate pre-unlink recheck (no journal I/O between this and the unlink).
        try recheckAll()

        if unlinkat(dirFD, originalFileName, 0) != 0 {
            let err = errno
            if let entry = try? LocalFileIdentity.inspect(dirFD: dirFD, name: originalFileName), entry == sourceLock.identity {
                throw posixError(err, "원본 삭제 실패: 원본은 그대로 남아 있습니다")
            }
            throw LocalDeletionUncertainError(detail: "원본 삭제 결과를 확인할 수 없습니다 (errno \(err)): MP4/썸네일은 보존되었고 작업 폴더에 원본 복사본이 보존됩니다.")
        }

        // Irreversible from here: sync the ORIGINAL's parent directory and positively confirm absence.
        guard fullSync(dirFD) else {
            throw LocalDeletionUncertainError(detail: "원본 삭제 후 디렉터리 sync 실패 (errno \(errno)): 삭제 영속성 미확인, 작업 폴더에 원본 복사본이 보존됩니다.")
        }
        var after = stat()
        guard fstatat(dirFD, originalFileName, &after, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw LocalDeletionUncertainError(detail: "원본 삭제 후 항목 부재를 확인하지 못했습니다: 증적이 보존됩니다.")
        }

        // Completed: drop the journal (best effort; a stale deletionStarted record with an absent original is read-only evidence).
        if unlinkat(dirFD, deletingJournalName, 0) == 0 {
            _ = fullSync(dirFD)
        }
    }

    private static func writeJournalRecord(
        _ record: LocalJournalRecord,
        fileName: String,
        dirFD: Int32
    ) throws {
        let data = try JSONEncoder().encode(record)
        let tempName = "\(fileName).tmp-\(UUID().uuidString.lowercased())"

        let fd = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "저널 임시 파일 생성 실패 (errno \(err))"])
        }

        var written = 0
        let writeError: Error? = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            while written < raw.count {
                let res = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if res <= 0 {
                    let err = errno
                    return NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "저널 쓰기 실패 (errno \(err))"])
                }
                written += res
            }
            return nil
        }

        if let writeError {
            Darwin.close(fd)
            unlinkat(dirFD, tempName, 0)
            throw writeError
        }

        guard written == data.count else {
            Darwin.close(fd)
            unlinkat(dirFD, tempName, 0)
            throw NSError(domain: "LocalConversionError", code: 19, userInfo: [NSLocalizedDescriptionKey: "저널 쓰기 바이트 불일치"])
        }

        if fsync(fd) != 0 {
            let err = errno
            Darwin.close(fd)
            unlinkat(dirFD, tempName, 0)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "저널 fsync 실패 (errno \(err))"])
        }
        Darwin.close(fd)

        if renameClaimed(dirFD, tempName, fileName) != 0 {
            let err = errno
            unlinkat(dirFD, tempName, 0)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "저널 배타적 발행 실패 (errno \(err))"])
        }

        if fsync(dirFD) != 0 {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "디렉터리 fsync 실패 (errno \(err))"])
        }
    }
}

// MARK: - Crash Recovery (Candidate-Local, Bounded & Read-Only)

enum LocalCrashRecovery {
    /// Candidate-local, descriptor-relative, bounded inspection of strictly recognizable own journals.
    /// Never mutates or removes any file. All uncertain original, staging, final and journal files are preserved.
    /// Performs NO pre-start full tree scan.
    static func inspectCandidateJournal(
        candidateURL: URL
    ) -> String? {
        let parentDir = candidateURL.deletingLastPathComponent()
        let fileName = candidateURL.lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }

        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(atPath: parentDir.path) else {
            return nil
        }

        let prefix = ".\(stem).journal-"
        for name in items where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let journalURL = parentDir.appendingPathComponent(name)

            var statBuf = stat()
            guard lstat(journalURL.path, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFREG else {
                continue
            }

            // Bounded read (max 64 KiB)
            guard statBuf.st_size <= 64 * 1024,
                  let data = try? Data(contentsOf: journalURL),
                  let record = try? JSONDecoder().decode(LocalJournalRecord.self, from: data) else {
                return "손상된 이전 변환 저널 발견 (보존됨): \(name)"
            }

            let backupURL = parentDir.appendingPathComponent(record.backupFileName)
            let finalURL = parentDir.appendingPathComponent(record.finalFileName)
            let stagedURL = parentDir.appendingPathComponent(record.stagedFileName)

            let backupExists = fileManager.fileExists(atPath: backupURL.path)
            let finalExists = fileManager.fileExists(atPath: finalURL.path)
            let stagedExists = fileManager.fileExists(atPath: stagedURL.path)
            let originalExists = fileManager.fileExists(atPath: parentDir.appendingPathComponent(record.originalFileName).path)

            // Schema 2 (keep-original transaction). Report only; never delete, re-encode or overwrite anything.
            if record.schema == LocalJournalRecord.currentSchema {
                switch record.state {
                case .outputStaged:
                    return "이전 완료본 스테이징 중단 기록 발견 (보존됨): 원본 '\(record.originalFileName)'은 그대로입니다."
                case .outputPublished:
                    return "이전 변환에서 MP4 '\(record.finalFileName)'는 발행되었으나 썸네일 생성/원본 정리가 끝나지 않았습니다. 원본 '\(record.originalFileName)'은 보존되어 있으며 자동 삭제하지 않습니다 (수동 확인 필요)."
                case .deletionStarted:
                    if originalExists {
                        return "이전 변환의 원본 삭제 시작 기록이 있으나 원본 '\(record.originalFileName)'이 남아 있습니다 (보존됨, 수동 확인 필요)."
                    } else if finalExists {
                        return "이전 변환의 원본 삭제 결과가 불확실합니다: MP4 '\(record.finalFileName)'는 존재하며 원본은 없습니다 (증적 보존됨, 수동 확인 필요)."
                    }
                    return "이전 변환의 원본 삭제 기록이 있으나 MP4와 원본이 모두 보이지 않습니다 (증적 보존됨)."
                case .staged, .sourceRenamed, .published:
                    return "알 수 없는 변환 저널 상태 (보존됨): \(name)"
                }
            }

            // Schema 1 (retired `_원본` flow): read-only legacy reporting, never deletion authorization.
            guard record.schema == 1 else {
                return "알 수 없는 변환 저널 스키마 (보존됨): \(name)"
            }

            switch record.state {
            case .outputStaged, .outputPublished, .deletionStarted:
                return "알 수 없는 변환 저널 상태 (보존됨): \(name)"
            case .staged:
                if stagedExists {
                    return "이전 스테이징 중단 기록 발견 (보존됨): 원본 '\(record.originalFileName)'"
                }
            case .sourceRenamed:
                if finalExists && backupExists {
                    return "이전 변환 완료 확인됨: 최종 MP4 '\(record.finalFileName)', 원본 보존 '\(record.backupFileName)'"
                } else if stagedExists {
                    return "최종 MP4 발행 직전 중단 기록: 원본 '\(record.backupFileName)' 보존됨, 완료본 '\(record.stagedFileName)' 보존됨"
                } else if backupExists {
                    return "원본이 '\(record.backupFileName)'(으)로 안전하게 보존되어 있습니다."
                }
            case .published:
                if finalExists && backupExists {
                    return "이전 변환 정상 완료 확인됨: '\(record.finalFileName)'"
                }
            }
        }

        return nil
    }
}
