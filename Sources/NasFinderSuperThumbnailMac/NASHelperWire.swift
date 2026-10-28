import Foundation

/// Definitive wire protocol models and validators for cooperative NAS-Mac video transcoding handoff (v1).
/// Matches the JSON Schema defined in https://nasfinder.handbrake.cooperation/v1/protocol-schema.json.
/// Strictly enforces `additionalProperties: false` and fail-closed validation on all message variants.
enum NASHelperWire {
    static let protocolName = "nas-handbrake-cooperation"
    static let schemaVersion = 1
    static let policyVersion = "nas-v1-h264-aac-crf18"
    static let handoffDirectoryName = ".NasFinder-Handoff"
    /// Display name sent at join so several Macs are told apart in the NAS client list (max 64 code points,
    /// control characters removed). Identity itself is only the per-start client UUID, never this name.
    static var defaultClientName: String {
        let raw = Host.current().localizedName ?? ""
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .control }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Mac Helper" }
        return String(String.UnicodeScalarView(cleaned.unicodeScalars.prefix(64)))
    }
    static let versionDirectoryName = "v1"
    /// Client release shown to the NAS in join_batch / result.json (informational only; identity is the client UUID).
    static let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    /// `slots_offered` / `available_slots` range of the frozen schema (1...4 since NAS backend 0.4.1).
    static let maxSlotsPerRoot = 4
    /// Expanded slot limit negotiated with backends advertising `pipeline_slots_12` (backend 0.5.0-r2+).
    static let maxPipelineSlotsPerRoot = 12
    /// Feature id of the immutable control files (`immutable_control_1`): per-seq ACK, per-revision receipt, per-request
    /// join/work/status responses. NAS backends from `immutableControlMinimumServerVersion` publish it.
    static let immutableControlFeature = "immutable_control_1"
    static let immutableControlMinimumServerVersion = [0, 4, 1]
    /// Feature id for cooperative video claim (`video_claim_1`).
    /// Server advertises it only after acquiring the common claim before offering work.
    static let videoClaimFeature = "video_claim_1"
    /// Feature id for expanded pipeline slots (`pipeline_slots_12`).
    static let pipelineSlotsFeature = "pipeline_slots_12"

    /// True when a root descriptor's `server_version` (for example "0.4.1-r1") is at least `minimum` (numeric
    /// dotted prefix only; anything unparsable counts as older).
    static func serverVersion(_ version: String, isAtLeast minimum: [Int]) -> Bool {
        var parts: [Int] = []
        for piece in version.split(separator: ".", omittingEmptySubsequences: false).prefix(3) {
            let digits = piece.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parts.append(value)
            if digits.count != piece.count { break }
        }
        while parts.count < minimum.count { parts.append(0) }
        for (have, need) in zip(parts, minimum) where have != need {
            return have > need
        }
        return true
    }

    static var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static var fallbackIso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseISO8601Date(_ string: String) -> Date? {
        iso8601Formatter.date(from: string) ?? fallbackIso8601Formatter.date(from: string)
    }

    static func formatISO8601Date(_ date: Date = Date()) -> String {
        iso8601Formatter.string(from: date)
    }
}

// MARK: - Validation Errors

enum NASWireValidationError: LocalizedError, Equatable {
    case invalidProtocol(String)
    case invalidSchemaVersion(Int)
    case invalidUUID(String)
    case invalidSha256(String)
    case invalidFencingToken(String)
    case invalidPathComponent(String)
    case invalidRelativePath(String)
    case unknownProperties(Set<String>)
    case missingRequiredProperty(String)
    case policyMismatch(String)
    case offerIdentityMismatch(String)
    case receiptIdentityMismatch(String)
    case responseMismatch(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidProtocol(let p):
            return "유효하지 않은 프로토콜입니다: \(p)"
        case .invalidSchemaVersion(let v):
            return "지원되지 않는 스키마 버전입니다: \(v)"
        case .invalidUUID(let u):
            return "올바르지 않은 UUID 형식입니다: \(u)"
        case .invalidSha256(let s):
            return "올바르지 않은 SHA-256 해시입니다: \(s)"
        case .invalidFencingToken(let t):
            return "올바르지 않은 펜싱 토큰입니다: \(t)"
        case .invalidPathComponent(let c):
            return "안전하지 않은 경로 구성 요소입니다: \(c)"
        case .invalidRelativePath(let p):
            return "안전하지 않은 상대 경로입니다: \(p)"
        case .unknownProperties(let props):
            return "허용되지 않은 추가 필드가 포함되어 있습니다: \(props.joined(separator: ", "))"
        case .missingRequiredProperty(let prop):
            return "필수 필드가 누락되었습니다: \(prop)"
        case .policyMismatch(let p):
            return "엔진 정책이 일치하지 않습니다: \(p)"
        case .offerIdentityMismatch(let m):
            return "Offer 식별 정보가 일치하지 않습니다: \(m)"
        case .receiptIdentityMismatch(let m):
            return "Receipt 식별 정보가 일치하지 않습니다: \(m)"
        case .responseMismatch(let m):
            return "응답 식별자 또는 요청 ID 불일치: \(m)"
        case .invalidJSON(let m):
            return "JSON 구문 분석 오류: \(m)"
        }
    }
}

// MARK: - Safe Path Component and Schema Primitive Validators

enum NASWireValidators {
    private static let uuidRegex = try! NSRegularExpression(pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private static let sha256Regex = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")
    private static let fencingTokenRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{16,64}$")
    private static let pathComponentRegex = try! NSRegularExpression(pattern: "^(?!(?:\\.|\\.\\.)$)[^/\\\\\\x00-\\x1f\\x7f-\\x9f]+$")

    static func validateUUID(_ string: String) throws {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard uuidRegex.firstMatch(in: string, options: [], range: range) != nil else {
            throw NASWireValidationError.invalidUUID(string)
        }
    }

    static func validateSha256(_ string: String) throws {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard sha256Regex.firstMatch(in: string, options: [], range: range) != nil else {
            throw NASWireValidationError.invalidSha256(string)
        }
    }

    static func validateFencingToken(_ string: String) throws {
        let range = NSRange(location: 0, length: string.utf16.count)
        guard fencingTokenRegex.firstMatch(in: string, options: [], range: range) != nil else {
            throw NASWireValidationError.invalidFencingToken(string)
        }
    }

    static func validatePathComponent(_ component: String) throws {
        guard !component.isEmpty, component.utf8.count <= 255 else {
            throw NASWireValidationError.invalidPathComponent(component)
        }
        let range = NSRange(location: 0, length: component.utf16.count)
        guard pathComponentRegex.firstMatch(in: component, options: [], range: range) != nil else {
            throw NASWireValidationError.invalidPathComponent(component)
        }
    }

    static func validatePathComponents(_ components: [String]) throws {
        guard !components.isEmpty, components.count <= 64 else {
            throw NASWireValidationError.invalidRelativePath("구성요소 개수 초과: \(components.count)")
        }
        var totalBytes = 0
        for comp in components {
            try validatePathComponent(comp)
            totalBytes += comp.utf8.count + 1
        }
        guard totalBytes <= 4096 else {
            throw NASWireValidationError.invalidRelativePath("총 경로 바이트 길이 초과: \(totalBytes)")
        }
    }

    /// Enforces `additionalProperties: false` by checking dictionary keys against allowed property set.
    static func assertNoUnknownKeys(in dictionary: [String: Any], allowedKeys: Set<String>) throws {
        let keys = Set(dictionary.keys)
        let unknown = keys.subtracting(allowedKeys)
        if !unknown.isEmpty {
            throw NASWireValidationError.unknownProperties(unknown)
        }
    }
}

// MARK: - Wire Enums

enum NASWireStage: String, Codable, Sendable, CaseIterable {
    case downloading
    case encoding
    case thumbnail
    case uploading
    case waitingValidation = "waiting_validation"

    var displayName: String {
        switch self {
        case .downloading: return "다운로드"
        case .encoding: return "변환"
        case .thumbnail: return "썸네일"
        case .uploading: return "업로드"
        case .waitingValidation: return "NAS 검증 대기"
        }
    }
}

enum NASWireReceiptStatus: String, Codable, Sendable {
    case accepted
    case validating
    case committed
    case rejected
    case retryOnNas = "retry_on_nas"
    case cancelled
    case manualAttention = "manual_attention"

    var isCommitted: Bool {
        self == .committed
    }
}

// MARK: - RootDescriptor

struct NASWireRootDescriptor: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_id", "coordinator_epoch", "active_job_id",
        "active_jobs", "supported_policy_versions", "server_version",
        "max_concurrent_clients", "published_at"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_id: String
    let coordinator_epoch: Int
    let active_job_id: String?
    let active_jobs: [String]
    let supported_policy_versions: [String]
    let server_version: String
    let max_concurrent_clients: Int
    let published_at: String

    func validate() throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        try NASWireValidators.validateUUID(root_id)
        try NASWireValidators.validateUUID(coordinator_id)
        if let active_job_id {
            try NASWireValidators.validateUUID(active_job_id)
        }
        for jobID in active_jobs {
            try NASWireValidators.validateUUID(jobID)
        }
        guard root_generation >= 1, coordinator_epoch >= 1 else {
            throw NASWireValidationError.invalidSchemaVersion(0)
        }
        guard supported_policy_versions.contains(NASHelperWire.policyVersion) else {
            throw NASWireValidationError.policyMismatch("미지원 정책 목록: \(supported_policy_versions)")
        }
    }
}

// MARK: - InboxRequest

struct NASWireInboxRequest: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "request_id", "root_id",
        "root_generation", "client_id", "action", "created_at",
        "join_payload", "request_work_payload", "leave_payload", "release_payload", "status_payload"
    ]

    let `protocol`: String
    let schema_version: Int
    let request_id: String
    let root_id: String
    let root_generation: Int
    let client_id: String
    let action: String
    let created_at: String

    let join_payload: JoinPayload?
    let request_work_payload: RequestWorkPayload?
    let leave_payload: LeavePayload?
    let release_payload: ReleasePayload?
    /// `status_request` (immutable control only): asks the NAS for a fresh, uniquely named job status answer.
    let status_payload: StatusPayload?

    struct StatusPayload: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = ["job_id"]
        let job_id: String
    }

    struct JoinPayload: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "client_name", "client_version", "supported_policy_version",
            "slots_offered", "target_job_id"
        ]
        let client_name: String
        let client_version: String
        let supported_policy_version: String
        let slots_offered: Int
        let target_job_id: String?
    }

    struct RequestWorkPayload: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "job_id", "engine_policy_version", "available_slots"
        ]
        let job_id: String
        let engine_policy_version: String
        let available_slots: Int
    }

    struct LeavePayload: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = ["job_id", "reason"]
        let job_id: String?
        let reason: String
    }

    struct ReleasePayload: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "job_id", "item_id", "coordinator_epoch", "attempt_id",
            "fencing_token", "engine_policy_version", "reason"
        ]
        let job_id: String
        let item_id: String
        let coordinator_epoch: Int
        let attempt_id: String
        let fencing_token: String
        let engine_policy_version: String
        let reason: String
    }

    static func makeJoin(
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        clientName: String = NASHelperWire.defaultClientName,
        clientVersion: String = NASHelperWire.clientVersion,
        slots: Int = 1,
        targetJobID: String? = nil
    ) -> NASWireInboxRequest {
        NASWireInboxRequest(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            request_id: UUID().uuidString.lowercased(),
            root_id: rootID,
            root_generation: rootGeneration,
            client_id: clientID,
            action: "join_batch",
            created_at: NASHelperWire.formatISO8601Date(),
            join_payload: JoinPayload(
                client_name: clientName,
                client_version: clientVersion,
                supported_policy_version: NASHelperWire.policyVersion,
                slots_offered: max(1, min(NASHelperWire.maxPipelineSlotsPerRoot, slots)),
                target_job_id: targetJobID
            ),
            request_work_payload: nil,
            leave_payload: nil,
            release_payload: nil,
            status_payload: nil
        )
    }

    static func makeRequestWork(
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        jobID: String,
        availableSlots: Int = 1
    ) -> NASWireInboxRequest {
        NASWireInboxRequest(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            request_id: UUID().uuidString.lowercased(),
            root_id: rootID,
            root_generation: rootGeneration,
            client_id: clientID,
            action: "request_work",
            created_at: NASHelperWire.formatISO8601Date(),
            join_payload: nil,
            request_work_payload: RequestWorkPayload(
                job_id: jobID,
                engine_policy_version: NASHelperWire.policyVersion,
                available_slots: max(1, min(NASHelperWire.maxPipelineSlotsPerRoot, availableSlots))
            ),
            leave_payload: nil,
            release_payload: nil,
            status_payload: nil
        )
    }

    static func makeLeave(
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        jobID: String? = nil,
        reason: String
    ) -> NASWireInboxRequest {
        NASWireInboxRequest(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            request_id: UUID().uuidString.lowercased(),
            root_id: rootID,
            root_generation: rootGeneration,
            client_id: clientID,
            action: "leave_batch",
            created_at: NASHelperWire.formatISO8601Date(),
            join_payload: nil,
            request_work_payload: nil,
            leave_payload: LeavePayload(job_id: jobID, reason: String(reason.prefix(256))),
            release_payload: nil,
            status_payload: nil
        )
    }

    /// Immutable-control job status request. Only sent after the NAS confirmed `immutable_control_1`.
    static func makeStatusRequest(rootID: String, rootGeneration: Int, clientID: String, jobID: String) -> NASWireInboxRequest {
        NASWireInboxRequest(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            request_id: UUID().uuidString.lowercased(),
            root_id: rootID,
            root_generation: rootGeneration,
            client_id: clientID,
            action: "status_request",
            created_at: NASHelperWire.formatISO8601Date(),
            join_payload: nil,
            request_work_payload: nil,
            leave_payload: nil,
            release_payload: nil,
            status_payload: StatusPayload(job_id: jobID)
        )
    }

    static func makeRelease(
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        jobID: String,
        itemID: String,
        coordinatorEpoch: Int,
        attemptID: String,
        fencingToken: String,
        reason: String
    ) -> NASWireInboxRequest {
        NASWireInboxRequest(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            request_id: UUID().uuidString.lowercased(),
            root_id: rootID,
            root_generation: rootGeneration,
            client_id: clientID,
            action: "release_attempt",
            created_at: NASHelperWire.formatISO8601Date(),
            join_payload: nil,
            request_work_payload: nil,
            leave_payload: nil,
            release_payload: ReleasePayload(
                job_id: jobID,
                item_id: itemID,
                coordinator_epoch: coordinatorEpoch,
                attempt_id: attemptID,
                fencing_token: fencingToken,
                engine_policy_version: NASHelperWire.policyVersion,
                reason: reason
            ),
            status_payload: nil
        )
    }
}

// MARK: - JoinResponse

struct NASWireJoinResponse: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "request_id", "client_id", "status", "reason_code",
        "assigned_slots", "active_job_id", "responded_at"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let request_id: String
    let client_id: String
    let status: String
    let reason_code: String
    let assigned_slots: Int
    let active_job_id: String?
    let responded_at: String

    func validate(expectedRequestID: String, expectedClientID: String) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard request_id == expectedRequestID else {
            throw NASWireValidationError.responseMismatch("request_id 불일치: 기대값 \(expectedRequestID) != 수신값 \(request_id)")
        }
        guard client_id == expectedClientID else {
            throw NASWireValidationError.responseMismatch("client_id 불일치: 기대값 \(expectedClientID) != 수신값 \(client_id)")
        }
        try NASWireValidators.validateUUID(root_id)
        if let active_job_id {
            try NASWireValidators.validateUUID(active_job_id)
        }
    }
}

// MARK: - Immutable JoinResponse (`clients/<client>/join_response-<request_id>.json`)

/// The legacy JoinResponse plus the authenticated coordinator identity and feature list. Created once by the NAS under a
/// name that contains the request id, so a cached older answer can never be mistaken for it.
struct NASWireJoinResponseIC: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = NASWireJoinResponse.allowedKeys.union(["coordinator_id", "coordinator_epoch", "features"])

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let request_id: String
    let client_id: String
    let status: String
    let reason_code: String
    let assigned_slots: Int
    let active_job_id: String?
    let responded_at: String
    let coordinator_id: String
    let coordinator_epoch: Int
    let features: [String]

    func validate(expectedRequestID: String, expectedClientID: String) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard request_id == expectedRequestID else {
            throw NASWireValidationError.responseMismatch("request_id 불일치")
        }
        guard client_id == expectedClientID else {
            throw NASWireValidationError.responseMismatch("client_id 불일치")
        }
        try NASWireValidators.validateUUID(root_id)
        try NASWireValidators.validateUUID(coordinator_id)
        if let active_job_id {
            try NASWireValidators.validateUUID(active_job_id)
        }
        let maxSlots = features.contains(NASHelperWire.pipelineSlotsFeature)
            ? NASHelperWire.maxPipelineSlotsPerRoot
            : NASHelperWire.maxSlotsPerRoot
        guard coordinator_epoch >= 1, root_generation >= 1, (0...maxSlots).contains(assigned_slots) else {
            throw NASWireValidationError.invalidSchemaVersion(0)
        }
    }

    var supportsImmutableControl: Bool {
        features.contains(NASHelperWire.immutableControlFeature)
    }

    var supportsPipelineSlots: Bool {
        features.contains(NASHelperWire.pipelineSlotsFeature)
    }

    /// The legacy-shaped view used by the shared acceptance checks.
    var legacyView: NASWireJoinResponse {
        NASWireJoinResponse(
            protocol: `protocol`, schema_version: schema_version, root_id: root_id, root_generation: root_generation,
            request_id: request_id, client_id: client_id, status: status, reason_code: reason_code,
            assigned_slots: assigned_slots, active_job_id: active_job_id, responded_at: responded_at
        )
    }
}

// MARK: - WorkResponse

struct NASWireWorkResponse: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "request_id", "client_id", "job_id", "status",
        "reason_code", "attempt_id", "offer_relative_path",
        "retry_after_seconds", "responded_at"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let request_id: String
    let client_id: String
    let job_id: String
    let status: String
    let reason_code: String
    let attempt_id: String?
    let offer_relative_path: String?
    let retry_after_seconds: Int
    let responded_at: String

    func validate(expectedRequestID: String, expectedClientID: String) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard request_id == expectedRequestID else {
            throw NASWireValidationError.responseMismatch("request_id 불일치: \(expectedRequestID) != \(request_id)")
        }
        guard client_id == expectedClientID else {
            throw NASWireValidationError.responseMismatch("client_id 불일치: \(expectedClientID) != \(client_id)")
        }
        try NASWireValidators.validateUUID(root_id)
        try NASWireValidators.validateUUID(job_id)
        if let attempt_id {
            try NASWireValidators.validateUUID(attempt_id)
        }
    }
}

// MARK: - Offer

struct NASWireOffer: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "item_id", "attempt_id",
        "fencing_token", "assigned_client_id", "source_path_components",
        "source_size_bytes", "source_sha256", "source_duration_seconds",
        "engine_policy_version", "lease_duration_seconds",
        "heartbeat_interval_seconds", "offered_at", "offer_expires_at",
        "lease_expires_at_hint"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let item_id: String
    let attempt_id: String
    let fencing_token: String
    let assigned_client_id: String
    let source_path_components: [String]
    let source_size_bytes: Int64
    let source_sha256: String
    let source_duration_seconds: Double
    let engine_policy_version: String
    let lease_duration_seconds: Int
    let heartbeat_interval_seconds: Int
    let offered_at: String
    let offer_expires_at: String
    let lease_expires_at_hint: String

    func validate(expectedClientID: String) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard assigned_client_id == expectedClientID else {
            throw NASWireValidationError.offerIdentityMismatch("할당 클라이언트 불일치: 기대 \(expectedClientID) != 배정 \(assigned_client_id)")
        }
        guard engine_policy_version == NASHelperWire.policyVersion else {
            throw NASWireValidationError.policyMismatch(engine_policy_version)
        }
        try NASWireValidators.validateUUID(root_id)
        try NASWireValidators.validateUUID(job_id)
        try NASWireValidators.validateUUID(item_id)
        try NASWireValidators.validateUUID(attempt_id)
        try NASWireValidators.validateUUID(assigned_client_id)
        try NASWireValidators.validateFencingToken(fencing_token)
        try NASWireValidators.validateSha256(source_sha256)
        try NASWireValidators.validatePathComponents(source_path_components)
        guard source_size_bytes >= 1 else {
            throw NASWireValidationError.invalidRelativePath("유효하지 않은 원본 크기: \(source_size_bytes)")
        }
        guard lease_duration_seconds == 120 else {
            throw NASWireValidationError.offerIdentityMismatch("lease_duration은 120이어야 함")
        }
        guard heartbeat_interval_seconds == 10 else {
            throw NASWireValidationError.offerIdentityMismatch("heartbeat_interval은 10이어야 함")
        }
    }

    /// Canonical attempt directory relative to .NasFinder-Handoff/v1
    /// e.g. attempts/<epoch>/<job>/<item>/<attempt>/<client>
    var attemptDirectoryRelativePath: String {
        "attempts/\(coordinator_epoch)/\(job_id)/\(item_id)/\(attempt_id)/\(assigned_client_id)"
    }
}

// MARK: - Heartbeat

struct NASWireHeartbeat: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "item_id", "attempt_id",
        "fencing_token", "client_id", "engine_policy_version",
        "seq", "stage", "stage_percent", "completed_bytes",
        "total_bytes", "client_timestamp", "release_requested", "release_reason"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let item_id: String
    let attempt_id: String
    let fencing_token: String
    let client_id: String
    let engine_policy_version: String
    let seq: Int
    let stage: NASWireStage
    let stage_percent: Double?
    let completed_bytes: Int64?
    let total_bytes: Int64?
    let client_timestamp: String
    let release_requested: Bool?
    let release_reason: String?

    /// NAS parse_heartbeat requires the `stage_percent` key to be present (value may be null).
    /// Other optional keys are omitted when nil.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(`protocol`, forKey: .protocol)
        try c.encode(schema_version, forKey: .schema_version)
        try c.encode(root_id, forKey: .root_id)
        try c.encode(root_generation, forKey: .root_generation)
        try c.encode(coordinator_epoch, forKey: .coordinator_epoch)
        try c.encode(job_id, forKey: .job_id)
        try c.encode(item_id, forKey: .item_id)
        try c.encode(attempt_id, forKey: .attempt_id)
        try c.encode(fencing_token, forKey: .fencing_token)
        try c.encode(client_id, forKey: .client_id)
        try c.encode(engine_policy_version, forKey: .engine_policy_version)
        try c.encode(seq, forKey: .seq)
        try c.encode(stage, forKey: .stage)
        try c.encode(stage_percent, forKey: .stage_percent)
        try c.encodeIfPresent(completed_bytes, forKey: .completed_bytes)
        try c.encodeIfPresent(total_bytes, forKey: .total_bytes)
        try c.encode(client_timestamp, forKey: .client_timestamp)
        try c.encodeIfPresent(release_requested, forKey: .release_requested)
        try c.encodeIfPresent(release_reason, forKey: .release_reason)
    }

    static func make(
        offer: NASWireOffer,
        seq: Int,
        stage: NASWireStage,
        stagePercent: Double? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        releaseRequested: Bool = false,
        releaseReason: String? = nil
    ) -> NASWireHeartbeat {
        NASWireHeartbeat(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            root_id: offer.root_id,
            root_generation: offer.root_generation,
            coordinator_epoch: offer.coordinator_epoch,
            job_id: offer.job_id,
            item_id: offer.item_id,
            attempt_id: offer.attempt_id,
            fencing_token: offer.fencing_token,
            client_id: offer.assigned_client_id,
            engine_policy_version: offer.engine_policy_version,
            seq: seq,
            stage: stage,
            stage_percent: stagePercent.map { min(100.0, max(0.0, $0)) },
            completed_bytes: completedBytes,
            total_bytes: totalBytes,
            client_timestamp: NASHelperWire.formatISO8601Date(),
            release_requested: releaseRequested ? true : nil,
            release_reason: releaseReason.map { String($0.prefix(256)) }
        )
    }
}

// MARK: - HeartbeatAck

struct NASWireHeartbeatAck: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "item_id", "attempt_id",
        "fencing_token", "client_id", "engine_policy_version",
        "ack_seq", "status", "reason_code", "lease_expires_at_hint",
        "receipt_revision", "server_timestamp"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let item_id: String
    let attempt_id: String
    let fencing_token: String
    let client_id: String
    let engine_policy_version: String
    let ack_seq: Int
    let status: String
    let reason_code: String
    let lease_expires_at_hint: String
    let receipt_revision: Int
    let server_timestamp: String

    /// The NAS answers a heartbeat it processed after a higher seq with `rejected`/`STALE_SEQ`. That only says the older seq is
    /// superseded by a newer one; it is neither a lease renewal nor a rejection of the attempt. Every other rejection is genuine.
    var isSupersededRejection: Bool { status == "rejected" && reason_code == "STALE_SEQ" }

    /// An ACK that settles the poll on its own: a `received` or a genuine rejection. Anything else (ignored status,
    /// superseded rejection) does not, so a scan continues to older seqs.
    var isDecisive: Bool { status == "received" || (status == "rejected" && !isSupersededRejection) }

    func validate(matching offer: NASWireOffer) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard root_id == offer.root_id,
              root_generation == offer.root_generation,
              coordinator_epoch == offer.coordinator_epoch,
              job_id == offer.job_id,
              item_id == offer.item_id,
              attempt_id == offer.attempt_id,
              fencing_token == offer.fencing_token,
              client_id == offer.assigned_client_id,
              engine_policy_version == offer.engine_policy_version else {
            throw NASWireValidationError.offerIdentityMismatch("HeartbeatAck 식별자 불일치")
        }
    }
}

// MARK: - ClientResult

struct NASWireClientResult: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "item_id", "attempt_id",
        "fencing_token", "client_id", "engine_policy_version",
        "output_size_bytes", "output_sha256", "thumbnail_present",
        "thumbnail_size_bytes", "thumbnail_sha256", "completed_at",
        "processing_report"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let item_id: String
    let attempt_id: String
    let fencing_token: String
    let client_id: String
    let engine_policy_version: String
    let output_size_bytes: Int64
    let output_sha256: String
    let thumbnail_present: Bool
    let thumbnail_size_bytes: Int64?
    let thumbnail_sha256: String?
    let completed_at: String
    let processing_report: ProcessingReport?

    struct ProcessingReport: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "encode_duration_ms", "fps_average", "audio_offset_applied_ms", "client_engine_banner"
        ]
        let encode_duration_ms: Int?
        let fps_average: Double?
        let audio_offset_applied_ms: Double?
        let client_engine_banner: String?
    }

    static func make(
        offer: NASWireOffer,
        outputSizeBytes: Int64,
        outputSha256: String,
        thumbnailPresent: Bool,
        thumbnailSizeBytes: Int64? = nil,
        thumbnailSha256: String? = nil,
        encodeDurationMs: Int? = nil,
        fpsAverage: Double? = nil
    ) -> NASWireClientResult {
        NASWireClientResult(
            protocol: NASHelperWire.protocolName,
            schema_version: NASHelperWire.schemaVersion,
            root_id: offer.root_id,
            root_generation: offer.root_generation,
            coordinator_epoch: offer.coordinator_epoch,
            job_id: offer.job_id,
            item_id: offer.item_id,
            attempt_id: offer.attempt_id,
            fencing_token: offer.fencing_token,
            client_id: offer.assigned_client_id,
            engine_policy_version: offer.engine_policy_version,
            output_size_bytes: outputSizeBytes,
            output_sha256: outputSha256,
            thumbnail_present: thumbnailPresent,
            thumbnail_size_bytes: thumbnailSizeBytes,
            thumbnail_sha256: thumbnailSha256,
            completed_at: NASHelperWire.formatISO8601Date(),
            processing_report: ProcessingReport(
                encode_duration_ms: encodeDurationMs,
                fps_average: fpsAverage,
                audio_offset_applied_ms: nil,
                client_engine_banner: "NasFinder Super Thumbnail Mac \(NASHelperWire.clientVersion) (engine_cli.py)"
            )
        )
    }
}

// MARK: - ServerReceipt

struct NASWireServerReceipt: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "item_id", "attempt_id",
        "fencing_token", "client_id", "engine_policy_version",
        "receipt_revision", "status", "reason_code", "reason_message",
        "final_path_components", "final_size_bytes", "final_mtime_ms",
        "final_sha256", "backup_path_components", "thumbnail_status",
        "thumbnail_filename", "updated_at", "committed_at"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let item_id: String
    let attempt_id: String
    let fencing_token: String
    let client_id: String
    let engine_policy_version: String
    let receipt_revision: Int
    let status: NASWireReceiptStatus
    let reason_code: String
    let reason_message: String
    let final_path_components: [String]?
    let final_size_bytes: Int64?
    let final_mtime_ms: Int64?
    let final_sha256: String?
    let backup_path_components: [String]?
    let thumbnail_status: String
    let thumbnail_filename: String?
    let updated_at: String
    let committed_at: String?

    func validate(matching offer: NASWireOffer) throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        guard root_id == offer.root_id,
              root_generation == offer.root_generation,
              coordinator_epoch == offer.coordinator_epoch,
              job_id == offer.job_id,
              item_id == offer.item_id,
              attempt_id == offer.attempt_id,
              fencing_token == offer.fencing_token,
              client_id == offer.assigned_client_id,
              engine_policy_version == offer.engine_policy_version else {
            throw NASWireValidationError.receiptIdentityMismatch("ServerReceipt 식별자 불일치")
        }
        if let final_path_components {
            try NASWireValidators.validatePathComponents(final_path_components)
        }
        if let backup_path_components {
            try NASWireValidators.validatePathComponents(backup_path_components)
        }
        if let final_sha256 {
            try NASWireValidators.validateSha256(final_sha256)
        }
    }
}

// MARK: - JobStatus

struct NASWireJobStatus: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = [
        "protocol", "schema_version", "root_id", "root_generation",
        "coordinator_epoch", "job_id", "state", "counts",
        "active_items", "updated_at"
    ]

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let state: String
    let counts: Counts
    let active_items: [ActiveItem]
    let updated_at: String

    struct Counts: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "total_items", "queued", "queued_nas", "local_processing",
            "mac_processing", "verifying", "completed", "failed",
            "deferred", "cancelled", "manual_attention"
        ]
        let total_items: Int
        let queued: Int
        let queued_nas: Int
        let local_processing: Int
        let mac_processing: Int
        let verifying: Int
        let completed: Int
        let failed: Int
        let deferred: Int
        let cancelled: Int
        let manual_attention: Int
    }

    struct ActiveItem: Codable, Sendable, Equatable {
        static let allowedKeys: Set<String> = [
            "item_id", "source_path_components", "stage",
            "assigned_client_id", "attempt_id", "stage_percent"
        ]
        let item_id: String
        let source_path_components: [String]
        let stage: NASWireStage
        let assigned_client_id: String
        let attempt_id: String
        let stage_percent: Double?
    }

    func validate() throws {
        guard `protocol` == NASHelperWire.protocolName else {
            throw NASWireValidationError.invalidProtocol(`protocol`)
        }
        guard schema_version == NASHelperWire.schemaVersion else {
            throw NASWireValidationError.invalidSchemaVersion(schema_version)
        }
        try NASWireValidators.validateUUID(root_id)
        try NASWireValidators.validateUUID(job_id)
        for item in active_items {
            try NASWireValidators.validateUUID(item.item_id)
            try NASWireValidators.validateUUID(item.assigned_client_id)
            try NASWireValidators.validateUUID(item.attempt_id)
            try NASWireValidators.validatePathComponents(item.source_path_components)
        }
    }
}

// MARK: - Immutable JobStatus answer (`clients/<client>/status_response-<request_id>.json`)

struct NASWireJobStatusResponse: Codable, Sendable, Equatable {
    static let allowedKeys: Set<String> = NASWireJobStatus.allowedKeys.union(["request_id", "client_id"])

    let `protocol`: String
    let schema_version: Int
    let root_id: String
    let root_generation: Int
    let coordinator_epoch: Int
    let job_id: String
    let state: String
    let counts: NASWireJobStatus.Counts
    let active_items: [NASWireJobStatus.ActiveItem]
    let updated_at: String
    let request_id: String
    let client_id: String

    func validate(expectedRequestID: String, expectedClientID: String) throws {
        guard request_id == expectedRequestID, client_id == expectedClientID else {
            throw NASWireValidationError.responseMismatch("status 응답의 요청/클라이언트 ID 불일치")
        }
        try jobStatus.validate()
    }

    var jobStatus: NASWireJobStatus {
        NASWireJobStatus(
            protocol: `protocol`, schema_version: schema_version, root_id: root_id, root_generation: root_generation,
            coordinator_epoch: coordinator_epoch, job_id: job_id, state: state, counts: counts,
            active_items: active_items, updated_at: updated_at
        )
    }
}

// MARK: - Safe Decoder and Encoder Helpers

enum NASWireCodec {
    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        allowedKeys: Set<String>
    ) throws -> T {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = jsonObject as? [String: Any] else {
            throw NASWireValidationError.invalidJSON("JSON 객체가 아니거나 손상된 데이터입니다.")
        }
        try NASWireValidators.assertNoUnknownKeys(in: dict, allowedKeys: allowedKeys)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
