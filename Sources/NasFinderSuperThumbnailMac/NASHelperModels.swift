import Foundation

/// A user-selected NAS or media folder registered for collaborative conversion help.
struct NASHelperFolder: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let addedDate: Date
    let isRecursiveScope: Bool
    var rootDescriptor: NASWireRootDescriptor?
    var registrationError: String?
    /// True when the folder is stored in the remembered list (exact-folder security-scoped bookmark).
    var isRemembered: Bool
    /// Set while the remembered folder cannot be reached; cleared by a successful reconnect.
    var mountIssue: NASHelperFolderMountIssue?

    init(
        id: UUID = UUID(),
        url: URL,
        addedDate: Date = Date(),
        isRecursiveScope: Bool = true,
        rootDescriptor: NASWireRootDescriptor? = nil,
        registrationError: String? = nil,
        isRemembered: Bool = false,
        mountIssue: NASHelperFolderMountIssue? = nil
    ) {
        self.id = id
        self.url = url
        self.addedDate = addedDate
        self.isRecursiveScope = isRecursiveScope
        self.rootDescriptor = rootDescriptor
        self.registrationError = registrationError
        self.isRemembered = isRemembered
        self.mountIssue = mountIssue
    }

    /// Fixed recovery hint for an unreachable remembered folder (no paths, IDs or raw error text).
    var recoveryText: String? {
        mountIssue?.recoveryText
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    var path: String {
        url.path
    }

    var isRegisteredRoot: Bool {
        rootDescriptor != nil
    }

    /// User-facing registration status text.
    /// Displays 'NAS 앱에서 이 폴더의 협업 작업을 등록해 주세요.' when unregistered.
    var statusText: String {
        if let desc = rootDescriptor {
            return "협업 등록됨 (Root: \(desc.root_id.prefix(8))…, Epoch: \(desc.coordinator_epoch))"
        }
        if let err = registrationError {
            return err
        }
        return "NAS 앱에서 이 폴더의 협업 작업을 등록해 주세요."
    }

    /// Clear recursive scope description for the user interface.
    var scopeDescription: String {
        "선택한 폴더와 모든 하위 폴더가 변환 협업 대상에 포함됩니다."
    }

    /// Excludes directories or paths containing `_원본`.
    /// The conversion helper never touches `_원본` media; NAS coordinates commit and preservation.
    static func containsExcludedOriginalPathSegment(_ targetURL: URL) -> Bool {
        let components = targetURL.standardizedFileURL.pathComponents
        return components.contains("_원본")
    }
}

/// One previously USER-selected folder, stored as an exact-folder security-scoped bookmark (no ancestor grants).
struct NASRememberedFolderRecord: Codable, Equatable, Sendable {
    var id: UUID
    var bookmark: Data
    var addedDate: Date
    /// Display fallback while the mount is missing (never used to access the folder).
    var lastPath: String
}

/// Persistence and resolution of remembered NAS folders.
/// Resolution never mounts a volume, never shows UI and never logs in anywhere: a missing mount stays visible and recoverable.
enum NASRememberedFolderStore {
    static let defaultsKey = "NASHelper.rememberedFolders.v1"
    static let maxRecords = 64

    struct Resolution {
        /// Resolved folder URL (nil only when the bookmark itself cannot be resolved).
        var url: URL?
        /// True when `url` was security-scoped and access was started; the caller must stop it when it forgets the folder.
        var scopeStarted: Bool
        /// Replacement bookmark when the stored one was stale and a fresh one could be made.
        var refreshedBookmark: Data?
        var issue: NASHelperFolderMountIssue?
    }

    static func load(defaults: UserDefaults = .standard) -> [NASRememberedFolderRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([NASRememberedFolderRecord].self, from: data) else {
            return []
        }
        return Array(records.prefix(maxRecords))
    }

    static func save(_ records: [NASRememberedFolderRecord], defaults: UserDefaults = .standard) {
        if records.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(Array(records.prefix(maxRecords))) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Bookmark for exactly this folder URL (security-scoped; plain bookmark only when scoping is unavailable).
    static func makeBookmark(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ record: NASRememberedFolderRecord) -> Resolution {
        let flagSets: [(URL.BookmarkResolutionOptions, Bool)] = [
            ([.withSecurityScope, .withoutUI, .withoutMounting], true),
            ([.withoutUI, .withoutMounting], false)
        ]
        for (options, scoped) in flagSets {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmark,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                continue
            }
            let started = scoped && url.startAccessingSecurityScopedResource()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                if started { url.stopAccessingSecurityScopedResource() }
                return Resolution(url: url, scopeStarted: false, refreshedBookmark: nil, issue: .missingMount)
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                if started { url.stopAccessingSecurityScopedResource() }
                return Resolution(url: url, scopeStarted: false, refreshedBookmark: nil, issue: .accessDenied)
            }
            var refreshed: Data? = nil
            if stale {
                refreshed = makeBookmark(for: url)
            }
            return Resolution(url: url, scopeStarted: started, refreshedBookmark: refreshed, issue: nil)
        }
        // The bookmark no longer resolves. The exact path the user selected earlier is the only fallback (never a parent).
        let fallback = URL(fileURLWithPath: record.lastPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fallback.path, isDirectory: &isDirectory), isDirectory.boolValue,
           FileManager.default.isReadableFile(atPath: fallback.path) {
            return Resolution(url: fallback, scopeStarted: false, refreshedBookmark: makeBookmark(for: fallback), issue: nil)
        }
        return Resolution(url: fallback, scopeStarted: false, refreshedBookmark: nil, issue: .missingMount)
    }
}

/// Why a remembered folder cannot be used right now.
enum NASHelperFolderMountIssue: String, Sendable {
    case missingMount
    case staleBookmark
    case accessDenied

    var recoveryText: String {
        switch self {
        case .missingMount:
            return "NAS 볼륨을 Finder에서 연결한 뒤 새로고침을 눌러 주세요."
        case .staleBookmark:
            return "저장된 폴더 위치가 바뀌었습니다. 폴더를 다시 추가해 주세요."
        case .accessDenied:
            return "폴더 접근 권한이 없습니다. 폴더를 다시 추가해 주세요."
        }
    }
}

/// Operational state of the NAS conversion helper.
enum NASHelperRunState: String, Sendable {
    case stopped = "도움 정지됨"
    case running = "도움 실행 중"
    case paused = "일시정지됨"

    var isRunning: Bool {
        self == .running
    }
}

/// Individual file stage in the collaborative video conversion pipeline.
enum NASHelperFileStage: String, CaseIterable, Sendable {
    case idle = "대기"
    case downloading = "다운로드"
    case converting = "변환"
    case generatingThumbnail = "썸네일 생성"
    case uploading = "업로드"
    case waitingVerification = "NAS 검증 대기"
    case completed = "완료"
    case failed = "실패"

    var displayName: String {
        rawValue
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .converting:
            return "gearshape.2"
        case .generatingThumbnail:
            return "photo.badge.checkmark"
        case .uploading:
            return "arrow.up.circle"
        case .waitingVerification:
            return "checkmark.shield"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    static func from(wireStage: NASWireStage) -> NASHelperFileStage {
        switch wireStage {
        case .downloading: return .downloading
        case .encoding: return .converting
        case .thumbnail: return .generatingThumbnail
        case .uploading: return .uploading
        case .waitingValidation: return .waitingVerification
        }
    }
}

/// Authoritative counts maintained and reported solely by the NAS via `job_status.json`.
/// When unknown or waiting for network reporting, values are `nil` and never fabricated.
struct NASAuthoritativeCounts: Equatable, Sendable {
    var totalItems: Int? = nil
    var queued: Int? = nil
    var queuedNas: Int? = nil
    var localProcessing: Int? = nil
    var macProcessing: Int? = nil
    var verifying: Int? = nil
    var completedCount: Int? = nil
    var failedCount: Int? = nil
    var deferredCount: Int? = nil
    var cancelledCount: Int? = nil
    var manualAttentionCount: Int? = nil
    var jobState: String? = nil

    var hasAuthoritativeData: Bool {
        totalItems != nil || completedCount != nil || failedCount != nil
    }

    var totalText: String {
        totalItems.map { "\($0)개" } ?? "확인 중"
    }

    var completedText: String {
        completedCount.map { "\($0)개" } ?? "확인 중"
    }

    var failedText: String {
        failedCount.map { "\($0)개" } ?? "확인 중"
    }

    var queuedText: String {
        queued.map { "\($0)개" } ?? "확인 중"
    }

    var macProcessingText: String {
        macProcessing.map { "\($0)개" } ?? "0개"
    }
}

/// Local helper execution progress for the current Mac.
/// Does not fabricate ETA, speed multiplier, or premature success.
struct NASHelperLocalProgress: Equatable, Sendable {
    var currentFileName: String? = nil
    var stage: NASHelperFileStage = .idle
    /// Actual current stage ratio (0.0 ... 1.0). Nullable when indeterminate.
    var stageFraction: Double? = nil
    var phaseLabel: String? = nil
    var processedCount: Int = 0
    var failedCount: Int = 0
    var lastError: String? = nil
    var activeSlotsInUse: Int = 0

    var progressText: String {
        if let label = phaseLabel, !label.isEmpty {
            if let stageFraction {
                return "\(label) (\(Int(stageFraction * 100))%)"
            }
            return label
        }
        guard let stageFraction else { return "진행률 확인 중" }
        return "\(Int(stageFraction * 100))%"
    }
}

/// One attempt that is running right now (several run side by side when the parallel count is above 1).
struct NASHelperAttemptDetail: Identifiable, Equatable, Sendable {
    let id: String
    var fileName: String
    var stage: NASHelperFileStage = .downloading
    /// Actual current stage ratio (0.0 ... 1.0); nil when indeterminate.
    var fraction: Double? = nil
    var phaseLabel: String? = nil
    var downloadFraction: Double? = nil
    var encodingFraction: Double? = nil
    var uploadFraction: Double? = nil
    var verificationFraction: Double? = nil

    init(
        id: String,
        fileName: String,
        stage: NASHelperFileStage = .downloading,
        fraction: Double? = nil,
        phaseLabel: String? = nil,
        downloadFraction: Double? = nil,
        encodingFraction: Double? = nil,
        uploadFraction: Double? = nil,
        verificationFraction: Double? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.stage = stage
        self.fraction = fraction
        self.phaseLabel = phaseLabel
        self.downloadFraction = downloadFraction
        self.encodingFraction = encodingFraction
        self.uploadFraction = uploadFraction
        self.verificationFraction = verificationFraction
    }
}

/// Real parallelism snapshot: what the user asked for, what the Mac and the NAS allow, and what is used now.
struct NASHelperParallelStatus: Equatable, Sendable {
    var requested: Int = NASHelperPipelineConfiguration.defaultEncodeWorkers
    /// Smaller of the CPU cap and the memory cap of this Mac.
    var deviceCap: Int = NASHelperPipelineConfiguration.maxParallelVideoCount
    /// Memory-based cap alone (conservative: about 3 GiB per video after a 4 GiB system reserve).
    var memoryCap: Int = NASHelperPipelineConfiguration.maxParallelVideoCount
    /// Sum of the NAS-assigned slots over the joined roots; nil while not connected.
    var serverCap: Int? = nil
    var effective: Int = NASHelperPipelineConfiguration.defaultEncodeWorkers
    var active: Int = 0
    var note: String? = nil
    var diskNote: String? = nil
}

/// Counters of the previous run, kept in memory only so that a new start never mixes them into the new run.
struct NASHelperRunSummary: Equatable, Sendable {
    var processedCount: Int
    var failedCount: Int
    var endedAt: Date
}

/// Concurrency and queue slot configuration for the conversion helper pipeline.
/// `encodeWorkers` is the user's simultaneous-video preference (1...4). The NAS shares at most 4 remote attempts per
/// root among all Macs (`slots_offered` 1...4), so the effective value is derived in the coordinator.
/// Download and upload stay one file at a time each.
struct NASHelperPipelineConfiguration: Equatable, Sendable {
    static let minParallelVideoCount = 1
    static let maxParallelVideoCount = 4
    static let defaultEncodeWorkers = 1
    static let maxEncodeWorkers = maxParallelVideoCount
    static let localCacheSlots = maxParallelVideoCount
    static let downloadWorkers = 1
    static let uploadWorkers = 1

    var encodeWorkers: Int = defaultEncodeWorkers {
        didSet {
            encodeWorkers = min(max(encodeWorkers, Self.minParallelVideoCount), Self.maxEncodeWorkers)
        }
    }
}
