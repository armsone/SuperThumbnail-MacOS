import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Resource limiter for bounded pipeline execution (AsyncSemaphore pattern).
/// Cancellation-safe: waiters removed on cancellation; permits delivered via withPermit.
/// The capacity can be changed at runtime: raising it admits waiters at once, lowering it never revokes permits
/// that are already held (new acquires simply wait until enough permits were returned).
actor NASResourceLimiter {
    private var capacity: Int
    private var inUse = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var availableCount: Int {
        max(0, capacity - inUse)
    }

    var currentCapacity: Int {
        capacity
    }

    func setCapacity(_ newCapacity: Int) {
        capacity = max(1, newCapacity)
        admitWaiters()
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if inUse < capacity {
            inUse += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let (_, cont) = waiters.remove(at: idx)
            cont.resume(throwing: CancellationError())
        }
    }

    /// Hands free permits to waiting acquirers in arrival order (the permit is counted before the waiter resumes).
    private func admitWaiters() {
        while inUse < capacity, !waiters.isEmpty {
            let (_, cont) = waiters.removeFirst()
            inUse += 1
            cont.resume(returning: ())
        }
    }

    func release() {
        inUse = max(0, inUse - 1)
        admitWaiters()
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// Thread-safe progress tracker for an individual attempt.
/// Prevents one attempt's stage or fraction from leaking into another attempt's heartbeat.
final class NASAttemptProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _stage: NASWireStage = .downloading
    private var _stagePercent: Double? = nil
    private var _completedBytes: Int64? = nil
    private var _totalBytes: Int64? = nil
    private var _phaseLabel: String? = nil

    func update(
        stage: NASWireStage,
        stagePercent: Double? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        phaseLabel: String? = nil
    ) {
        lock.lock()
        _stage = stage
        _stagePercent = stagePercent
        _completedBytes = completedBytes
        _totalBytes = totalBytes
        _phaseLabel = phaseLabel
        lock.unlock()
    }

    var snapshot: (stage: NASWireStage, percent: Double?, completedBytes: Int64?, totalBytes: Int64?, label: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (_stage, _stagePercent, _completedBytes, _totalBytes, _phaseLabel)
    }
}

/// Monotonic heartbeat sequencing and trusted-lease bookkeeping for one attempt.
///
/// A single value is owned by exactly one writer at a time: the attempt task during the first-ACK handshake,
/// then (copied) by the periodic heartbeat task. The two never run concurrently.
/// - Every heartbeat gets a strictly increasing seq and a monotonic send instant, recorded BEFORE the write.
/// - Only an ACK that strictly advances `lastAckSeq` renews the trusted lease; duplicates/stale/unsent never do.
/// - The renewed lease is anchored to the acknowledged heartbeat's SEND instant, never the ACK read time.
struct NASHeartbeatLeaseState: Sendable {
    static let heartbeatIntervalSeconds = 10
    static let nasLeaseSeconds = 120
    static let leaseSafetyMarginSeconds = 15
    static let handshakeMaxSeconds = 120
    static let offerSafetySeconds = 15
    /// Upper bound on remembered seq -> send instant entries.
    static let sendTimeRetention = 32

    enum AckOutcome: Equatable {
        case renewed
        case duplicate
        case stale
        case unsent
        case ignoredStatus
        case rejected(reason: String)
    }

    private(set) var nextSeq = 1
    private(set) var lastAckSeq = 0
    private(set) var lastSendAt: ContinuousClock.Instant?
    private(set) var leaseExpiry: ContinuousClock.Instant?
    private var sendTimes: [Int: ContinuousClock.Instant] = [:]

    private(set) var heartbeatsSent = 0
    private(set) var writeFailures = 0
    private(set) var ackReads = 0
    private(set) var emptyReads = 0
    private(set) var staleReads = 0
    private(set) var unsentReads = 0
    private(set) var ignoredStatusReads = 0
    private(set) var lastReadState = "none"
    /// Last actual I/O failure of an ACK read / heartbeat write (fixed phase + errno only; never paths or messages).
    private(set) var lastReadFailure: NASIOFailureDiagnostic?
    private(set) var lastWriteFailure: NASIOFailureDiagnostic?
    /// Highest `receipt_revision` any identity-validated ACK advertised (a hint for probing immutable receipts).
    private(set) var latestAckReceiptRevision = 0

    var highestSentSeq: Int { nextSeq - 1 }

    /// Reserves the next strictly increasing seq and records its send instant (before the write attempt).
    mutating func reserveSeq(at now: ContinuousClock.Instant) -> Int {
        let seq = nextSeq
        nextSeq += 1
        heartbeatsSent += 1
        lastSendAt = now
        sendTimes[seq] = now
        let floor = seq - Self.sendTimeRetention
        sendTimes = sendTimes.filter { $0.key > floor }
        return seq
    }

    mutating func noteWriteFailure() {
        writeFailures += 1
    }

    /// Remembers the typed cause of the latest failure per direction when the error carries one.
    mutating func noteIOFailure(_ error: Error) {
        guard case NASHelperTransportError.operationFailed(let diagnostic) = error else { return }
        if diagnostic.phase == .heartbeatAckRead {
            lastReadFailure = diagnostic
        } else {
            lastWriteFailure = diagnostic
        }
    }

    /// Fixed-text suffix naming the latest real I/O causes; empty when none was observed.
    var ioFailureSuffix: String {
        var parts: [String] = []
        if let lastWriteFailure { parts.append("마지막 쓰기 오류: \(lastWriteFailure.summary)") }
        if let lastReadFailure { parts.append("마지막 읽기 오류: \(lastReadFailure.summary)") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: " / ") + ")"
    }

    mutating func noteEmptyRead() {
        ackReads += 1
        emptyReads += 1
        lastReadState = "empty"
    }

    /// Classifies an identity-validated ACK and renews the lease only for a strictly advancing, previously sent seq.
    mutating func observe(_ ack: NASWireHeartbeatAck) -> AckOutcome {
        ackReads += 1
        latestAckReceiptRevision = max(latestAckReceiptRevision, ack.receipt_revision)
        guard ack.ack_seq >= 0 else {
            staleReads += 1
            lastReadState = "stale_seq"
            return .stale
        }
        guard ack.ack_seq <= highestSentSeq else {
            unsentReads += 1
            lastReadState = "unsent_seq"
            return .unsent
        }
        if ack.isSupersededRejection {
            // A newer heartbeat was processed first; this older seq is covered by that ACK. Neither a renewal nor a rejection.
            staleReads += 1
            lastReadState = "stale_seq"
            return .stale
        }
        if ack.status == "rejected" {
            return .rejected(reason: ack.reason_code)
        }
        guard ack.status == "received" else {
            ignoredStatusReads += 1
            lastReadState = "ignored_status"
            return .ignoredStatus
        }
        guard ack.ack_seq > lastAckSeq, let sentAt = sendTimes[ack.ack_seq] else {
            staleReads += 1
            lastReadState = "stale_seq"
            return ack.ack_seq == lastAckSeq ? .duplicate : .stale
        }
        lastAckSeq = ack.ack_seq
        let candidate = sentAt + .seconds(Self.nasLeaseSeconds - Self.leaseSafetyMarginSeconds)
        if let current = leaseExpiry, current >= candidate {
            // Never shorten an already trusted lease.
        } else {
            leaseExpiry = candidate
        }
        lastReadState = "received"
        return .renewed
    }

    func leaseHasExpired(at now: ContinuousClock.Instant) -> Bool {
        guard let expiry = leaseExpiry else { return true }
        return now >= expiry
    }

    func handshakeDiagnostic(elapsedSeconds: Int, budgetSeconds: Int) -> NASHeartbeatHandshakeDiagnostic {
        NASHeartbeatHandshakeDiagnostic(
            lastReadState: lastReadState,
            elapsedSeconds: elapsedSeconds,
            budgetSeconds: budgetSeconds,
            heartbeatsSent: heartbeatsSent,
            writeFailures: writeFailures,
            ackReads: ackReads,
            emptyReads: emptyReads,
            staleReads: staleReads,
            unsentReads: unsentReads,
            ignoredStatusReads: ignoredStatusReads,
            lastReadFailure: lastReadFailure,
            lastWriteFailure: lastWriteFailure
        )
    }
}

/// Lock-protected holder of one attempt's lease state, shared by its independent heartbeat sender and ACK/deadline watcher
/// (the first-ACK handshake still owns the plain value; the box is created from it afterwards).
final class NASHeartbeatLeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: NASHeartbeatLeaseState

    init(_ state: NASHeartbeatLeaseState) {
        self.state = state
    }

    func withState<R>(_ body: (inout NASHeartbeatLeaseState) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// Active attempt execution handle.
private final class NASActiveAttemptHandle: @unchecked Sendable {
    let attemptID: String
    let jobID: String
    let itemID: String
    /// The connection's pinned root (shared with the joined root); every control read/write of this attempt walks from it.
    let pin: NASPinnedRoot
    let offer: NASWireOffer
    let workspaceURL: URL
    let progressTracker: NASAttemptProgressTracker
    /// Connection (helper start) this attempt belongs to; an older connection never updates the current run's counters.
    let connection: Int
    /// True once the NAS confirmed immutable_control_1 for this attempt's root: ACK/receipt are read ONLY from the
    /// immutable per-seq / per-revision files, never from the mutable legacy files.
    let immutableControl: Bool
    var task: Task<Void, Never>?
    /// The attempt's single real heartbeat writer slot (shared by the first-ACK handshake and the periodic sender).
    let heartbeatGate = NASHeartbeatWriteGate()

    private let failureLock = NSLock()
    private var _heartbeatFailure: NASHelperTransportError?
    private var _isCancelled = false

    /// Set by the user-side stop/removal paths; read from the attempt task, hence lock protected.
    var isCancelled: Bool {
        get {
            failureLock.lock()
            defer { failureLock.unlock() }
            return _isCancelled
        }
        set {
            failureLock.lock()
            _isCancelled = newValue
            failureLock.unlock()
        }
    }

    /// Unique per concurrently running attempt (epoch + item); keys the engine process, never the shared job ID.
    var engineRef: String {
        "epoch_\(offer.coordinator_epoch)_item_\(offer.item_id)"
    }

    /// First failure recorded by the background heartbeat task wins; it explains the resulting cancellation.
    func recordHeartbeatFailure(_ failure: NASHelperTransportError) {
        failureLock.lock()
        if _heartbeatFailure == nil {
            _heartbeatFailure = failure
        }
        failureLock.unlock()
    }

    var heartbeatFailure: NASHelperTransportError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _heartbeatFailure
    }

    init(
        attemptID: String,
        jobID: String,
        itemID: String,
        pin: NASPinnedRoot,
        offer: NASWireOffer,
        workspaceURL: URL,
        connection: Int,
        immutableControl: Bool
    ) {
        self.connection = connection
        self.immutableControl = immutableControl
        self.attemptID = attemptID
        self.jobID = jobID
        self.itemID = itemID
        self.pin = pin
        self.offer = offer
        self.workspaceURL = workspaceURL
        self.progressTracker = NASAttemptProgressTracker()
    }
}

/// Coordinator managing the "NAS 영상 변환 돕기" (NAS Video Conversion Helper) mode.
///
/// Strict rules enforced:
/// - Exact NAS registered roots multi-select / remove (no ancestor search).
/// - Unregistered root displays: 'NAS 앱에서 이 폴더의 협업 작업을 등록해 주세요.'
/// - Trusted bundled engine (engine_cli.py + worker.py) only; verified NAS source SHA/size.
/// - Mac never writes originals / finals / backups / .NasFinder-Vault.
/// - Strict identity, fencing, and lease coordination.
/// - Independent 10s heartbeat with seq=1 ack verified before downloading; monotonic ack checks.
/// - Real phases and NAS counts; no false completion before NAS authoritative committed receipt.
/// - Thumbnail: AVFoundation creates JPEG content only (thumb.jpg); optional on error; NAS commits final vault keys.
/// - Bounded pipeline: cache and encode slots = the effective parallel count (1...4, pre-acquired), max 1 download, max 1 upload.
/// - Stop sends SIGTERM to engine PID and releases attempts/leaves batch; never stops NAS overall job.
@MainActor
final class NASHelperCoordinator: ObservableObject {
    @Published var selectedFolders: [NASHelperFolder] = []
    @Published var runState: NASHelperRunState = .stopped {
        didSet {
            refreshParallelStatus()
            refreshAutoResumeNote()
        }
    }
    @Published var toolEnvironment: NASToolEnvironment
    @Published var nasAuthoritativeCounts = NASAuthoritativeCounts()
    @Published var localProgress = NASHelperLocalProgress()
    @Published var pipelineConfig = NASHelperPipelineConfiguration()
    @Published var connectionStatusText = "NAS 협업 연결 대기"
    @Published var statusMessage = "Finder에서 변환을 도울 NAS 폴더를 추가하세요."

    /// Real simultaneous video count (download -> encode -> upload attempts), 1...4; not an x264 thread setting.
    /// The NAS shares at most 4 remote attempts per root among all Macs, so `parallelStatus` reports what is really used.
    @Published var parallelVideoCount: Int = NASHelperPipelineConfiguration.defaultEncodeWorkers {
        didSet {
            let clamped = min(max(parallelVideoCount, NASHelperPipelineConfiguration.minParallelVideoCount),
                              NASHelperPipelineConfiguration.maxParallelVideoCount)
            if clamped != parallelVideoCount {
                // Assigning inside its own observer does not re-trigger it: continue with the clamped value below.
                parallelVideoCount = clamped
            }
            pipelineConfig.encodeWorkers = clamped
            defaults.set(clamped, forKey: Self.parallelCountKey)
            applyParallelLimits()
        }
    }
    @Published private(set) var parallelStatus = NASHelperParallelStatus()
    /// Attempts running right now, oldest first (`localProgress` shows the oldest one plus a count).
    @Published private(set) var activeAttemptDetails: [NASHelperAttemptDetail] = []

    /// Launch-time participation of remembered folders (visible preference).
    @Published var autoParticipationEnabled = true {
        didSet {
            defaults.set(autoParticipationEnabled, forKey: Self.autoParticipationKey)
            refreshAutoResumeNote()
        }
    }
    @Published private(set) var autoResumeNote: String?
    /// True once the repeated-failure breaker blocked a root: only an explicit user start resumes it.
    @Published private(set) var needsManualRestart = false
    /// Set by an explicit user stop or by the repeated-failure breaker; cleared only by an explicit user start.
    @Published private(set) var userStopped = false
    /// Counters of the previous run (memory only, never persisted).
    @Published private(set) var previousRun: NASHelperRunSummary?

    /// True while helper is running, paused, or has in-flight/draining attempts.
    var hasActiveWork: Bool {
        runState != .stopped || !activeAttempts.isEmpty || unwindingAttemptTasks > 0
    }

    /// Hook to check if local conversion is active before auto-resuming.
    var isLocalWorkActive: (() -> Bool)?

    /// Folders whose latest root descriptor resolve has not finished yet (refresh/add/start).
    @Published private(set) var pendingResolveIDs: Set<UUID> = []

    private static let parallelCountKey = "NASHelper.parallelVideoCount"
    private static let autoParticipationKey = "NASHelper.autoParticipation"
    private static let userStoppedKey = "NASHelper.userStopped"
    private let defaults: UserDefaults
    /// Remembered folder records (exact-folder bookmarks) and the folders whose security scope is currently open.
    private var rememberedRecords: [NASRememberedFolderRecord] = []
    private var scopedAccessURLs: [UUID: URL] = [:]
    private var launchAutoResumePending = false
    private var mountObserver: NSObjectProtocol?
    /// Attempt tasks that have not finished unwinding (also after stop); per-start counters only reset at 0.
    private var unwindingAttemptTasks = 0
    /// New work is held back until an attempt ends after the cache volume ran short of free space.
    private var diskHoldActive = false
    /// Set when an offer did not fit next to running attempts; requests stay paused until an attempt ends.
    private var diskHoldUntilAttemptEnds = false
    /// Joined roots of the current connection (server slot cap source).
    private var joinedRoots: [NASAcceptedRoot] = []
    /// Set while the NAS refuses more work with SLOT_LIMIT_REACHED although this Mac has room (cap shared with other Macs).
    private var nasShareNote: String?
    /// One fresh-status request-response per root at a time (immutable control); see `startFreshStatusRefresh`.
    private var statusRefreshTasks: [String: Task<Void, Never>] = [:]
    /// Identity of the task currently registered in `statusRefreshTasks`; a finishing task only removes its own entry.
    private var statusRefreshTokens: [String: UUID] = [:]
    private var statusRefreshStartedAt: [String: Date] = [:]
    private static let statusRefreshIntervalSeconds: TimeInterval = 6
    /// The ONE unanswered `status_request` per root. A 10 s wait is only the caller's I/O budget: the same request ID is
    /// polled again by the next refreshes until its answer arrives, an authenticated final snapshot ends the job, or the
    /// 120 s NAS window passes. Only then may a new ID be issued (so at most one new request per window, never per poll).
    private struct NASPendingStatusRequest {
        let requestID: String
        let submittedAt: Date
    }
    private var pendingStatusRequests: [String: NASPendingStatusRequest] = [:]
    private static let statusRequestMaxPendingSeconds: TimeInterval = 120
    private static let statusResponseWaitSeconds: TimeInterval = 10
    /// Serializes limiter capacity changes so a late task never applies an outdated value.
    private var limiterUpdateTask: Task<Void, Never>?
    /// A failure happened while sibling attempts were still running; shown as `.failed` once none is left.
    private var failureStagePending = false
    /// Connection-scoped failure books of the repeated-failure breaker (reset only by an explicit restart / commit).
    private var consecutiveFailures: [String: Int] = [:]
    private var itemFailureCounts: [String: Int] = [:]
    private static let repeatedFailureLimit = 2
    /// The NAS registers at most this many attempts per root and client (`slots_offered` / `available_slots` 1...4).
    /// Its root-wide remote cap is also 4, SHARED among all Macs (fair share), so the real count can be lower.
    private static let serverSlotsPerRoot = NASHelperWire.maxSlotsPerRoot
    /// Free space that must stay available on the cache volume before another attempt may start.
    private static let minimumFreeCacheBytes: Int64 = 4 * 1024 * 1024 * 1024

    private var activeMainLoopTask: Task<Void, Never>?
    /// Latest resolve generation per folder id; only the newest resolve may apply its result.
    private var resolveGenerations: [UUID: Int] = [:]
    private var clientID: String = UUID().uuidString.lowercased()

    private let transport = NASHelperTransport()
    private let engineBridge = DefaultNASConversionEngineBridge()

    // Bounded pipeline limiters
    private var cacheLimiter = NASResourceLimiter(capacity: NASHelperPipelineConfiguration.defaultEncodeWorkers)
    private let downloadLimiter = NASResourceLimiter(capacity: NASHelperPipelineConfiguration.downloadWorkers)
    private let uploadLimiter = NASResourceLimiter(capacity: NASHelperPipelineConfiguration.uploadWorkers)
    private var encodeLimiter: NASResourceLimiter
    private var prefetchLimiter: NASResourceLimiter
    private var postEncodeLimiter: NASResourceLimiter

    // In-flight attempt handles
    private var activeAttempts: [String: NASActiveAttemptHandle] = [:]

    /// One outstanding request_work per root (this client only). The same request ID is re-read on every
    /// loop pass until a response arrives. A request still unresolved after the NAS offer window (120s) is
    /// NEVER discarded or replaced by a new ID: its root is blocked instead (see `blockedRoots`).
    private struct NASOutstandingWorkRequest {
        let request: NASWireInboxRequest
        let submittedAt: Date
        let folderID: UUID
    }
    private var outstandingWorkRequests: [String: NASOutstandingWorkRequest] = [:]
    private static let workRequestMaxOutstandingSeconds: TimeInterval = 120

    /// Why a root stopped receiving work in this connection.
    private enum NASRootBlockReason: Equatable {
        /// request_work unanswered (or offer still not visible) after the 120s NAS offer window.
        case requestUnanswered
        /// Path validation / identity / fence / schema / symlink failure: immediate safety block.
        case safety
        /// Any other actual I/O failure.
        case io
        /// Two consecutive failed attempts on this root (or the same item failing twice): manual restart only.
        case repeatedFailure
    }
    private struct NASBlockedRoot {
        let reason: NASRootBlockReason
        let folderID: UUID
    }
    /// Blocked-root markers (and the pending request identity in `outstandingWorkRequests`) are kept until an
    /// explicit helper restart (new connection / client ID), or the root is removed. Never reset by the loop.
    private var blockedRoots: [String: NASBlockedRoot] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.toolEnvironment = NASToolEnvironment.detect()
        let initialWorkers = NASHelperPipelineConfiguration.defaultEncodeWorkers
        self.encodeLimiter = NASResourceLimiter(capacity: initialWorkers)
        self.prefetchLimiter = NASResourceLimiter(capacity: initialWorkers)
        self.postEncodeLimiter = NASResourceLimiter(capacity: initialWorkers)

        // Property observers do not run inside init: apply the stored preferences explicitly.
        if defaults.object(forKey: Self.parallelCountKey) != nil {
            let stored = min(max(defaults.integer(forKey: Self.parallelCountKey), NASHelperPipelineConfiguration.minParallelVideoCount),
                             NASHelperPipelineConfiguration.maxParallelVideoCount)
            parallelVideoCount = stored
            pipelineConfig.encodeWorkers = stored
        }
        if defaults.object(forKey: Self.autoParticipationKey) != nil {
            autoParticipationEnabled = defaults.bool(forKey: Self.autoParticipationKey)
        }
        userStopped = defaults.bool(forKey: Self.userStoppedKey)
        refreshParallelStatus()

        restoreRememberedFolders()
        observeUserVolumeMounts()
    }

    // MARK: - Tool Environment

    func refreshEnvironment() {
        toolEnvironment = NASToolEnvironment.detect()
    }

    var canStartHelper: Bool {
        let hasRegistered = selectedFolders.contains(where: { $0.isRegisteredRoot })
        return hasRegistered && pendingResolveIDs.isEmpty && toolEnvironment.isReadyToExecute && runState == .stopped
    }

    // MARK: - Parallel Video Limits

    /// CPU-based cap: at most half of the active cores, within 1...4.
    private var cpuParallelCap: Int {
        min(NASHelperPipelineConfiguration.maxParallelVideoCount, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    /// Memory-based cap (conservative): about 3 GiB per video after a 4 GiB system reserve, within 1...4.
    private var memoryParallelCap: Int {
        let gib = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return min(NASHelperPipelineConfiguration.maxParallelVideoCount, max(1, Int((gib - 4.0) / 3.0)))
    }

    private var deviceParallelCap: Int {
        min(cpuParallelCap, memoryParallelCap)
    }

    /// Joined roots that can still receive work in this connection.
    private var usableJoinedRoots: [NASAcceptedRoot] {
        joinedRoots.filter { isRootStillSelected($0) && blockedRoots[$0.rootID] == nil && !isVerifiedTerminal($0) }
    }

    /// Sum of the NAS-assigned slots over the usable joined roots; nil while not connected.
    private var serverSlotCap: Int? {
        guard runState != .stopped else { return nil }
        let usable = usableJoinedRoots
        guard !usable.isEmpty else { return nil }
        return usable.reduce(0) { $0 + max(1, $1.assignedSlots) }
    }

    /// What is really used: the user's count, bounded by the Mac and by the slots the NAS granted.
    private var effectiveParallelLimit: Int {
        var cap = min(parallelVideoCount, deviceParallelCap)
        if let server = serverSlotCap {
            cap = min(cap, server)
        }
        return max(1, cap)
    }

    /// Total in-flight / cache budget: bounded by 3*N and actual server grants.
    private var inFlightLimit: Int {
        let budget = 3 * effectiveParallelLimit
        if let server = serverSlotCap {
            return max(1, min(budget, server))
        }
        return max(1, budget)
    }

    private func refreshParallelStatus() {
        let requested = parallelVideoCount
        let device = deviceParallelCap
        let memory = memoryParallelCap
        let server = serverSlotCap
        let effective = effectiveParallelLimit
        var note: String?
        if effective < requested {
            if let server, server < min(requested, device) {
                if usableJoinedRoots.contains(where: { $0.assignedSlots < Self.serverSlotsPerRoot }) {
                    note = "동시 \(requested)개는 다음 도움 시작부터 NAS에 반영됩니다. 지금은 \(effective)개로 처리합니다."
                } else {
                    note = "NAS가 배정한 동시 처리 한도는 \(server)개입니다. 지금은 \(effective)개로 처리합니다."
                }
            } else if memory <= cpuParallelCap, memory < requested {
                note = "이 Mac의 메모리에 맞춰 동시 \(effective)개로 제한했습니다."
            } else {
                note = "이 Mac의 CPU 코어 수에 맞춰 동시 \(effective)개로 제한했습니다."
            }
        } else if let share = nasShareNote, activeAttempts.count < effective {
            // The Mac would run more, but the NAS shares its root-wide cap with the other Macs right now.
            note = share
        }
        let activeEncoders = activeAttemptDetails.filter { $0.stage == .converting }.count
        let next = NASHelperParallelStatus(
            requested: requested,
            deviceCap: device,
            memoryCap: memory,
            serverCap: server,
            effective: effective,
            active: activeEncoders,
            note: note,
            diskNote: diskHoldActive ? "Mac 저장 공간이 부족해 새 영상 시작을 잠시 멈췄습니다." : nil
        )
        if next != parallelStatus {
            parallelStatus = next
        }
    }

    /// Applies the effective limit to the limiters (ordered, never revokes held permits).
    private func applyParallelLimits() {
        refreshParallelStatus()
        let limit = effectiveParallelLimit
        let cacheCap = inFlightLimit
        let cache = cacheLimiter
        let encode = encodeLimiter
        let prefetch = prefetchLimiter
        let post = postEncodeLimiter
        let previous = limiterUpdateTask
        limiterUpdateTask = Task {
            await previous?.value
            await cache.setCapacity(cacheCap)
            await prefetch.setCapacity(limit)
            await encode.setCapacity(limit)
            await post.setCapacity(limit)
        }
    }

    /// Free bytes on the volume that holds the private attempt workspaces (nil when unknown).
    private func cacheVolumeFreeBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Bytes a running attempt may still claim on the cache volume (source copy plus converted output).
    private func reservedCacheBytes(excluding attemptID: String? = nil) -> Int64 {
        activeAttempts.values
            .filter { $0.attemptID != attemptID }
            .reduce(Int64(0)) { $0 + 2 * max(0, $1.offer.source_size_bytes) }
    }

    /// Cache volume check before asking for one more video. Unknown free space never blocks.
    private func diskAllowsAnotherAttempt() -> Bool {
        guard let free = cacheVolumeFreeBytes() else { return true }
        return free >= Self.minimumFreeCacheBytes + reservedCacheBytes()
    }

    // MARK: - Remembered Folders (exact-folder security-scoped bookmarks, no discovery)

    private func persistRememberedFolders() {
        NASRememberedFolderStore.save(rememberedRecords, defaults: defaults)
    }

    /// Stores exactly the folder the user picked (no parent grants). Returns whether the folder is now remembered.
    @discardableResult
    private func rememberFolder(id: UUID, url: URL, addedDate: Date) -> Bool {
        guard let bookmark = NASRememberedFolderStore.makeBookmark(for: url) else { return false }
        rememberedRecords.removeAll { $0.id == id }
        rememberedRecords.append(NASRememberedFolderRecord(id: id, bookmark: bookmark, addedDate: addedDate, lastPath: url.path))
        if rememberedRecords.count > NASRememberedFolderStore.maxRecords {
            rememberedRecords.removeFirst(rememberedRecords.count - NASRememberedFolderStore.maxRecords)
        }
        persistRememberedFolders()
        return true
    }

    private func forgetRememberedFolder(id: UUID) {
        if let scoped = scopedAccessURLs.removeValue(forKey: id) {
            scoped.stopAccessingSecurityScopedResource()
        }
        guard rememberedRecords.contains(where: { $0.id == id }) else { return }
        rememberedRecords.removeAll { $0.id == id }
        persistRememberedFolders()
    }

    private func forgetAllRememberedFolders() {
        for (_, scoped) in scopedAccessURLs {
            scoped.stopAccessingSecurityScopedResource()
        }
        scopedAccessURLs.removeAll()
        rememberedRecords.removeAll()
        persistRememberedFolders()
    }

    /// Restores the folders the user selected earlier. Resolution never mounts, never prompts and never logs in:
    /// an unreachable folder stays in the list with a fixed recovery text.
    private func restoreRememberedFolders() {
        rememberedRecords = NASRememberedFolderStore.load(defaults: defaults)
        guard !rememberedRecords.isEmpty else {
            refreshAutoResumeNote()
            return
        }
        var restored: [NASHelperFolder] = []
        var changed = false
        for index in rememberedRecords.indices {
            let record = rememberedRecords[index]
            let resolution = NASRememberedFolderStore.resolve(record)
            guard let url = resolution.url else { continue }
            if let fresh = resolution.refreshedBookmark {
                rememberedRecords[index].bookmark = fresh
                changed = true
            }
            if resolution.issue == nil, rememberedRecords[index].lastPath != url.path {
                rememberedRecords[index].lastPath = url.path
                changed = true
            }
            if resolution.scopeStarted {
                scopedAccessURLs[record.id] = url
            }
            var folder = NASHelperFolder(id: record.id, url: url.standardizedFileURL, addedDate: record.addedDate, isRemembered: true, mountIssue: resolution.issue)
            if let issue = resolution.issue {
                folder.registrationError = issue.recoveryText
            }
            restored.append(folder)
        }
        if changed {
            persistRememberedFolders()
        }
        selectedFolders = restored
        launchAutoResumePending = true
        let reachable = restored.filter { $0.mountIssue == nil }.map { $0.id }
        if reachable.isEmpty {
            updateFolderSummaryStatus()
            evaluateAutoResume()
        } else {
            resolveFolderRegistrations(ids: reachable)
        }
    }

    /// Re-resolves remembered folders that were unreachable (mount missing, access lost). Returns the ids that are reachable now.
    private func reconnectUnreachableFolders() {
        for index in selectedFolders.indices where selectedFolders[index].isRemembered && selectedFolders[index].mountIssue != nil {
            let current = selectedFolders[index]
            guard let recordIndex = rememberedRecords.firstIndex(where: { $0.id == current.id }) else { continue }
            let resolution = NASRememberedFolderStore.resolve(rememberedRecords[recordIndex])
            guard resolution.issue == nil, let url = resolution.url else {
                selectedFolders[index].mountIssue = resolution.issue ?? .missingMount
                selectedFolders[index].registrationError = selectedFolders[index].mountIssue?.recoveryText
                continue
            }
            if let fresh = resolution.refreshedBookmark {
                rememberedRecords[recordIndex].bookmark = fresh
            }
            rememberedRecords[recordIndex].lastPath = url.path
            persistRememberedFolders()
            if let old = scopedAccessURLs.removeValue(forKey: current.id) {
                old.stopAccessingSecurityScopedResource()
            }
            if resolution.scopeStarted {
                scopedAccessURLs[current.id] = url
            }
            selectedFolders[index] = NASHelperFolder(id: current.id, url: url.standardizedFileURL, addedDate: current.addedDate, isRemembered: true)
        }
    }

    /// Reacts to the user's own volume mounts (no polling, no discovery): a remembered folder may be reachable now.
    private func observeUserVolumeMounts() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleVolumeMounted()
            }
        }
    }

    private func handleVolumeMounted() {
        guard runState == .stopped, selectedFolders.contains(where: { $0.mountIssue != nil }) else { return }
        reconnectUnreachableFolders()
        launchAutoResumePending = true
        let ids = selectedFolders.filter { $0.mountIssue == nil && $0.rootDescriptor == nil }.map { $0.id }
        if ids.isEmpty {
            updateFolderSummaryStatus()
            evaluateAutoResume()
        } else {
            resolveFolderRegistrations(ids: ids)
        }
    }

    private func hasActiveNASJob(_ folder: NASHelperFolder) -> Bool {
        guard let descriptor = folder.rootDescriptor else { return false }
        return (descriptor.active_job_id ?? descriptor.active_jobs.first) != nil
    }

    /// Launch (or mount) check: join automatically only when the user has not stopped, the preference is on, tools are
    /// ready and a remembered folder's fresh strict descriptor names an ACTIVE NAS job. It never registers, approves
    /// or creates NAS jobs; the normal join path is the only thing that runs.
    private func evaluateAutoResume() {
        guard launchAutoResumePending, pendingResolveIDs.isEmpty else { return }
        launchAutoResumePending = false
        refreshAutoResumeNote()
        guard runState == .stopped, autoParticipationEnabled, !userStopped else { return }
        guard !(isLocalWorkActive?() ?? false) else { return }
        guard selectedFolders.contains(where: { hasActiveNASJob($0) }), canStartHelper else { return }
        beginHelper(automatic: true)
    }

    private func refreshAutoResumeNote() {
        let note: String?
        if !selectedFolders.contains(where: { $0.isRemembered }) || runState != .stopped {
            note = nil
        } else if userStopped {
            note = needsManualRestart
                ? "같은 폴더에서 변환이 연속으로 실패해 자동으로 시작하지 않습니다. 원인을 확인한 뒤 도움 시작을 눌러 주세요."
                : "도움을 중지해 자동으로 시작하지 않습니다. 도움 시작을 누르면 다시 연결합니다."
        } else if !autoParticipationEnabled {
            note = "자동 참여가 꺼져 있어 앱을 켜도 연결하지 않습니다."
        } else if selectedFolders.contains(where: { $0.mountIssue != nil }) {
            note = "NAS 볼륨 연결을 기다리는 중입니다. Finder에서 NAS를 연결하면 이어집니다."
        } else if !pendingResolveIDs.isEmpty {
            note = nil
        } else if !selectedFolders.contains(where: { hasActiveNASJob($0) }) {
            note = "NAS에 진행 중인 협업 작업이 없습니다. NAS에서 작업을 시작한 뒤 도움 시작을 눌러 주세요."
        } else if !toolEnvironment.isReadyToExecute {
            note = toolEnvironment.diagnosticMessage
        } else {
            note = nil
        }
        if note != autoResumeNote {
            autoResumeNote = note
        }
    }

    private func setUserStopped(_ value: Bool) {
        userStopped = value
        defaults.set(value, forKey: Self.userStoppedKey)
        refreshAutoResumeNote()
    }

    // MARK: - Folder Management (Exact Root Only, No Ancestor Search)

    /// Programmatic folder addition reusing the exact picker resolution/bookmarks.
    func addFolderURLs(_ urls: [URL]) {
        var addedIDs: [UUID] = []
        for url in urls {
            let standardized = url.standardizedFileURL
            if !selectedFolders.contains(where: { $0.url.standardizedFileURL == standardized }) {
                var folder = NASHelperFolder(url: standardized)
                folder.isRemembered = rememberFolder(id: folder.id, url: standardized, addedDate: folder.addedDate)
                selectedFolders.append(folder)
                addedIDs.append(folder.id)
            }
        }
        guard !addedIDs.isEmpty else { return }
        updateFolderSummaryStatus()
        resolveFolderRegistrations(ids: addedIDs)
    }

    func addFolders() {
        let panel = NSOpenPanel()
        panel.title = "변환을 도울 NAS 폴더 선택"
        panel.message = "Finder에 연결된 NAS 영상 폴더를 선택하세요. NAS 앱에 등록한 폴더를 선택해 주세요. (하위 폴더 포함)"
        panel.prompt = "폴더 추가"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }
        addFolderURLs(panel.urls)
    }

    /// Result of one fresh descriptor resolve. A read failure is distinct from "not registered" and "no active job".
    private enum NASFolderResolveOutcome: Sendable {
        case descriptor(NASWireRootDescriptor)
        case unregistered
        case readFailure(String)
    }

    /// Marks a new resolve for the folder and returns its generation; any older in-flight resolve becomes stale.
    private func beginResolve(id: UUID) -> Int {
        let generation = (resolveGenerations[id] ?? 0) + 1
        resolveGenerations[id] = generation
        pendingResolveIDs.insert(id)
        return generation
    }

    /// Performs the descriptor read strictly at the folder's own `.NasFinder-Handoff/v1/root.json` (no ancestor search).
    /// Returns nil only when the task was cancelled.
    nonisolated private static func resolveOutcome(transport: NASHelperTransport, url: URL) async -> NASFolderResolveOutcome? {
        // Non-connected folder-picker resolution (add / refresh): the transport pins the folder for this single read only.
        await resolveOutcome { try await transport.resolveRootDescriptor(at: url) }
    }

    /// Connected resolution: reads through the connection's pinned root.
    nonisolated private static func resolveOutcome(transport: NASHelperTransport, root: NASPinnedRoot) async -> NASFolderResolveOutcome? {
        await resolveOutcome { try await transport.resolveRootDescriptor(root: root) }
    }

    /// Opens the folder's root pin ONCE for this connection (bounded, off the main actor), then reads its fresh descriptor through it.
    /// An absent root is reported like an absent `root.json` (not registered); every other failure is a fixed phase + errno text.
    nonisolated private static func pinAndResolve(
        transport: NASHelperTransport,
        url: URL,
        folderID: UUID,
        connection: Int
    ) async -> (pin: NASPinnedRoot?, outcome: NASFolderResolveOutcome?) {
        let pin: NASPinnedRoot
        do {
            pin = try await NASPinnedRoot.open(url: url, folderID: folderID, connection: connection)
        } catch is CancellationError {
            return (nil, nil)
        } catch NASHelperTransportError.operationFailed(let diagnostic) where diagnostic.errnoValue == ENOENT {
            return (nil, .unregistered)
        } catch let error as NASHelperTransportError {
            return (nil, .readFailure(error.localizedDescription))
        } catch {
            let classified = NASJoinDiagnostic.classify(error)
            return (nil, .readFailure("\(classified.message)\(classified.errnoValue.map { " [errno=\($0)]" } ?? "")"))
        }
        guard let outcome = await resolveOutcome(transport: transport, root: pin) else {
            pin.close()
            return (nil, nil)
        }
        return (pin, outcome)
    }

    nonisolated private static func resolveOutcome(_ read: () async throws -> NASWireRootDescriptor?) async -> NASFolderResolveOutcome? {
        do {
            if let descriptor = try await read() {
                return .descriptor(descriptor)
            }
            return .unregistered
        } catch is CancellationError {
            return nil
        } catch let error as NASHelperTransportError {
            return .readFailure(error.localizedDescription)
        } catch {
            // Classified via enum/errno only; raw localizedDescription is never shown (may contain paths)
            let classified = NASJoinDiagnostic.classify(error)
            return .readFailure("\(classified.message)\(classified.errnoValue.map { " [errno=\($0)]" } ?? "")")
        }
    }

    /// Resolves each folder's descriptor off the main actor. Only the latest generation per folder applies its result.
    private func resolveFolderRegistrations(ids: [UUID]) {
        let targets = selectedFolders.filter { ids.contains($0.id) }.map { ($0.id, $0.url, beginResolve(id: $0.id)) }
        guard !targets.isEmpty else { return }
        updateFolderSummaryStatus()
        let trans = transport

        Task { [weak self] in
            for (id, url, generation) in targets {
                let outcome = await NASHelperCoordinator.resolveOutcome(transport: trans, url: url)
                guard let self else { return }
                self.finishResolve(id: id, generation: generation, outcome: outcome)
            }
        }
    }

    /// Applies a resolve result if (and only if) it is still the latest one for a folder that still exists.
    private func finishResolve(id: UUID, generation: Int, outcome: NASFolderResolveOutcome?) {
        guard resolveGenerations[id] == generation else { return }
        pendingResolveIDs.remove(id)
        if let outcome, selectedFolders.contains(where: { $0.id == id }) {
            applyFolderRegistration(id: id, outcome: outcome)
        } else {
            updateFolderSummaryStatus()
        }
        evaluateAutoResume()
    }

    private func applyFolderRegistration(id: UUID, outcome: NASFolderResolveOutcome) {
        guard let index = selectedFolders.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .descriptor(let descriptor):
            selectedFolders[index].rootDescriptor = descriptor
            selectedFolders[index].registrationError = nil
        case .unregistered:
            selectedFolders[index].rootDescriptor = nil
            selectedFolders[index].registrationError = "NAS 앱에 등록한 폴더를 선택해 주세요."
        case .readFailure(let message):
            selectedFolders[index].rootDescriptor = nil
            selectedFolders[index].registrationError = message
        }
        updateFolderSummaryStatus()
    }

    func refreshFolders() {
        reconnectUnreachableFolders()
        resolveFolderRegistrations(ids: selectedFolders.filter { $0.mountIssue == nil }.map { $0.id })
        updateFolderSummaryStatus()
    }

    func removeFolder(id: UUID) {
        guard let index = selectedFolders.firstIndex(where: { $0.id == id }) else { return }
        let folder = selectedFolders[index]

        // Cancel and release in-flight attempts for this root
        for (attemptID, handle) in activeAttempts where handle.pin.folderID == folder.id {
            cancelAttempt(handle)
            activeAttempts.removeValue(forKey: attemptID)
        }

        releaseWorkMarkers(forFolderID: folder.id)
        if let removedRootID = folder.rootDescriptor?.root_id {
            rootStatuses.removeValue(forKey: removedRootID)
        }
        selectedFolders.remove(at: index)
        forgetRememberedFolder(id: folder.id)
        resolveGenerations.removeValue(forKey: folder.id)
        pendingResolveIDs.remove(folder.id)
        if selectedFolders.isEmpty && runState != .stopped {
            stopHelperInternal()
        } else {
            updateFolderSummaryStatus()
        }
    }

    func clearAllFolders() {
        if runState != .stopped {
            stopHelperInternal()
        }
        forgetAllRememberedFolders()
        outstandingWorkRequests.removeAll()
        blockedRoots.removeAll()
        rootStatuses.removeAll()
        selectedFolders.removeAll()
        resolveGenerations.removeAll()
        pendingResolveIDs.removeAll()
        statusMessage = "등록된 폴더를 모두 제거했습니다."
    }

    private func updateFolderSummaryStatus() {
        let registeredCount = selectedFolders.filter { $0.isRegisteredRoot }.count
        if selectedFolders.isEmpty {
            statusMessage = "Finder에서 변환을 도울 NAS 폴더를 추가하세요."
        } else if !pendingResolveIDs.isEmpty {
            statusMessage = "NAS 등록 정보를 새로 확인하고 있습니다…"
        } else if registeredCount == 0, selectedFolders.contains(where: { $0.mountIssue != nil }) {
            statusMessage = "NAS 폴더에 연결할 수 없습니다. Finder에서 NAS를 연결한 뒤 새로고침을 눌러 주세요."
        } else if registeredCount == 0 {
            statusMessage = "선택한 폴더 중 등록된 폴더가 없습니다. NAS 앱에 등록한 폴더를 선택해 주세요."
        } else {
            statusMessage = "변환할 폴더 \(registeredCount)개 준비 완료 (전체 \(selectedFolders.count)개 중)"
        }
        refreshAutoResumeNote()
    }

    // MARK: - Helper Lifecycle Controls

    /// Explicit user start: the only way to resume after a user stop or the repeated-failure breaker.
    func startHelper(targetFolderIDs: Set<UUID>? = nil) {
        beginHelper(automatic: false, targetFolderIDs: targetFolderIDs)
    }

    /// Shared start path. `automatic` is the launch/mount participation: it never clears a user stop.
    private func beginHelper(automatic: Bool, targetFolderIDs: Set<UUID>? = nil) {
        guard !(isLocalWorkActive?() ?? false) else {
            if !automatic {
                statusMessage = "로컬 영상 변환이 진행 중입니다. 로컬 작업 종료 후 다시 시도해 주세요."
            }
            return
        }

        guard canStartHelper else {
            guard !automatic else { return }
            refreshEnvironment()
            if !toolEnvironment.isReadyToExecute {
                statusMessage = toolEnvironment.diagnosticMessage
            } else {
                statusMessage = "NAS 앱에 등록한 폴더를 선택해 주세요."
            }
            return
        }

        if !automatic {
            needsManualRestart = false
            setUserStopped(false)
        }

        // Fresh client identity on each start (also distinguishes several Macs and several starts)
        clientID = UUID().uuidString.lowercased()
        runState = .running
        connectionStatusText = automatic ? "자동으로 NAS 협업 연결 중" : "NAS 협업 연결 중"
        statusMessage = "NAS 등록 정보를 새로 확인하고 있습니다…"

        resetCountersForNewStart()
        localProgress.stage = .idle
        localProgress.stageFraction = nil
        localProgress.currentFileName = nil
        localProgress.phaseLabel = nil
        failureStagePending = false
        diskHoldActive = false
        joinedRoots = []

        let limit = effectiveParallelLimit
        let cacheCap = inFlightLimit
        cacheLimiter = NASResourceLimiter(capacity: cacheCap)
        encodeLimiter = NASResourceLimiter(capacity: limit)
        prefetchLimiter = NASResourceLimiter(capacity: limit)
        postEncodeLimiter = NASResourceLimiter(capacity: limit)
        refreshParallelStatus()

        activeMainLoopTask = Task { [weak self] in
            guard let self else { return }
            await self.runHelperLoop(targetFolderIDs: targetFolderIDs)
        }
    }

    /// Per-start counters belong to one run. They reset only when no earlier attempt task is still unwinding, and the
    /// finished run is kept (memory only) as `previousRun` so old numbers are never shown as the new run's.
    private func resetCountersForNewStart() {
        guard unwindingAttemptTasks == 0 else { return }
        if localProgress.processedCount > 0 || localProgress.failedCount > 0 {
            previousRun = NASHelperRunSummary(
                processedCount: localProgress.processedCount,
                failedCount: localProgress.failedCount,
                endedAt: Date()
            )
        }
        localProgress.processedCount = 0
        localProgress.failedCount = 0
        localProgress.lastError = nil
    }

    func pauseHelper() {
        guard runState == .running else { return }
        runState = .paused
        connectionStatusText = "일시정지 중"
        statusMessage = "신규 작업 수령을 중단했습니다. 진행 중인 변환은 완료 후 대기합니다."
    }

    func resumeHelper() {
        guard runState == .paused else { return }
        runState = .running
        connectionStatusText = "도움 실행 중"
        statusMessage = "도움을 다시 시작했습니다. 작업 배정을 확인합니다."
    }

    /// User stop (도움 중지): remembered for the next launch, so the app does not join again by itself.
    func stopHelper() {
        guard runState != .stopped else { return }
        setUserStopped(true)
        stopHelperInternal()
    }

    private func stopHelperInternal(preservingFailure: Bool = false) {
        guard runState != .stopped else { return }
        let preserved = localProgress
        runState = .stopped
        connectionStatusText = "도움 정지됨"
        statusMessage = "도움이 정지되었습니다. 내 Mac의 임시 작업공간을 정리했습니다."

        // Cancel all in-flight attempts
        for (_, handle) in activeAttempts {
            cancelAttempt(handle)
        }
        activeAttempts.removeAll()

        activeMainLoopTask?.cancel()
        activeMainLoopTask = nil

        engineBridge.cancelAll()

        localProgress.stage = .idle
        localProgress.stageFraction = nil
        localProgress.currentFileName = nil
        localProgress.phaseLabel = nil
        localProgress.activeSlotsInUse = 0
        joinedRoots = []
        diskHoldActive = false
        activeAttemptDetails.removeAll()
        refreshParallelStatus()

        if preservingFailure {
            // A stop caused by repeated failures keeps the failure visible (stage, last error, counters).
            localProgress.stage = .failed
            localProgress.currentFileName = preserved.currentFileName
            localProgress.phaseLabel = preserved.phaseLabel
        }
    }

    private func cancelAttempt(_ handle: NASActiveAttemptHandle) {
        handle.isCancelled = true
        handle.heartbeatGate.close()
        handle.task?.cancel()

        // 1. Terminate owned engine process first (only this attempt's run, never a sibling of the same job)
        engineBridge.cancel(ref: handle.engineRef)

        // 2. Submit release_attempt to NAS and clean up cache after exit
        // The release outlives the connection's pin (closed when the loop ends): it gets its own descriptor of the same root object.
        let releasePin = handle.pin.duplicate()
        let offer = handle.offer
        let workspaceURL = handle.workspaceURL
        let jobID = handle.jobID
        let itemID = handle.itemID
        let attemptID = handle.attemptID
        let trans = transport

        Task.detached(priority: .userInitiated) {
            let request = NASWireInboxRequest.makeRelease(
                rootID: offer.root_id,
                rootGeneration: offer.root_generation,
                clientID: offer.assigned_client_id,
                jobID: jobID,
                itemID: itemID,
                coordinatorEpoch: offer.coordinator_epoch,
                attemptID: attemptID,
                fencingToken: offer.fencing_token,
                reason: "user_cancelled"
            )
            if let releasePin {
                try? await trans.submitInboxRequest(root: releasePin, request: request)
                releasePin.close()
            }
            try? FileManager.default.removeItem(at: workspaceURL)
        }
    }

    // MARK: - Main Coordination Loop

    /// An authoritative NAS root that has successfully accepted our join request.
    private struct NASAcceptedRoot: Sendable {
        /// The connection's pinned root, bound to rootID/generation/epoch at the verified immutable join.
        let pin: NASPinnedRoot
        let rootID: String
        let rootGeneration: Int
        let coordinatorEpoch: Int
        let activeJobID: String
        let assignedSlots: Int
        /// The NAS confirmed immutable_control_1 for this root (authenticated immutable join answer).
        let immutableControl: Bool
    }

    /// Job states of the frozen wire schema (`protocol-schema.json` job_status.state enum / NAS `JOB_STATE_WIRE`).
    /// Only `completed`, `cancelled` and `failed` are terminal; every other or unknown string is non-terminal.
    private static let knownJobStates: Set<String> = ["scanning", "running", "paused", "completed", "cancelled", "failed"]
    private static let terminalJobStates: Set<String> = ["completed", "cancelled", "failed"]

    /// Authenticated `job_status.json` of one joined root. Stored only when root/job/generation/epoch all equal the
    /// identity of the current connection's joined root.
    private struct NASRootStatus {
        let rootID: String
        let rootGeneration: Int
        let coordinatorEpoch: Int
        let jobID: String
        let state: String
        let counts: NASWireJobStatus.Counts
    }
    private var rootStatuses: [String: NASRootStatus] = [:]
    /// Incremented by every helper (re)start; a loop of an older connection never stores or acts on status.
    private var connectionSerial = 0

    private static let immutableJoinUnavailableHint = " NAS가 이 앱이 요구하는 변경 불가(immutable) 참여 응답을 제공하지 않았습니다. NAS 앱이 0.4.1 이상으로 실행 중인지 확인하고, 업데이트 후 다시 시작해 주세요."

    private func runHelperLoop(targetFolderIDs: Set<UUID>? = nil) async {
        let currentClient = clientID
        // Explicit helper (re)start = new connection and client ID: the only point where markers reset.
        outstandingWorkRequests.removeAll()
        blockedRoots.removeAll()
        rootStatuses.removeAll()
        cancelStatusRefreshes()
        nasShareNote = nil
        consecutiveFailures.removeAll()
        itemFailureCounts.removeAll()
        nasAuthoritativeCounts = NASAuthoritativeCounts()
        connectionSerial += 1
        let connection = connectionSerial

        // One pin per approved folder for this connection. The loop owns them (they must outlive stop: leave_batch is sent
        // last); a failed or abandoned run closes every one of them here.
        var pins: [UUID: NASPinnedRoot] = [:]
        defer {
            for (_, pin) in pins { pin.close() }
        }

        // 1. Join batch on each registered root with finite retry and identity verification
        var acceptedRoots: [NASAcceptedRoot] = []
        var joinFailureReasons: [String] = []

        // Fresh descriptor resolve for every selected folder; the join below uses exactly these results (never stale cache).
        var fresh: [(folder: NASHelperFolder, outcome: NASFolderResolveOutcome)] = []
        let candidateFolders = targetFolderIDs.map { ids in selectedFolders.filter { ids.contains($0.id) } } ?? selectedFolders
        for folder in candidateFolders {
            let generation = beginResolve(id: folder.id)
            let pinned = await NASHelperCoordinator.pinAndResolve(
                transport: transport, url: folder.url, folderID: folder.id, connection: connection
            )
            guard !Task.isCancelled, runState != .stopped else {
                pinned.pin?.close()
                finishResolve(id: folder.id, generation: generation, outcome: nil)
                return
            }
            if let pin = pinned.pin { pins[folder.id] = pin }
            let outcome = pinned.outcome
            finishResolve(id: folder.id, generation: generation, outcome: outcome)
            if let outcome, selectedFolders.contains(where: { $0.id == folder.id }) {
                fresh.append((folder: folder, outcome: outcome))
            }
        }
        statusMessage = "NAS 협업 작업을 연결하고 있습니다…"

        for (folder, outcome) in fresh {
            let desc: NASWireRootDescriptor
            switch outcome {
            case .unregistered:
                continue
            case .readFailure(let message):
                joinFailureReasons.append("NAS 등록 정보를 읽지 못했습니다: \(message)")
                continue
            case .descriptor(let resolved):
                desc = resolved
            }
            // The descriptor (possibly a cached root.json, so its server_version is never trusted or used to block) only
            // names the root, generation, job and coordinator to ask. Capability comes solely from the fresh immutable
            // join answer of the unique request below; there is no mutable legacy fallback.
            guard let activeJobID = desc.active_job_id ?? desc.active_jobs.first else {
                joinFailureReasons.append("진행 중인 협업 작업이 없습니다.")
                continue
            }
            guard let pin = pins[folder.id] else {
                joinFailureReasons.append(NASPinnedRoot.fault(EBADF).localizedDescription)
                continue
            }

            do {
                // FIRST join MUST request slots_offered<=4 (older server parser rejects >4).
                let firstJoinSlots = min(NASHelperWire.maxSlotsPerRoot, 3 * effectiveParallelLimit)
                let joinReq = NASWireInboxRequest.makeJoin(
                    rootID: desc.root_id,
                    rootGeneration: desc.root_generation,
                    clientID: currentClient,
                    slots: firstJoinSlots,
                    targetJobID: activeJobID
                )
                // Exactly one inbox submission per root (no infinite join generation)
                try await transport.submitInboxRequest(root: pin, request: joinReq)

                // The answer of THIS request is waited for up to 120 s on its own immutable name only: the same pending
                // request ID throughout, no new ID, no fast fallback to the mutable legacy join_response.json.
                let joinWait = try await transport.waitForJoinResponse(
                    root: pin,
                    clientID: currentClient,
                    requestID: joinReq.request_id,
                    timeoutSeconds: 120,
                    source: .immutable
                )
                let joinResp = joinWait.response
                guard let immutableAnswer = joinWait.immutable else {
                    throw NASHelperTransportError.responseSchemaMismatch("immutable join answer missing")
                }
                // The coordinator epoch is adopted only from this exact fresh answer: same request/client (validated by the
                // transport), same root and generation (checked below), the coordinator the descriptor names, and an epoch
                // that did not go backwards.
                guard immutableAnswer.coordinator_id == desc.coordinator_id,
                      immutableAnswer.coordinator_epoch >= desc.coordinator_epoch else {
                    throw NASHelperTransportError.responseSchemaMismatch("immutable join answer identity")
                }

                // Verify identity and root generation (exact flags are recorded before the throw)
                let rootIDEqual = joinResp.root_id == desc.root_id
                let generationEqual = joinResp.root_generation == desc.root_generation
                let clientIDEqual = joinResp.client_id == currentClient
                guard rootIDEqual, generationEqual, clientIDEqual else {
                    throw NASHelperTransportError.joinDiagnosed(NASJoinDiagnostic(
                        lastStatus: "identity_mismatch",
                        cause: "identity",
                        attempts: joinWait.attempts,
                        elapsedSeconds: joinWait.elapsedSeconds,
                        errnoValue: nil,
                        detail: nil,
                        expectedGeneration: desc.root_generation,
                        actualGeneration: joinResp.root_generation,
                        rootIDEqual: rootIDEqual,
                        clientIDEqual: clientIDEqual,
                        generationEqual: generationEqual,
                        lowerMessage: "NAS 응답의 Root ID 또는 Generation이 일치하지 않습니다."
                    ))
                }

                if joinResp.status == "accepted" {
                    guard immutableAnswer.features.contains(NASHelperWire.videoClaimFeature) else {
                        joinFailureReasons.append("NAS 업데이트 후 협업 가능")
                        let leaveReq = NASWireInboxRequest.makeLeave(
                            rootID: desc.root_id,
                            rootGeneration: desc.root_generation,
                            clientID: currentClient,
                            jobID: activeJobID,
                            reason: "missing_video_claim_1"
                        )
                        try? await transport.submitInboxRequest(root: pin, request: leaveReq)
                        continue
                    }

                    // The job and coordinator identity of the FIRST accepted join: the rejoin below must match them exactly.
                    let acceptedJobID = joinResp.active_job_id ?? activeJobID
                    let acceptedCoordinatorID = immutableAnswer.coordinator_id
                    let acceptedCoordinatorEpoch = immutableAnswer.coordinator_epoch

                    // From here the NAS holds our slots. Any failure before the root is registered in acceptedRoots would
                    // be missed by the final leave_batch, so it sends exactly one best-effort leave for the first job.
                    do {
                    var finalEpoch = acceptedCoordinatorEpoch
                    var finalAssignedSlots = joinResp.assigned_slots

                    // FINAL NAS CONTRACT: pipeline_slots_12 negotiation
                    // Only if this response advertises pipeline_slots_12, negotiate ONE new join request with same
                    // client/root/job and new request_id for 3*N<=12 slots before work.
                    let targetPipelineSlots = min(NASHelperWire.maxPipelineSlotsPerRoot, 3 * effectiveParallelLimit)
                    if immutableAnswer.features.contains(NASHelperWire.pipelineSlotsFeature) {
                        let expandedReq = NASWireInboxRequest.makeJoin(
                            rootID: desc.root_id,
                            rootGeneration: desc.root_generation,
                            clientID: currentClient,
                            slots: targetPipelineSlots,
                            targetJobID: acceptedJobID
                        )
                        try await transport.submitInboxRequest(root: pin, request: expandedReq)

                        let expandedWait = try await transport.waitForJoinResponse(
                            root: pin,
                            clientID: currentClient,
                            requestID: expandedReq.request_id,
                            timeoutSeconds: 120,
                            source: .immutable
                        )
                        let expandedResp = expandedWait.response
                        guard let expandedImmutable = expandedWait.immutable else {
                            throw NASHelperTransportError.responseSchemaMismatch("immutable expanded join answer missing")
                        }
                        // The rejoin must come from the very coordinator and epoch that accepted the first join.
                        guard expandedImmutable.coordinator_id == acceptedCoordinatorID,
                              expandedImmutable.coordinator_epoch == acceptedCoordinatorEpoch else {
                            throw NASHelperTransportError.responseSchemaMismatch("immutable expanded join answer identity")
                        }
                        guard expandedResp.root_id == desc.root_id,
                          expandedResp.root_generation == desc.root_generation,
                          expandedResp.client_id == currentClient else {
                            throw NASHelperTransportError.responseSchemaMismatch("expanded join identity mismatch")
                        }
                        guard expandedResp.status == "accepted" else {
                            throw NASHelperTransportError.responseSchemaMismatch("expanded join not accepted: \(expandedResp.reason_code)")
                        }
                        guard expandedImmutable.features.contains(NASHelperWire.videoClaimFeature) else {
                            throw NASHelperTransportError.responseSchemaMismatch("expanded join missing video_claim_1")
                        }
                        // The expanded answer must name the accepted job itself (a missing job is never filled in) and
                        // grant a slot count inside the range this client asked for.
                        guard let expandedJobID = expandedResp.active_job_id, expandedJobID == acceptedJobID,
                              (1...targetPipelineSlots).contains(expandedResp.assigned_slots) else {
                            throw NASHelperTransportError.responseSchemaMismatch("expanded join job or slots")
                        }
                        finalEpoch = expandedImmutable.coordinator_epoch
                        finalAssignedSlots = expandedResp.assigned_slots
                    }

                    let jobID = acceptedJobID
                    // Bind the pin to the verified immutable join facts, once; offers of another root/generation are refused later.
                    guard pin.bind(rootID: desc.root_id, generation: desc.root_generation, epoch: finalEpoch) else {
                        throw NASHelperTransportError.responseSchemaMismatch("root binding")
                    }
                    acceptedRoots.append(NASAcceptedRoot(
                        pin: pin,
                        rootID: desc.root_id,
                        rootGeneration: desc.root_generation,
                        // The epoch the NAS really runs, from the verified immutable answer of this very request.
                        coordinatorEpoch: finalEpoch,
                        activeJobID: jobID,
                        assignedSlots: finalAssignedSlots,
                        immutableControl: true
                    ))
                    } catch {
                        let leaveReq = NASWireInboxRequest.makeLeave(
                            rootID: desc.root_id,
                            rootGeneration: desc.root_generation,
                            clientID: currentClient,
                            jobID: acceptedJobID,
                            reason: "rejoin_failed"
                        )
                        // Detached so a cancelled parent cannot cancel the leave; the pin is captured strongly and stays
                        // open until the leave has finished (the loop's defer closes it only after this await).
                        let leaveTransport = transport
                        let leavePin = pin
                        await Task.detached(priority: .userInitiated) {
                            try? await leaveTransport.submitInboxRequest(root: leavePin, request: leaveReq)
                        }.value
                        throw error
                    }
                } else {
                    joinFailureReasons.append("NAS 협업 참여 거부됨: \(joinResp.reason_code)")
                }
            } catch is CancellationError {
                joinFailureReasons.append("NAS 협업 참여 요청이 취소되었습니다.")
            } catch let error as NASHelperTransportError {
                switch error {
                case .joinDiagnosed, .responseSchemaMismatch:
                    // Timeout / schema / identity failure of the immutable join: fail closed with an actionable hint.
                    joinFailureReasons.append(error.localizedDescription + Self.immutableJoinUnavailableHint)
                default:
                    joinFailureReasons.append(error.localizedDescription)
                }
            } catch {
                // Classified via enum/errno only; raw localizedDescription is never shown (may contain paths)
                let classified = NASJoinDiagnostic.classify(error)
                joinFailureReasons.append("\(classified.message) [join=\(classified.cause)\(classified.errnoValue.map { " errno=\($0)" } ?? "")]" + Self.immutableJoinUnavailableHint)
            }
        }

        // If all roots failed, terminate into clean stopped state with actionable message
        if acceptedRoots.isEmpty {
            runState = .stopped
            connectionStatusText = "도움 정지됨"
            statusMessage = joinFailureReasons.first
                ?? (fresh.isEmpty ? "NAS 응답을 읽지 못했습니다. 연결을 확인한 뒤 다시 시작해 주세요." : "NAS 앱에 등록한 폴더를 선택해 주세요.")
            activeMainLoopTask = nil
            return
        }

        // Partial or full join success
        if !joinFailureReasons.isEmpty {
            statusMessage = "일부 폴더 연결 실패 (\(acceptedRoots.count)개 연결됨). 변환 작업을 확인합니다."
        } else {
            statusMessage = "NAS 협업 작업을 연결했습니다. 작업 배정을 확인합니다."
        }
        connectionStatusText = "도움 실행 중"
        joinedRoots = acceptedRoots
        applyParallelLimits()

        // 2. Continuous work request and status loop restricted strictly to accepted roots
        while runState != .stopped && !Task.isCancelled && connection == connectionSerial {
            await updateAuthoritativeJobStatus(for: acceptedRoots, connection: connection, clientID: currentClient)
            guard connection == connectionSerial else { break }

            // Verified terminal roots get no new request; their pending request identity is dropped (no new ID issued).
            for root in acceptedRoots where isVerifiedTerminal(root) {
                outstandingWorkRequests.removeValue(forKey: root.rootID)
            }

            // Result-preserving normal stop: every still-selected joined root has a matching known terminal status and
            // no attempt is still running (active attempts keep their heartbeat/receipt until their final outcome).
            if activeAttempts.isEmpty, let terminalText = terminalStopMessage(acceptedRoots: acceptedRoots) {
                finishAtTerminal(message: terminalText)
                break
            }

            if runState == .paused {
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            // Only request new work while running attempts < inFlightLimit and the cache volume has room.
            var assignedNow = false
            refreshParallelStatus()
            if activeAttempts.count < inFlightLimit, !diskHoldUntilAttemptEnds {
                if diskAllowsAnotherAttempt() {
                    if diskHoldActive {
                        diskHoldActive = false
                        refreshParallelStatus()
                    }
                    assignedNow = await checkAndRequestWork(clientID: currentClient, acceptedRoots: acceptedRoots)
                } else if !diskHoldActive {
                    diskHoldActive = true
                    refreshParallelStatus()
                }
            }

            // Every still-selected root blocked and nothing running: end this connection cleanly so the user can
            // restart explicitly. Markers stay until that restart.
            let liveRoots = acceptedRoots.filter { isRootStillSelected($0) }
            if activeAttempts.isEmpty, !liveRoots.isEmpty, liveRoots.allSatisfy({ blockedRoots[$0.rootID] != nil || isVerifiedTerminal($0) }),
               liveRoots.contains(where: { blockedRoots[$0.rootID] != nil }) {
                let blockedText = blockedRootsStatusText(acceptedRoots: acceptedRoots) ?? statusMessage
                let stoppedByFailure = liveRoots.contains { blockedRoots[$0.rootID]?.reason == .repeatedFailure }
                stopHelperInternal(preservingFailure: stoppedByFailure)
                statusMessage = blockedText
                if stoppedByFailure {
                    connectionStatusText = "반복 실패로 정지됨"
                    needsManualRestart = true
                    // Only an explicit user start resumes after repeated failures (also blocks launch auto-participation).
                    setUserStopped(true)
                }
                break
            }

            if !assignedNow {
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // On shutdown, submit leave_batch strictly to accepted roots
        for root in acceptedRoots {
            let leaveReq = NASWireInboxRequest.makeLeave(
                rootID: root.rootID,
                rootGeneration: root.rootGeneration,
                clientID: currentClient,
                jobID: root.activeJobID,
                reason: "client_shutdown"
            )
            try? await transport.submitInboxRequest(root: root.pin, request: leaveReq)
        }
        if connection == connectionSerial {
            cancelStatusRefreshes()
        }
        if connection == connectionSerial, runState == .stopped {
            joinedRoots = []
            refreshParallelStatus()
        }
    }

    private func cancelStatusRefreshes() {
        for (_, task) in statusRefreshTasks { task.cancel() }
        statusRefreshTasks.removeAll()
        statusRefreshTokens.removeAll()
        statusRefreshStartedAt.removeAll()
        pendingStatusRequests.removeAll()
    }

    /// Stores each joined root's authenticated status and republishes the counts summed over all still-selected roots.
    /// A missing/unreadable file keeps that root's earlier status of THIS connection (never invents one); a status whose
    /// root/job/generation/epoch or state is not exactly the joined one is dropped as stale/foreign.
    private func updateAuthoritativeJobStatus(for acceptedRoots: [NASAcceptedRoot], connection: Int, clientID: String) async {
        for root in acceptedRoots where isRootStillSelected(root) {
            if root.immutableControl {
                // Immutable control: freshness comes from an explicit unique request-response in its own bounded task,
                // never from the mutable job_status.json (which a mount may serve stale).
                startFreshStatusRefresh(root: root, connection: connection, clientID: clientID)
                continue
            }
            do {
                let status = try await transport.readJobStatus(root: root.pin, jobID: root.activeJobID)
                guard connection == connectionSerial else { return }
                guard let status else { continue }
                storeStatus(status, for: root)
            } catch {
                guard connection == connectionSerial else { return }
                // Keep this connection's earlier status on transient read failure
            }
        }
        publishAggregateCounts(acceptedRoots: acceptedRoots)
    }

    /// Keeps a status only when root/job/generation/epoch and state are exactly those of the joined root.
    private func storeStatus(_ status: NASWireJobStatus, for root: NASAcceptedRoot) {
        if status.root_id == root.rootID,
           status.root_generation == root.rootGeneration,
           status.coordinator_epoch == root.coordinatorEpoch,
           status.job_id == root.activeJobID,
           Self.knownJobStates.contains(status.state) {
            rootStatuses[root.rootID] = NASRootStatus(
                rootID: root.rootID,
                rootGeneration: root.rootGeneration,
                coordinatorEpoch: root.coordinatorEpoch,
                jobID: root.activeJobID,
                state: status.state,
                counts: status.counts
            )
        } else {
            rootStatuses.removeValue(forKey: root.rootID)
        }
    }

    /// Starts one bounded status request-response for the root unless one is already in flight or the last one was
    /// started less than `statusRefreshIntervalSeconds` ago. The result is applied on the main actor of the SAME connection only.
    private func startFreshStatusRefresh(root: NASAcceptedRoot, connection: Int, clientID: String) {
        guard statusRefreshTasks[root.rootID] == nil,
              Date().timeIntervalSince(statusRefreshStartedAt[root.rootID] ?? .distantPast) >= Self.statusRefreshIntervalSeconds
        else { return }
        statusRefreshStartedAt[root.rootID] = Date()
        let trans = transport
        // A still-fresh unanswered request is polled again as it is (same ID); an expired one is dropped for a new one.
        var pending = pendingStatusRequests[root.rootID]
        if let current = pending, Date().timeIntervalSince(current.submittedAt) >= Self.statusRequestMaxPendingSeconds {
            pendingStatusRequests.removeValue(forKey: root.rootID)
            pending = nil
        }
        let reused = pending
        let token = UUID()
        statusRefreshTokens[root.rootID] = token
        statusRefreshTasks[root.rootID] = Task { [weak self] in
            guard let self else { return }
            // Every exit (success, error, cancellation, early return) clears this task's own entry, never a newer one.
            defer { self.clearStatusRefresh(rootID: root.rootID, token: token) }
            var status: NASWireJobStatus?
            do {
                var requestID = reused?.requestID
                if requestID == nil {
                    let request = try await trans.submitStatusRequest(
                        root: root.pin,
                        rootID: root.rootID,
                        rootGeneration: root.rootGeneration,
                        clientID: clientID,
                        jobID: root.activeJobID
                    )
                    requestID = request.request_id
                    guard connection == self.connectionSerial, !Task.isCancelled else { return }
                    self.pendingStatusRequests[root.rootID] = NASPendingStatusRequest(requestID: request.request_id, submittedAt: Date())
                }
                if let requestID {
                    status = try await trans.awaitStatusResponse(
                        root: root.pin,
                        clientID: clientID,
                        requestID: requestID,
                        timeoutSeconds: Self.statusResponseWaitSeconds
                    )
                }
            } catch {
                // Not answered / not readable in this pass: the pending request stays (bounded by its 120 s window).
            }
            if status == nil, !Task.isCancelled {
                // No answer: the NAS stops polling a root's inbox once its job ended, so look for the final snapshot.
                status = try? await trans.readFinalJobStatus(root: root.pin, jobID: root.activeJobID)
            }
            self.finishFreshStatusRefresh(root: root, connection: connection, status: status)
        }
    }

    private func clearStatusRefresh(rootID: String, token: UUID) {
        guard statusRefreshTokens[rootID] == token else { return }
        statusRefreshTokens.removeValue(forKey: rootID)
        statusRefreshTasks.removeValue(forKey: rootID)
    }

    private func finishFreshStatusRefresh(root: NASAcceptedRoot, connection: Int, status: NASWireJobStatus?) {
        guard connection == connectionSerial else { return }
        guard isRootStillSelected(root), let status else { return }
        // An answer (or the authenticated final snapshot) resolves the pending request; the next refresh asks anew.
        pendingStatusRequests.removeValue(forKey: root.rootID)
        storeStatus(status, for: root)
        publishAggregateCounts(acceptedRoots: joinedRoots)
    }

    /// Sums counts over all still-selected joined roots. Until every such root has an authenticated status the
    /// aggregate stays unknown (nil / "확인 중"): a partial sum is never shown as the authoritative total.
    private func publishAggregateCounts(acceptedRoots: [NASAcceptedRoot]) {
        let live = acceptedRoots.filter { isRootStillSelected($0) }
        let known = live.compactMap { rootStatuses[$0.rootID] }
        guard !live.isEmpty, known.count == live.count else {
            nasAuthoritativeCounts = NASAuthoritativeCounts()
            return
        }
        var sum = NASAuthoritativeCounts()
        sum.totalItems = known.reduce(0) { $0 + $1.counts.total_items }
        sum.queued = known.reduce(0) { $0 + $1.counts.queued }
        sum.queuedNas = known.reduce(0) { $0 + $1.counts.queued_nas }
        sum.localProcessing = known.reduce(0) { $0 + $1.counts.local_processing }
        sum.macProcessing = known.reduce(0) { $0 + $1.counts.mac_processing }
        sum.verifying = known.reduce(0) { $0 + $1.counts.verifying }
        sum.completedCount = known.reduce(0) { $0 + $1.counts.completed }
        sum.failedCount = known.reduce(0) { $0 + $1.counts.failed }
        sum.deferredCount = known.reduce(0) { $0 + $1.counts.deferred }
        sum.cancelledCount = known.reduce(0) { $0 + $1.counts.cancelled }
        sum.manualAttentionCount = known.reduce(0) { $0 + $1.counts.manual_attention }
        let states = Set(known.map(\.state))
        sum.jobState = states.count == 1 ? states.first : nil
        nasAuthoritativeCounts = sum
    }

    /// True only for a stored (identity-matched) status whose state is one of the frozen terminal job states.
    private func isVerifiedTerminal(_ root: NASAcceptedRoot) -> Bool {
        guard let status = rootStatuses[root.rootID] else { return false }
        return Self.terminalJobStates.contains(status.state)
    }

    /// Final text once ALL still-selected joined roots are verified terminal; nil while any root is non-terminal or unknown.
    /// Success wording requires every root `completed` and NAS counts that are mutually consistent.
    private func terminalStopMessage(acceptedRoots: [NASAcceptedRoot]) -> String? {
        let live = acceptedRoots.filter { isRootStillSelected($0) }
        guard !live.isEmpty, live.allSatisfy({ isVerifiedTerminal($0) }) else { return nil }
        let statuses = live.compactMap { rootStatuses[$0.rootID] }
        guard statuses.count == live.count else { return nil }

        func total(_ key: KeyPath<NASWireJobStatus.Counts, Int>) -> Int {
            statuses.reduce(0) { $0 + $1.counts[keyPath: key] }
        }
        let items = total(\.total_items)
        let completed = total(\.completed)
        let failed = total(\.failed)
        let deferred = total(\.deferred)
        let cancelled = total(\.cancelled)
        let manual = total(\.manual_attention)
        let open = total(\.queued) + total(\.queued_nas) + total(\.local_processing) + total(\.mac_processing) + total(\.verifying)

        let consistent = open == 0 && items == completed + failed + deferred + cancelled + manual
        let allCompleted = statuses.allSatisfy { $0.state == "completed" }
        var text: String
        if allCompleted, consistent, items > 0, completed == items {
            text = "NAS 전체 완료: \(items)개 항목을 NAS가 확인·저장했습니다."
        } else if !consistent {
            text = "NAS 작업이 종료되었지만 항목 집계가 일치하지 않아 정상 완료로 표시하지 않습니다. NAS 앱에서 확인해 주세요."
        } else {
            text = "NAS 작업이 정상 완료 없이 종료되었습니다 (완료 \(completed), 실패 \(failed), 취소 \(cancelled), 보류 \(deferred), 수동 확인 \(manual) / 전체 \(items)). NAS 앱에서 확인해 주세요."
        }
        if localProgress.failedCount > 0 {
            text += " 이 Mac의 실패 시도 \(localProgress.failedCount)건은 위 NAS 집계와 별개로 기록됩니다."
        }
        return text
    }

    /// Normal stop at NAS terminal state: no attempt is running, so unlike `stopHelper` the local result
    /// (processed/failed counters, last error, `.failed` stage) is kept as is.
    private func finishAtTerminal(message: String) {
        runState = .stopped
        connectionStatusText = "NAS 작업 종료"
        statusMessage = message
        activeMainLoopTask = nil
        if localProgress.stage != .failed {
            localProgress.stage = .idle
            localProgress.stageFraction = nil
            localProgress.currentFileName = nil
            localProgress.phaseLabel = nil
        }
        localProgress.activeSlotsInUse = activeAttempts.count
    }

    /// Pre-acquires cache and prefetch capacity BEFORE sending request_work to prevent over-fetching.
    /// If work is assigned, the attempt takes ownership of both permits and releases them across stages.
    /// If no work is assigned or error occurs, permits are released immediately.
    /// Returns true when an attempt was started (the loop then asks again without waiting).
    private func checkAndRequestWork(clientID: String, acceptedRoots: [NASAcceptedRoot]) async -> Bool {
        guard activeAttempts.count < inFlightLimit else { return false }

        // Acquire cache and prefetch capacity BEFORE requesting work
        let cLimiter = cacheLimiter
        let pLimiter = prefetchLimiter

        guard await cLimiter.availableCount > 0, await pLimiter.availableCount > 0 else {
            return false
        }

        do {
            try await cLimiter.acquire()
        } catch {
            return false
        }

        do {
            try await pLimiter.acquire()
        } catch {
            await cLimiter.release()
            return false
        }

        var workAssigned = false

        for root in acceptedRoots {
            guard runState.isRunning else { break }
            // A removed root is no longer polled; a blocked root stays blocked until explicit helper restart.
            guard isRootStillSelected(root), blockedRoots[root.rootID] == nil else { continue }
            // A verified terminal root gets no new or repeated request; its pending identity was dropped by the loop.
            guard !isVerifiedTerminal(root) else {
                outstandingWorkRequests.removeValue(forKey: root.rootID)
                continue
            }

            do {
                let workReq: NASWireInboxRequest
                if let pending = outstandingWorkRequests[root.rootID] {
                    if Date().timeIntervalSince(pending.submittedAt) >= Self.workRequestMaxOutstandingSeconds {
                        // Unresolved past the NAS offer window: keep the pending identity, never issue a new ID.
                        blockRoot(root, reason: .requestUnanswered)
                        continue
                    }
                    // Reuse the SAME request ID; never allocate a second request while one is outstanding.
                    workReq = pending.request
                } else {
                    // A new request is only sent while this root still has a free server-assigned slot (no pending request is affected).
                    let rootActive = activeAttempts.values.filter { $0.pin.folderID == root.pin.folderID }.count
                    guard rootActive < root.assignedSlots else { continue }
                    let newReq = NASWireInboxRequest.makeRequestWork(
                        rootID: root.rootID,
                        rootGeneration: root.rootGeneration,
                        clientID: clientID,
                        jobID: root.activeJobID,
                        availableSlots: max(1, min(
                            inFlightLimit - activeAttempts.count,
                            root.assignedSlots - rootActive
                        ))
                    )
                    try await transport.submitInboxRequest(root: root.pin, request: newReq)
                    outstandingWorkRequests[root.rootID] = NASOutstandingWorkRequest(
                        request: newReq,
                        submittedAt: Date(),
                        folderID: root.pin.folderID
                    )
                    workReq = newReq
                }

                let workResp = try await transport.waitForWorkResponse(
                    root: root.pin,
                    clientID: clientID,
                    requestID: workReq.request_id,
                    timeoutSeconds: 15,
                    source: root.immutableControl ? .immutable : .legacy
                )
                nasShareNote = nil

                if workResp.status == "assigned",
                   let offerPath = workResp.offer_relative_path {
                    let offer = try await transport.readOffer(
                        root: root.pin,
                        offerRelativePath: offerPath,
                        expectedClientID: clientID
                    )

                    outstandingWorkRequests.removeValue(forKey: root.rootID)

                    // Late offer: helper stopped, root removed or root became terminal while we waited. Never start
                    // new work from it; hand the attempt back with its own fencing identity.
                    guard runState.isRunning, isRootStillSelected(root), !isVerifiedTerminal(root), blockedRoots[root.rootID] == nil,
                          activeAttempts.count < inFlightLimit else {
                        let lateRelease = NASWireInboxRequest.makeRelease(
                            rootID: offer.root_id,
                            rootGeneration: offer.root_generation,
                            clientID: offer.assigned_client_id,
                            jobID: offer.job_id,
                            itemID: offer.item_id,
                            coordinatorEpoch: offer.coordinator_epoch,
                            attemptID: offer.attempt_id,
                            fencingToken: offer.fencing_token,
                            reason: runState == .stopped ? "client_shutdown" : "user_cancelled"
                        )
                        try? await transport.submitInboxRequest(root: root.pin, request: lateRelease)
                        break
                    }

                    // The offer names the real size: it must fit next to the attempts that are already running.
                    if let free = cacheVolumeFreeBytes(),
                       free < Self.minimumFreeCacheBytes + reservedCacheBytes() + 2 * max(0, offer.source_size_bytes) {
                        let shortRelease = NASWireInboxRequest.makeRelease(
                            rootID: offer.root_id,
                            rootGeneration: offer.root_generation,
                            clientID: offer.assigned_client_id,
                            jobID: offer.job_id,
                            itemID: offer.item_id,
                            coordinatorEpoch: offer.coordinator_epoch,
                            attemptID: offer.attempt_id,
                            fencingToken: offer.fencing_token,
                            reason: "resource_exhaustion"
                        )
                        try? await transport.submitInboxRequest(root: root.pin, request: shortRelease)
                        if activeAttempts.isEmpty {
                            // Nothing else is running, so this Mac cannot take the file at all: a real failure.
                            recordFailureForBreaker(rootID: offer.root_id, itemID: offer.item_id, folderID: root.pin.folderID)
                            localProgress.failedCount += 1
                            localProgress.lastError = "Mac 저장 공간이 부족해 영상을 받을 수 없습니다."
                            statusMessage = "Mac 저장 공간이 부족해 영상을 받을 수 없습니다. 공간을 확보한 뒤 다시 시작해 주세요."
                        } else {
                            diskHoldUntilAttemptEnds = true
                            diskHoldActive = true
                            refreshParallelStatus()
                            setRequestStatus("Mac 저장 공간이 부족해 새 영상 시작을 잠시 멈췄습니다.")
                        }
                        break
                    }

                    // Response and offer consumed; attempt takes over the acquired cache and prefetch slots
                    workAssigned = true
                    startAttempt(pin: root.pin, offer: offer, immutableControl: root.immutableControl)
                    break
                } else if workResp.status == "queue_empty" {
                    outstandingWorkRequests.removeValue(forKey: root.rootID)
                    setRequestStatus("대기열에 배정 가능한 변환 작업이 없습니다.")
                } else {
                    outstandingWorkRequests.removeValue(forKey: root.rootID)
                    if workResp.reason_code == "SLOT_LIMIT_REACHED" {
                        nasShareNote = "NAS가 동시 처리 한도를 다른 Mac과 나눠 배정하고 있습니다."
                        refreshParallelStatus()
                        setRequestStatus("NAS가 동시 처리 한도를 다른 Mac과 나눠 배정하고 있습니다.")
                    } else {
                        setRequestStatus("NAS가 작업 배정을 거절했습니다 (\(workResp.reason_code)).")
                    }
                }
            } catch NASHelperTransportError.pendingRequestTimeout {
                // Keep the outstanding request; the next pass waits for the same response again (bounded by 120s).
                setRequestStatus("NAS 응답을 기다리는 중입니다. 같은 요청을 유지합니다.")
            } catch {
                // Classified by type/code only; error text (may hold paths, IDs, tokens) is never displayed.
                switch NASWorkReadClassifier.classify(error) {
                case .cancelled:
                    break
                case .transientAbsence where outstandingWorkRequests[root.rootID] != nil:
                    // Actual ENOENT / Cocoa no-such-file only: keep the SAME request, re-read within the 120s bound.
                    setRequestStatus("NAS가 배정한 Offer 파일이 아직 보이지 않습니다. 같은 요청으로 다시 확인합니다.")
                case .offerExpired:
                    // The NAS closed this offer window itself: the request legitimately ended.
                    outstandingWorkRequests.removeValue(forKey: root.rootID)
                    setRequestStatus("배정된 Offer 유효 기간이 지났습니다. 다음 확인에서 새 요청을 보냅니다.")
                case .safetyBlock:
                    blockRoot(root, reason: .safety)
                case .transientAbsence, .ioBlock:
                    blockRoot(root, reason: .io)
                }
            }
        }

        if let blockedText = blockedRootsStatusText(acceptedRoots: acceptedRoots) {
            statusMessage = blockedText
        }

        if !workAssigned {
            await pLimiter.release()
            await cLimiter.release()
        }
        return workAssigned
    }

    /// Idle request-loop status never overwrites an attempt failure message (`.failed` stays until the next attempt starts).
    private func setRequestStatus(_ message: String) {
        guard localProgress.stage != .failed else { return }
        statusMessage = message
    }

    private func isRootStillSelected(_ root: NASAcceptedRoot) -> Bool {
        selectedFolders.contains { $0.id == root.pin.folderID }
    }

    /// Marks the root blocked for the rest of this connection. The pending request identity (if any) is kept as is.
    private func blockRoot(_ root: NASAcceptedRoot, reason: NASRootBlockReason) {
        blockedRoots[root.rootID] = NASBlockedRoot(reason: reason, folderID: root.pin.folderID)
    }

    /// Legitimate end of a root (folder removed): the only non-restart reset of its markers.
    private func releaseWorkMarkers(forFolderID id: UUID) {
        outstandingWorkRequests = outstandingWorkRequests.filter { $0.value.folderID != id }
        blockedRoots = blockedRoots.filter { $0.value.folderID != id }
    }

    /// Fixed-text status for blocked roots (no paths, IDs, tokens or raw error text).
    private func blockedRootsStatusText(acceptedRoots: [NASAcceptedRoot]) -> String? {
        let live = acceptedRoots.filter { isRootStillSelected($0) }
        let blocked = live.compactMap { blockedRoots[$0.rootID]?.reason }
        guard !blocked.isEmpty else { return nil }
        if blocked.contains(.repeatedFailure) {
            if blocked.count < live.count {
                return "변환이 연속 \(Self.repeatedFailureLimit)번 실패한 폴더 \(blocked.count)개의 작업 수령을 멈췄습니다. 나머지 폴더는 계속 진행합니다. 원인을 확인한 뒤 도움을 중지하고 다시 시작해 주세요."
            }
            return "변환이 연속 \(Self.repeatedFailureLimit)번 실패해 작업 수령을 멈췄습니다. 원인을 확인한 뒤 도움 시작을 눌러 주세요."
        }
        let cause: String
        if blocked.contains(.safety) {
            cause = "Offer 경로·신원·펜싱·형식 검증에 실패해 안전을 위해"
        } else if blocked.contains(.io) {
            cause = "NAS 파일 입출력 오류로"
        } else {
            cause = "NAS가 \(Int(Self.workRequestMaxOutstandingSeconds))초 안에 작업 요청을 마치지 않아"
        }
        if blocked.count < live.count {
            return "폴더 \(blocked.count)개를 \(cause) 중단했습니다. 나머지 폴더는 계속 진행합니다. 해당 폴더는 도움을 정지한 뒤 다시 시작해야 재개됩니다."
        }
        return "모든 폴더를 \(cause) 중단했습니다. 도움을 다시 시작하면 새 연결로 재개합니다."
    }

    // MARK: - Individual Attempt Execution

    private func startAttempt(pin: NASPinnedRoot, offer: NASWireOffer, immutableControl: Bool) {
        let attemptID = offer.attempt_id
        let jobID = offer.job_id
        let itemID = offer.item_id

        // Create private workspace directory with mode 0700
        let tempDir = (try? NASPathSecurity.realpathURL(of: FileManager.default.temporaryDirectory))
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let workspaceURL = tempDir.appendingPathComponent("mac_helper_\(attemptID)", isDirectory: true)

        let handle = NASActiveAttemptHandle(
            attemptID: attemptID,
            jobID: jobID,
            itemID: itemID,
            pin: pin,
            offer: offer,
            workspaceURL: workspaceURL,
            connection: connectionSerial,
            immutableControl: immutableControl
        )
        activeAttempts[attemptID] = handle
        unwindingAttemptTasks += 1
        failureStagePending = false
        activeAttemptDetails.append(NASHelperAttemptDetail(
            id: attemptID,
            fileName: offer.source_path_components.last ?? "영상 파일",
            stage: .downloading,
            fraction: nil,
            phaseLabel: "Heartbeat seq 1 승인 대기 중",
            downloadFraction: nil,
            encodingFraction: nil,
            uploadFraction: nil
        ))
        republishLocalProgress()
        localProgress.activeSlotsInUse = activeAttempts.count
        refreshParallelStatus()

        let env = toolEnvironment
        let encLimiter = encodeLimiter
        let prefLimiter = prefetchLimiter
        let postLimiter = postEncodeLimiter
        let bridge = engineBridge
        let trans = transport
        let dlLimiter = downloadLimiter
        let ulLimiter = uploadLimiter
        let cLimiter = cacheLimiter

        handle.task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.executeAttempt(
                handle: handle,
                environment: env,
                transport: trans,
                engineBridge: bridge,
                cacheLimiter: cLimiter,
                prefetchLimiter: prefLimiter,
                downloadLimiter: dlLimiter,
                currentEncodeLimiter: encLimiter,
                postEncodeLimiter: postLimiter,
                uploadLimiter: ulLimiter
            )
        }
    }

    // MARK: - Per-Attempt Display and Failure Books

    /// Aggregates the running attempts into the single `localProgress` view: the oldest attempt plus a count.
    private func republishLocalProgress() {
        guard let lead = activeAttemptDetails.first else { return }
        let others = activeAttemptDetails.count - 1
        localProgress.currentFileName = others > 0 ? "\(lead.fileName) 외 \(others)개" : lead.fileName
        localProgress.stage = lead.stage
        localProgress.stageFraction = lead.fraction
        localProgress.phaseLabel = lead.phaseLabel
    }

    private func updateAttemptDisplay(_ attemptID: String, _ change: (inout NASHelperAttemptDetail) -> Void) {
        guard let index = activeAttemptDetails.firstIndex(where: { $0.id == attemptID }) else { return }
        change(&activeAttemptDetails[index])
        republishLocalProgress()
    }

    private func removeAttemptDisplay(_ attemptID: String) {
        activeAttemptDetails.removeAll { $0.id == attemptID }
        if activeAttemptDetails.isEmpty {
            if failureStagePending {
                localProgress.stage = .failed
            } else if localProgress.stage != .failed {
                localProgress.stage = .idle
            }
            localProgress.stageFraction = nil
            localProgress.currentFileName = localProgress.stage == .failed ? localProgress.currentFileName : nil
            if localProgress.stage != .failed {
                localProgress.phaseLabel = nil
            }
        } else {
            republishLocalProgress()
        }
    }

    /// A NAS-committed receipt: the only event that resets the repeated-failure books of its root.
    private func noteAttemptCommitted(_ handle: NASActiveAttemptHandle, thumbnailFailed: Bool) {
        guard handle.connection == connectionSerial else { return }
        localProgress.processedCount += 1
        consecutiveFailures[handle.offer.root_id] = 0
        itemFailureCounts.removeValue(forKey: handle.itemID)
        if thumbnailFailed {
            statusMessage = "영상 변환 및 저장 완료 (썸네일 등록 실패 - NAS 확인 필요)"
        } else {
            statusMessage = "NAS 확인 및 저장 완료: \(handle.offer.source_path_components.last ?? "영상")"
        }
    }

    /// A real attempt failure (not a user cancel / shutdown / NAS-side cancel). Counts toward the breaker.
    private func noteAttemptFailed(_ handle: NASActiveAttemptHandle, releaseReason: String, message: String) {
        guard handle.connection == connectionSerial else { return }
        localProgress.failedCount += 1
        localProgress.lastError = message
        statusMessage = "변환 중 오류 (\(releaseReason)): \(message)"
        failureStagePending = true
        recordFailureForBreaker(rootID: handle.offer.root_id, itemID: handle.itemID, folderID: handle.pin.folderID)
        removeAttemptDisplay(handle.attemptID)
    }

    /// The NAS cancelled the attempt itself (job cancel/pause): neither a Mac failure nor a user cancel.
    private func noteAttemptCancelledByNAS(_ handle: NASActiveAttemptHandle) {
        guard handle.connection == connectionSerial else { return }
        statusMessage = "NAS가 이 영상 작업을 취소했습니다. 다음 작업을 확인합니다."
        removeAttemptDisplay(handle.attemptID)
    }

    /// Two consecutive failed attempts on one root (or the same item failing twice) block that root for this connection.
    /// Only an explicit restart clears it; the same file is never retried endlessly.
    private func recordFailureForBreaker(rootID: String, itemID: String, folderID: UUID) {
        let consecutive = (consecutiveFailures[rootID] ?? 0) + 1
        consecutiveFailures[rootID] = consecutive
        let sameItem = (itemFailureCounts[itemID] ?? 0) + 1
        itemFailureCounts[itemID] = sameItem
        guard consecutive >= Self.repeatedFailureLimit || sameItem >= Self.repeatedFailureLimit else { return }
        guard blockedRoots[rootID]?.reason != .repeatedFailure else { return }
        blockedRoots[rootID] = NASBlockedRoot(reason: .repeatedFailure, folderID: folderID)
        needsManualRestart = true
        applyParallelLimits()
    }

    nonisolated private func executeAttempt(
        handle: NASActiveAttemptHandle,
        environment: NASToolEnvironment,
        transport: NASHelperTransport,
        engineBridge: DefaultNASConversionEngineBridge,
        cacheLimiter: NASResourceLimiter,
        prefetchLimiter: NASResourceLimiter,
        downloadLimiter: NASResourceLimiter,
        currentEncodeLimiter: NASResourceLimiter,
        postEncodeLimiter: NASResourceLimiter,
        uploadLimiter: NASResourceLimiter
    ) async {
        let offer = handle.offer
        let root = handle.pin
        let workspaceURL = handle.workspaceURL
        let progress = handle.progressTracker
        let attemptID = handle.attemptID

        var cachePermitHeld = true
        var prefetchPermitHeld = true
        var encodePermitHeld = false
        var postPermitHeld = false

        // Attempt clean up when done - exactly once permit release
        defer {
            handle.heartbeatGate.close()
            if postPermitHeld {
                postPermitHeld = false
                Task { [postEncodeLimiter] in
                    await postEncodeLimiter.release()
                }
            }
            if encodePermitHeld {
                encodePermitHeld = false
                Task { [currentEncodeLimiter] in
                    await currentEncodeLimiter.release()
                }
            }
            if prefetchPermitHeld {
                prefetchPermitHeld = false
                Task { [prefetchLimiter] in
                    await prefetchLimiter.release()
                }
            }
            if cachePermitHeld {
                cachePermitHeld = false
                Task { [cacheLimiter] in
                    await cacheLimiter.release()
                }
            }
            Task { @MainActor in
                self.activeAttempts.removeValue(forKey: attemptID)
                self.localProgress.activeSlotsInUse = self.activeAttempts.count
                self.unwindingAttemptTasks = max(0, self.unwindingAttemptTasks - 1)
                self.removeAttemptDisplay(attemptID)
                // Space is freed by an ending attempt: new work may be considered again.
                self.diskHoldUntilAttemptEnds = false
                self.diskHoldActive = false
                self.refreshParallelStatus()
            }
        }

        // Set once result.json is published / the lease box exists; used only for the read-only receipt reconciliation below.
        var resultPublished = false
        var reconciliationLeaseBox: NASHeartbeatLeaseBox?

        do {
            try Task.checkCancellation()

            progress.update(stage: .downloading, stagePercent: nil, phaseLabel: "Heartbeat seq 1 승인 대기")

            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.stage = .downloading
                    $0.fraction = nil
                    $0.phaseLabel = "Heartbeat seq 1 승인 대기 중"
                    $0.downloadFraction = nil
                    $0.encodingFraction = nil
                    $0.uploadFraction = nil
                }
            }

            // Step 1: Heartbeat seq=1 plus bounded first-ACK handshake BEFORE copying.
            // Heartbeats keep flowing (strictly increasing seq, every 10s) while waiting for the first valid ACK.
            let heartbeatGate = handle.heartbeatGate
            let leaseState = try await Self.performFirstHeartbeatHandshake(
                transport: transport,
                root: root,
                offer: offer,
                immutableControl: handle.immutableControl,
                heartbeatGate: heartbeatGate
            )

            // Step 2: two independent background tasks per attempt, so that neither a slow write nor a slow read can
            // delay the other or the lease deadline (all blocking I/O is bounded and detached in the transport):
            //  - sender: a strictly increasing seq every 10 seconds, send instant recorded BEFORE the write;
            //  - watcher: reads ACKs every 2 seconds and enforces the trusted lease deadline.
            // Only a strictly advancing ack_seq renews the trusted lease, anchored to that heartbeat's SEND instant.
            let leaseBox = NASHeartbeatLeaseBox(leaseState)
            reconciliationLeaseBox = leaseBox
            let immutableControl = handle.immutableControl
            let hbSender = Task.detached(priority: .utility) {
                let clock = ContinuousClock()
                let interval = Duration.seconds(NASHeartbeatLeaseState.heartbeatIntervalSeconds)
                var due = (leaseBox.withState { $0.lastSendAt } ?? clock.now) + interval

                while !Task.isCancelled {
                    let wait = due - clock.now
                    if wait > .zero {
                        try? await Task.sleep(for: wait)
                    }
                    if Task.isCancelled || heartbeatGate.isClosed { break }

                    let snap = handle.progressTracker.snapshot
                    let sendAt = clock.now
                    // At most one REAL heartbeat write per attempt: while an earlier write's worker has not really returned
                    // (even if its await timed out) nothing is written, no seq is reserved and the lease anchor stays untouched.
                    guard let slot = heartbeatGate.tryBegin() else {
                        due = sendAt + .seconds(1)
                        continue
                    }
                    let hbSeq = leaseBox.withState { $0.reserveSeq(at: sendAt) }
                    due = sendAt + interval
                    let hb = NASWireHeartbeat.make(
                        offer: offer,
                        seq: hbSeq,
                        stage: snap.stage,
                        stagePercent: snap.percent,
                        completedBytes: snap.completedBytes,
                        totalBytes: snap.totalBytes
                    )

                    do {
                        try await transport.writeHeartbeat(root: root, offer: offer, heartbeat: hb, slot: slot)
                    } catch is CancellationError {
                        break
                    } catch {
                        // Tolerates a brief glitch, but stays bound to the conservatively anchored lease (the watcher ends it).
                        let tagged = NASIOFailureDiagnostic.tagged(.heartbeatWrite, error)
                        leaseBox.withState {
                            $0.noteWriteFailure()
                            $0.noteIOFailure(tagged)
                        }
                    }
                }
            }
            let hbWatcher = Task.detached(priority: .utility) { [weak handle] in
                let clock = ContinuousClock()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    if Task.isCancelled { break }
                    guard let handle else { return }

                    do {
                        let outcome = try await Self.pollAcks(
                            transport: transport,
                            root: root,
                            offer: offer,
                            leaseBox: leaseBox,
                            immutableControl: immutableControl
                        )
                        if case .rejected(let reason) = outcome {
                            handle.recordHeartbeatFailure(.heartbeatRejected(reason: reason))
                            handle.task?.cancel()
                            break
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        let tagged = NASIOFailureDiagnostic.tagged(.heartbeatAckRead, error)
                        leaseBox.withState {
                            $0.noteWriteFailure()
                            $0.noteIOFailure(tagged)
                        }
                    }

                    if leaseBox.withState({ $0.leaseHasExpired(at: clock.now) }) {
                        // Trusted lease ran out without a strictly advancing ACK
                        let causes = leaseBox.withState { $0.ioFailureSuffix }
                        handle.recordHeartbeatFailure(.leaseExpired("Heartbeat ACK 갱신 없이 lease 보호 시한이 지났습니다.\(causes)"))
                        handle.task?.cancel()
                        break
                    }
                }
            }
            defer {
                heartbeatGate.close()
                hbSender.cancel()
                hbWatcher.cancel()
            }

            // Private 0700 workspace root: canonical realpath, owned by this user, no symlink (engine policy requires it).
            try NASIOFailureDiagnostic.run(.workspacePrepare) {
                try NASPathSecurity.prepareOwnedWorkspaceRoot(at: workspaceURL)
            }

            // Step 3: Download source media into private workspace with cancellation-safe permit
            let sourceLocalRelative = "sources/source.bin"
            let sourceLocalURL = workspaceURL.appendingPathComponent(sourceLocalRelative)

            try await downloadLimiter.withPermit {
                try Task.checkCancellation()

                progress.update(stage: .downloading, phaseLabel: "원본 스트리밍 다운로드 중")
                await MainActor.run {
                    self.updateAttemptDisplay(attemptID) {
                        $0.stage = .downloading
                        $0.fraction = nil
                        $0.phaseLabel = "원본 스트리밍 다운로드 중 (크기·해시 검증)"
                    }
                }

                try NASHelperBulkTransferWorker.downloadSource(
                    root: root,
                    offer: offer,
                    destinationURL: sourceLocalURL,
                    onProgress: { [weak self, progress] done, total in
                        let ratio: Double? = {
                            guard total > 0 else { return nil }
                            let r = Double(done) / Double(total)
                            guard r.isFinite else { return nil }
                            return min(1.0, max(0.0, r))
                        }()
                        progress.update(
                            stage: .downloading,
                            stagePercent: ratio.map { $0 * 100.0 },
                            completedBytes: done,
                            totalBytes: total,
                            phaseLabel: "원본 다운로드 중"
                        )
                        Task { @MainActor in
                            self?.updateAttemptDisplay(attemptID) {
                                $0.downloadFraction = ratio
                                $0.fraction = ratio
                            }
                        }
                    }
                )
            }

            // Only successful operation completion may set that phase 1.
            // Reset current fraction at stage transition; never carry download 100 into encoding.
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.downloadFraction = 1.0
                    $0.fraction = nil
                    $0.phaseLabel = "변환 대기 중"
                }
            }

            // Step 4: Encode with trusted bundled engine (encode-local) with cancellation-safe permit
            let outputRelative = "out/output.mp4"
            let ext = (offer.source_path_components.last as NSString?)?.pathExtension ?? "mp4"

            try Task.checkCancellation()
            try await currentEncodeLimiter.acquire()
            encodePermitHeld = true
            // Release prefetch permit only when encoder starts
            if prefetchPermitHeld {
                prefetchPermitHeld = false
                await prefetchLimiter.release()
            }

            progress.update(stage: .encoding, phaseLabel: "번들 엔진 변환 중")
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.stage = .converting
                    $0.fraction = nil
                    $0.encodingFraction = nil
                    $0.phaseLabel = "번들 엔진(H.264/AAC) 변환 중"
                }
                self.refreshParallelStatus()
            }

            let engineResult = try await engineBridge.encodeLocal(
                environment: environment,
                workspaceRoot: workspaceURL,
                jobID: offer.job_id,
                ref: handle.engineRef,
                sourceLocalRelativePath: sourceLocalRelative,
                sourceExt: ".\(ext.lowercased())",
                sourceExpectedSize: offer.source_size_bytes,
                sourceExpectedSha256: offer.source_sha256,
                outputRelativePath: outputRelative,
                onProgress: { [weak self, progress] prog in
                    let pct = prog.phase_pct
                    let clampedPct: Double? = {
                        guard let p = pct, p.isFinite else { return nil }
                        return min(100.0, max(0.0, p))
                    }()
                    let frac = clampedPct.map { $0 / 100.0 }
                    progress.update(
                        stage: .encoding,
                        stagePercent: clampedPct,
                        phaseLabel: prog.phase_label ?? prog.phase
                    )
                    Task { @MainActor in
                        guard let self else { return }
                        self.updateAttemptDisplay(attemptID) {
                            $0.encodingFraction = frac
                            $0.fraction = frac
                            $0.phaseLabel = prog.phase_label ?? prog.phase
                        }
                    }
                }
            )

            // Only successful operation completion may set that phase 1.
            // Reset current fraction at stage transition; never carry encoding 100 into upload.
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.encodingFraction = 1.0
                    $0.fraction = nil
                    $0.phaseLabel = "업로드 대기 중"
                }
            }

            // After successful encode reserve post capacity BEFORE releasing encoder permit,
            // so slow upload cannot accumulate unbounded results. Hold post capacity through final receipt/cleanup.
            try Task.checkCancellation()
            try await postEncodeLimiter.acquire()
            postPermitHeld = true
            if encodePermitHeld {
                encodePermitHeld = false
                await currentEncodeLimiter.release()
            }
            await MainActor.run {
                self.refreshParallelStatus()
            }

            let localMP4URL = workspaceURL.appendingPathComponent(outputRelative)

            // Step 5: Optional Thumbnail generation using AVFoundation (thumb.jpg)
            // If thumbnail generation fails, publish video with thumbnail_present=false and warn; never discard video!
            progress.update(stage: .thumbnail, phaseLabel: "고화질 썸네일 생성 중")
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.stage = .generatingThumbnail
                    $0.fraction = nil
                    $0.phaseLabel = "AVFoundation 고화질 썸네일 생성 중"
                }
            }

            var thumbUploadInfo: (size: Int64, sha256: String)? = nil
            do {
                let thumbnailData = try await generateThumbnailData(for: localMP4URL)
                let thumbSize = Int64(thumbnailData.count)
                guard thumbSize >= 100 && thumbSize <= 10_485_760 else {
                    throw NASWireValidationError.invalidJSON("썸네일 크기 범위 초과: \(thumbSize)")
                }
                let thumbnailTempURL = workspaceURL.appendingPathComponent("thumb.jpg")
                try thumbnailData.write(to: thumbnailTempURL, options: .atomic)

                let thumbUpload = try await uploadLimiter.withPermit {
                    try Task.checkCancellation()
                    return try NASHelperBulkTransferWorker.uploadCandidateFile(
                        root: root,
                        offer: offer,
                        sourceURL: thumbnailTempURL,
                        targetFilename: "thumb.jpg"
                    )
                }
                thumbUploadInfo = thumbUpload
            } catch {
                await MainActor.run {
                    self.statusMessage = "썸네일 생성 건너뜀 (영상만 저장 진행): \(error.localizedDescription)"
                }
            }

            // Step 6: Upload output MP4 (output.part fsync + rename) with cancellation-safe permit
            progress.update(stage: .uploading, phaseLabel: "변환 완료본 업로드 중")
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.stage = .uploading
                    $0.fraction = nil
                    $0.uploadFraction = nil
                    $0.phaseLabel = "변환 완료 영상 업로드 중"
                }
            }

            let mp4Upload = try await uploadLimiter.withPermit {
                try Task.checkCancellation()
                return try NASHelperBulkTransferWorker.uploadCandidateFile(
                    root: root,
                    offer: offer,
                    sourceURL: localMP4URL,
                    targetFilename: "output.mp4",
                    onProgress: { [weak self, progress] done, total in
                        let ratio: Double? = {
                            guard total > 0 else { return nil }
                            let r = Double(done) / Double(total)
                            guard r.isFinite else { return nil }
                            return min(1.0, max(0.0, r))
                        }()
                        progress.update(
                            stage: .uploading,
                            stagePercent: ratio.map { $0 * 100.0 },
                            completedBytes: done,
                            totalBytes: total,
                            phaseLabel: "완료본 업로드 중"
                        )
                        Task { @MainActor in
                            self?.updateAttemptDisplay(attemptID) {
                                $0.uploadFraction = ratio
                                $0.fraction = ratio
                            }
                        }
                    }
                )
            }

            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.uploadFraction = 1.0
                    $0.fraction = nil
                }
            }

            // Verify uploaded MP4 matches engine output size and SHA-256 before publishing result
            guard let engineOutput = engineResult.output,
                  mp4Upload.size == engineOutput.size,
                  mp4Upload.sha256.lowercased() == engineOutput.sha256.lowercased() else {
                throw NASHelperTransportError.uploadVerificationFailed("업로드된 MP4 크기 또는 해시가 엔진 결과와 불일치합니다.")
            }

            // Step 7: Publish result.json LAST!
            let clientResult = NASWireClientResult.make(
                offer: offer,
                outputSizeBytes: mp4Upload.size,
                outputSha256: mp4Upload.sha256,
                thumbnailPresent: thumbUploadInfo != nil,
                thumbnailSizeBytes: thumbUploadInfo?.size,
                thumbnailSha256: thumbUploadInfo?.sha256,
                encodeDurationMs: engineResult.elapsed_s.map { Int($0 * 1000) }
            )
            try await transport.publishResult(root: root, offer: offer, result: clientResult)
            resultPublished = true

            // Step 8: Poll for Server Receipt while lease remains positively valid
            progress.update(stage: .waitingValidation, phaseLabel: "NAS 확인 및 저장 대기")
            await MainActor.run {
                self.updateAttemptDisplay(attemptID) {
                    $0.stage = .waitingVerification
                    $0.fraction = nil
                    $0.phaseLabel = "NAS 확인 및 ‘_원본’ 보존 저장 대기 중"
                }
            }

            var receiptCommitted = false
            var lastReceiptRevision = 0
            let receiptClock = ContinuousClock()

            // The wait for the NAS (full decode validation can legitimately take minutes) is bounded ONLY by the trusted
            // lease: the same ACK-backed, send-anchored deadline the independent watcher enforces. Neither this loop nor any
            // receipt (accepted/validating included) extends it, and there is no separate overall timeout.
            while true {
                try Task.checkCancellation()
                if leaseBox.withState({ $0.leaseHasExpired(at: receiptClock.now) }) {
                    throw NASHelperTransportError.leaseExpired("NAS 확인 대기 중 Heartbeat lease 보호 시한이 지났습니다.")
                }

                let currentReceipt: NASWireServerReceipt?
                do {
                    if immutableControl {
                        // One file per revision, created once: never the mutable receipt.json.
                        let hint = leaseBox.withState { $0.latestAckReceiptRevision }
                        currentReceipt = try await transport.readImmutableServerReceipt(
                            root: root,
                            offer: offer,
                            lastRevision: lastReceiptRevision,
                            hintRevision: hint
                        )
                    } else {
                        currentReceipt = try await transport.readServerReceipt(root: root, offer: offer)
                    }
                } catch where NASHelperTransport.isTransientReadIOError(error) {
                    // A single stuck/busy mount read (timeout / full I/O gate) is not a verdict on the NAS validation:
                    // poll again while the lease stays valid. Cancellation, path, identity and schema failures are not caught.
                    currentReceipt = nil
                }
                if let receipt = currentReceipt {
                    lastReceiptRevision = max(lastReceiptRevision, receipt.receipt_revision)
                    if receipt.status == .committed {
                        receiptCommitted = true
                        await MainActor.run {
                            self.noteAttemptCommitted(handle, thumbnailFailed: receipt.thumbnail_status == "failed")
                        }
                        break
                    } else if receipt.status == .rejected || receipt.status == .retryOnNas || receipt.status == .manualAttention || receipt.status == .cancelled {
                        throw NASHelperTransportError.serverReceiptRejected(
                            status: receipt.status.rawValue,
                            code: receipt.reason_code,
                            message: receipt.reason_message
                        )
                    }
                }

                try await Task.sleep(for: .seconds(2))
            }

            guard receiptCommitted else {
                throw NASHelperTransportError.pendingRequestTimeout("server receipt")
            }

            // Successful completion: clean up workspace cache
            try? FileManager.default.removeItem(at: workspaceURL)

        } catch let cancelError where handle.heartbeatFailure == nil && (cancelError is CancellationError || handle.isCancelled) {
            // User stop / folder removal / shutdown: never a failure and never counted by the breaker.
            // Process cleanup complete before deleting cache
            engineBridge.cancel(ref: handle.engineRef)

            let isShuttingDown = await MainActor.run { self.runState == .stopped }
            let releaseReason = isShuttingDown ? "client_shutdown" : "user_cancelled"

            let releaseReq = NASWireInboxRequest.makeRelease(
                rootID: offer.root_id,
                rootGeneration: offer.root_generation,
                clientID: offer.assigned_client_id,
                jobID: offer.job_id,
                itemID: offer.item_id,
                coordinatorEpoch: offer.coordinator_epoch,
                attemptID: offer.attempt_id,
                fencingToken: offer.fencing_token,
                reason: releaseReason
            )
            try? await transport.submitInboxRequest(root: root, request: releaseReq)
            try? FileManager.default.removeItem(at: workspaceURL)

            await MainActor.run {
                guard handle.connection == self.connectionSerial else { return }
                if self.activeAttemptDetails.count <= 1, !self.failureStagePending {
                    self.localProgress.phaseLabel = "작업 취소됨"
                }
            }
        } catch {
            // A background heartbeat failure (remote rejection / lease expiry) surfaces as its own cause, not a user cancel
            var failure: Error = (error is CancellationError ? handle.heartbeatFailure : nil) ?? error

            let isFencedFailure: Bool = {
                if let transportErr = failure as? NASHelperTransportError {
                    switch transportErr {
                    case .heartbeatRejected(let reason):
                        return reason == "FENCED" || reason.contains("FENCED")
                    case .attemptFenced:
                        return true
                    default:
                        return false
                    }
                }
                return false
            }()

            // Commit ambiguity / terminal receipt reconciliation:
            // One bounded READ-ONLY look at this attempt's own immutable receipts (exact 9-tuple, strict schema).
            // A committed receipt is the authoritative result: no release, no failure.
            // A terminal rejected/retry_on_nas/manual_attention/cancelled receipt returned after a heartbeat FENCED failure
            // preserves its exact authoritative reason/status instead of dropping it for a network/download error.
            var receiptAlreadyFinal = false
            if let transportErr = failure as? NASHelperTransportError, case .serverReceiptRejected = transportErr {
                receiptAlreadyFinal = true
            }
            if (resultPublished || isFencedFailure), handle.immutableControl, !receiptAlreadyFinal, let box = reconciliationLeaseBox {
                let hint = box.withState { $0.latestAckReceiptRevision }
                // Unstructured task: the cancellation that ended this attempt must not abort the one reconciliation read.
                let known = await Task.detached(priority: .utility) {
                    try? await transport.readImmutableServerReceipt(root: root, offer: offer, lastRevision: 0, hintRevision: hint)
                }.value
                if let known {
                    if known.status == .committed {
                        engineBridge.cancel(ref: handle.engineRef)
                        try? FileManager.default.removeItem(at: workspaceURL)
                        await MainActor.run {
                            self.noteAttemptCommitted(handle, thumbnailFailed: known.thumbnail_status == "failed")
                        }
                        return
                    } else if isFencedFailure && (known.status == .rejected || known.status == .retryOnNas || known.status == .manualAttention || known.status == .cancelled) {
                        failure = NASHelperTransportError.serverReceiptRejected(
                            status: known.status.rawValue,
                            code: known.reason_code,
                            message: known.reason_message
                        )
                    }
                }
            }
            // Explicit release_attempt with defined reason
            let releaseReason: String
            if let transportErr = failure as? NASHelperTransportError {
                switch transportErr {
                case .sourceSizeMismatch, .sourceFileExceedsExpectedSize, .sourceShaMismatch:
                    releaseReason = "download_error"
                case .leaseExpired, .attemptFenced, .serverReceiptRejected:
                    releaseReason = "user_cancelled"
                case .heartbeatRejected(let reason) where reason == "FENCED" || reason.contains("FENCED"):
                    releaseReason = "user_cancelled"
                default:
                    releaseReason = "download_error"
                }
            } else if failure is NASEngineExecutionError {
                releaseReason = "decode_unsupported"
            } else {
                releaseReason = "resource_exhaustion"
            }

            // A NAS-side cancelled receipt (job cancelled/paused on the NAS) is not a Mac failure.
            var cancelledByNAS = false
            if let transportErr = failure as? NASHelperTransportError,
               case .serverReceiptRejected(let status, _, _) = transportErr,
               status == NASWireReceiptStatus.cancelled.rawValue {
                cancelledByNAS = true
            }

            engineBridge.cancel(ref: handle.engineRef)

            let releaseReq = NASWireInboxRequest.makeRelease(
                rootID: offer.root_id,
                rootGeneration: offer.root_generation,
                clientID: offer.assigned_client_id,
                jobID: offer.job_id,
                itemID: offer.item_id,
                coordinatorEpoch: offer.coordinator_epoch,
                attemptID: offer.attempt_id,
                fencingToken: offer.fencing_token,
                reason: releaseReason
            )
            try? await transport.submitInboxRequest(root: root, request: releaseReq)
            try? FileManager.default.removeItem(at: workspaceURL)

            let failureText = failure.localizedDescription
            await MainActor.run {
                if cancelledByNAS {
                    self.noteAttemptCancelledByNAS(handle)
                } else {
                    self.noteAttemptFailed(handle, releaseReason: releaseReason, message: failureText)
                }
            }
        }
    }

    /// Validates the offer expiration once on acceptance, sends heartbeat seq=1 and then waits for the first valid
    /// HeartbeatAck against an independent local monotonic deadline of 120s. The initial offer deadline never
    /// truncates this wait (the NAS lease is already renewed by the first heartbeat). Further heartbeats (strictly
    /// increasing seq) are sent every 10s while waiting so the NAS keeps seeing a live client. Returns the
    /// seq/lease state for the periodic loop.
    /// A remote `rejected` ACK fails immediately; running out of local time throws `heartbeatAckTimeout`.
    nonisolated private static func performFirstHeartbeatHandshake(
        transport: NASHelperTransport,
        root: NASPinnedRoot,
        offer: NASWireOffer,
        immutableControl: Bool,
        heartbeatGate: NASHeartbeatWriteGate
    ) async throws -> NASHeartbeatLeaseState {
        let clock = ContinuousClock()
        let startedAt = clock.now

        // Fail closed: an unparsable/non-finite offer expiration never falls back to the default wait.
        guard let expiresAt = NASHelperWire.parseISO8601Date(offer.offer_expires_at) else {
            throw NASHelperTransportError.responseSchemaMismatch("offer_expires_at 형식이 올바르지 않습니다.")
        }
        let remaining = expiresAt.timeIntervalSinceNow - Double(NASHeartbeatLeaseState.offerSafetySeconds)
        guard remaining.isFinite else {
            throw NASHelperTransportError.responseSchemaMismatch("offer_expires_at 값이 유효하지 않습니다.")
        }
        guard remaining > 0 else {
            throw NASHelperTransportError.offerExpired(offer.offer_expires_at)
        }
        // Offer expiration was validated above (acceptance time only); the ACK wait budget is independent of it.
        let budgetSeconds = Double(NASHeartbeatLeaseState.handshakeMaxSeconds)
        let deadline = startedAt + .seconds(budgetSeconds)
        let interval = Duration.seconds(NASHeartbeatLeaseState.heartbeatIntervalSeconds)

        // The handshake owns the plain value; polling goes through a box so it shares the exact ACK logic of the watcher.
        let box = NASHeartbeatLeaseBox(NASHeartbeatLeaseState())

        // seq=1 must be written successfully; failure propagates as before. The single writer slot is taken BEFORE the seq is
        // reserved, so a seq and its send anchor always belong to a write that really starts.
        // First write only: up to 30s, but never beyond the CURRENT offer remainder (minus the offer safety) nor the remaining
        // handshake budget. Computed here, right before the write starts (no await since the validation above). Fail closed.
        let currentOfferRemaining = expiresAt.timeIntervalSinceNow - Double(NASHeartbeatLeaseState.offerSafetySeconds)
        let firstWriteTimeout = min(
            NASHelperTransport.firstHeartbeatWriteMaxTimeout,
            currentOfferRemaining,
            (deadline - clock.now) / .seconds(1)
        )
        guard firstWriteTimeout.isFinite, firstWriteTimeout > 0 else {
            throw NASHelperTransportError.offerExpired(offer.offer_expires_at)
        }
        guard let firstSlot = heartbeatGate.tryBegin() else {
            throw NASIOFailureDiagnostic.tagged(
                .firstHeartbeatWrite, NASHelperTransportError.ioError("Heartbeat 쓰기 정체 (errno \(EBUSY))")
            )
        }
        let firstSeq = box.withState { $0.reserveSeq(at: clock.now) }
        do {
            try await transport.writeHeartbeat(
                root: root,
                offer: offer,
                heartbeat: NASWireHeartbeat.make(offer: offer, seq: firstSeq, stage: .downloading, stagePercent: 0.0),
                slot: firstSlot,
                firstWriteTimeout: firstWriteTimeout
            )
        } catch {
            // Keep the fixed phase + errno of the real cause (never its path/message) so the failure is not a generic I/O error.
            throw NASIOFailureDiagnostic.tagged(.firstHeartbeatWrite, error)
        }

        while true {
            try Task.checkCancellation()

            do {
                let outcome = try await pollAcks(
                    transport: transport, root: root, offer: offer, leaseBox: box, immutableControl: immutableControl
                )
                switch outcome {
                case .renewed:
                    // The send-anchored lease (send + 105s) must still be in the future before any download starts.
                    // An already expired ACK is rejected (no download); a later heartbeat's ACK may still arrive in time.
                    if !box.withState({ $0.leaseHasExpired(at: clock.now) }) {
                        return box.withState { $0 }
                    }
                case .rejected(let reason):
                    throw NASHelperTransportError.heartbeatRejected(reason: reason)
                default:
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NASHelperTransportError {
                if case .heartbeatRejected = error { throw error }
                let tagged = NASIOFailureDiagnostic.tagged(.heartbeatAckRead, error)
                box.withState {
                    $0.noteWriteFailure()
                    $0.noteIOFailure(tagged)
                }
            } catch {
                let tagged = NASIOFailureDiagnostic.tagged(.heartbeatAckRead, error)
                box.withState {
                    $0.noteWriteFailure()
                    $0.noteIOFailure(tagged)
                }
            }

            var now = clock.now
            if now >= deadline {
                let elapsed = Int((now - startedAt) / .seconds(1))
                throw NASHelperTransportError.heartbeatAckTimeout(
                    box.withState { $0.handshakeDiagnostic(elapsedSeconds: elapsed, budgetSeconds: Int(budgetSeconds)) }
                )
            }

            // While an earlier write's worker has not really returned the slot is taken: nothing is written and no seq is reserved.
            if let lastSend = box.withState({ $0.lastSendAt }), now - lastSend >= interval, let slot = heartbeatGate.tryBegin() {
                let seq = box.withState { $0.reserveSeq(at: now) }
                do {
                    try await transport.writeHeartbeat(
                        root: root,
                        offer: offer,
                        heartbeat: NASWireHeartbeat.make(offer: offer, seq: seq, stage: .downloading, stagePercent: 0.0),
                        slot: slot
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The seq stays consumed (never reused); keep waiting within the local deadline.
                    let tagged = NASIOFailureDiagnostic.tagged(.heartbeatWrite, error)
                    box.withState {
                        $0.noteWriteFailure()
                        $0.noteIOFailure(tagged)
                    }
                }
                now = clock.now
                if now >= deadline { continue }
            }

            try await Task.sleep(for: min(.seconds(1), deadline - now))
        }
    }

    /// One ACK poll shared by the handshake and the watcher. Immutable control reads ONLY the per-seq ACK files (newest few
    /// not yet acknowledged, scanned newest first and cut at the first decisive ACK); the legacy path reads the single mutable heartbeat_ack.json. Every identity-validated ACK goes
    /// through the same `observe` rules. The strongest outcome wins: rejected, then renewed, then the first other outcome.
    nonisolated private static func pollAcks(
        transport: NASHelperTransport,
        root: NASPinnedRoot,
        offer: NASWireOffer,
        leaseBox: NASHeartbeatLeaseBox,
        immutableControl: Bool
    ) async throws -> NASHeartbeatLeaseState.AckOutcome? {
        if immutableControl {
            let (after, highest) = leaseBox.withState { ($0.lastAckSeq, $0.highestSentSeq) }
            let acks = try await transport.readImmutableHeartbeatAcks(
                root: root, offer: offer, afterSeq: after, highestSentSeq: highest
            )
            return leaseBox.withState { state in
                guard !acks.isEmpty else {
                    state.noteEmptyRead()
                    return nil
                }
                var best: NASHeartbeatLeaseState.AckOutcome?
                for ack in acks.sorted(by: { $0.ack_seq < $1.ack_seq }) {
                    let outcome = state.observe(ack)
                    if case .rejected = outcome { return outcome }
                    if outcome == .renewed || best == nil { best = outcome }
                }
                return best
            }
        }
        let ack = try await transport.readHeartbeatAck(root: root, offer: offer)
        return leaseBox.withState { state in
            guard let ack else {
                state.noteEmptyRead()
                return nil
            }
            return state.observe(ack)
        }
    }

    // MARK: - Thumbnail Generation Foundation

    /// Generates JPEG thumbnail content data using existing AVFoundation logic in `VaultProcessor`.
    /// The Mac helper never generates or publishes final vault keys (`v1-*.jpg`) or modifies `.NasFinder-Vault`.
    nonisolated func generateThumbnailData(for convertedVideoURL: URL) async throws -> Data {
        try await VaultProcessor.videoThumbnailData(for: convertedVideoURL)
    }

    // MARK: - Safe Path Filtering

    func isEligibleConversionCandidate(_ url: URL) -> Bool {
        guard !NASHelperFolder.containsExcludedOriginalPathSegment(url) else {
            return false
        }
        guard let kind = SupportedMedia.kind(for: url), kind == .video else {
            return false
        }
        return true
    }
}
