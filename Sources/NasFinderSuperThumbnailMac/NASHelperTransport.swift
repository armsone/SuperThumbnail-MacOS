import CryptoKit
import Foundation

extension NASWireReceiptStatus {
    /// True for every receipt status after which the NAS publishes no further revision of the attempt.
    var isTerminalReceipt: Bool {
        switch self {
        case .accepted, .validating:
            return false
        case .committed, .rejected, .retryOnNas, .cancelled, .manualAttention:
            return true
        }
    }
}

/// Errors encountered during NAS cooperative transport and I/O.
enum NASHelperTransportError: LocalizedError, Equatable {
    case rootNotRegistered(String)
    case unsafeSymlinkDetected(String)
    case pathOutsideRoot(String)
    case pendingRequestTimeout(String)
    case invalidOfferPath(String)
    /// Offer file answered by the NAS but not (yet) visible: true ENOENT only. Never a path/identity failure.
    case offerNotVisible
    case offerExpired(String)
    case sourceSizeMismatch(expected: Int64, actual: Int64)
    case sourceFileExceedsExpectedSize(expected: Int64)
    case sourceShaMismatch(expected: String, actual: String)
    case uploadVerificationFailed(String)
    case heartbeatRejected(reason: String)
    /// Local-only: no valid first HeartbeatAck was observed within the local monotonic deadline.
    /// This is NOT a remote rejection.
    case heartbeatAckTimeout(NASHeartbeatHandshakeDiagnostic)
    case leaseExpired(String)
    case attemptFenced(String)
    case serverReceiptRejected(status: String, code: String, message: String)
    case destinationAlreadyExists(String)
    case invalidCandidateFilename(String)
    case ioError(String)
    case responseSchemaMismatch(String)
    case responseReadFailed(String)
    case joinDiagnosed(NASJoinDiagnostic)
    /// A real I/O failure of one known operation. Holds only the fixed phase and errno/Cocoa code (no path, name, ID or message).
    case operationFailed(NASIOFailureDiagnostic)

    var errorDescription: String? {
        switch self {
        case .rootNotRegistered:
            return "NAS 앱에서 이 폴더의 협업 작업을 등록해 주세요."
        case .unsafeSymlinkDetected:
            return "심볼릭 링크는 보안상 허용되지 않습니다."
        case .pathOutsideRoot:
            return "경로가 지정된 루트 외부에 있습니다."
        case .pendingRequestTimeout, .responseReadFailed:
            return "NAS 응답을 읽지 못했습니다. 연결을 확인한 뒤 다시 시작해 주세요."
        case .invalidOfferPath:
            return "올바르지 않은 Offer 경로 문법입니다."
        case .offerNotVisible:
            return "NAS가 배정한 Offer 파일이 아직 보이지 않습니다."
        case .offerExpired(let date):
            return "Offer 유효 기간이 만료되었습니다 (\(date))"
        case .sourceSizeMismatch(let expected, let actual):
            return "원본 파일 크기 부족: 기대 \(expected)바이트, 실제 \(actual)바이트"
        case .sourceFileExceedsExpectedSize(let expected):
            return "원본 파일 크기 초과: 기대 \(expected)바이트보다 더 읽힘"
        case .sourceShaMismatch(let expected, let actual):
            return "원본 SHA-256 해시 불일치: 기대 \(expected), 실제 \(actual)"
        case .uploadVerificationFailed(let msg):
            return "업로드 검증 실패: \(msg)"
        case .heartbeatRejected(let reason):
            return "Heartbeat 거부됨 (NAS 상태: \(reason))"
        case .heartbeatAckTimeout(let diagnostic):
            return diagnostic.userMessage
        case .leaseExpired(let msg):
            return "Lease 만료: \(msg)"
        case .attemptFenced(let msg):
            return "작업 펜싱 거부(CAS 충돌): \(msg)"
        case .serverReceiptRejected(let status, let code, let message):
            return "NAS 커밋 거부됨 (\(status)/\(code)): \(message)"
        case .destinationAlreadyExists:
            return "대상 파일이 이미 존재합니다 (기존 파일 보호를 위해 중단)"
        case .invalidCandidateFilename(let name):
            return "허용되지 않은 후보 파일 이름입니다: \(name)"
        case .ioError:
            return "NAS 연결 및 파일 읽기 오류가 발생했습니다."
        case .responseSchemaMismatch:
            return "NAS 응답 형식이 맞지 않습니다. 앱 버전을 확인해 주세요."
        case .joinDiagnosed(let diagnostic):
            return diagnostic.userMessage
        case .operationFailed(let diagnostic):
            return diagnostic.userMessage
        }
    }
}

// MARK: - Work Request / Offer Read Failure Classification

/// How the coordinator must treat a failure raised while waiting for a work response or reading its offer.
enum NASWorkReadDisposition: Equatable, Sendable {
    /// Actual ENOENT / known Cocoa no-such-file: keep the SAME request and re-read within the 120s bound.
    case transientAbsence
    /// NAS offer window already closed: the request legitimately ended.
    case offerExpired
    /// Path validation, identity, fence, schema or symlink failure: block that root immediately, no retry.
    case safetyBlock
    /// Any other actual I/O failure: block that root immediately, no blanket retry.
    case ioBlock
    case cancelled
}

enum NASWorkReadClassifier {
    /// Classifies by error type/code only; messages (which may hold paths, IDs or tokens) are never inspected.
    static func classify(_ error: Error) -> NASWorkReadDisposition {
        if error is CancellationError { return .cancelled }
        if let transport = error as? NASHelperTransportError {
            switch transport {
            case .offerNotVisible:
                return .transientAbsence
            case .offerExpired:
                return .offerExpired
            case .invalidOfferPath, .unsafeSymlinkDetected, .pathOutsideRoot, .responseSchemaMismatch,
                 .rootNotRegistered, .attemptFenced, .leaseExpired:
                return .safetyBlock
            default:
                return .ioBlock
            }
        }
        if error is NASWireValidationError { return .safetyBlock }
        if isNoSuchFile(error as NSError) { return .transientAbsence }
        return .ioBlock
    }

    /// True only for POSIX ENOENT, Cocoa NSFileNoSuchFile / NSFileReadNoSuchFile, or a Cocoa/POSIX error whose
    /// known underlying error is one of those. Other Cocoa read errors (permission, corrupt, unknown) are not absence.
    private static func isNoSuchFile(_ error: NSError, depth: Int = 0) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        guard depth < 3,
              error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain,
              let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isNoSuchFile(underlying, depth: depth + 1)
    }
}

// MARK: - Operation I/O Failure Diagnostic

/// Fixed list of the operations whose I/O failure is reported with its phase. Raw values never hold runtime data.
enum NASIOPhase: String, Equatable, Sendable {
    case rootPin
    case workspacePrepare
    case firstHeartbeatWrite
    case heartbeatWrite
    case heartbeatAckRead
    case sourceOpen
    case sourceCopy
    case uploadOpen
    case uploadWrite
    case uploadFinalize

    var label: String {
        switch self {
        case .rootPin: return "NAS 루트 고정"
        case .workspacePrepare: return "작업공간 준비"
        case .firstHeartbeatWrite: return "첫 Heartbeat 쓰기"
        case .heartbeatWrite: return "Heartbeat 쓰기"
        case .heartbeatAckRead: return "Heartbeat 승인 읽기"
        case .sourceOpen: return "원본 열기"
        case .sourceCopy: return "원본 로컬 복사"
        case .uploadOpen: return "업로드 파일 준비"
        case .uploadWrite: return "업로드 쓰기"
        case .uploadFinalize: return "업로드 마무리"
        }
    }
}

/// Bounded, privacy-safe record of one failed operation: the fixed phase plus the errno (or Cocoa code) only.
/// Never holds paths, names, IDs, tokens or raw NSError/localized strings.
struct NASIOFailureDiagnostic: Equatable, Sendable {
    var phase: NASIOPhase
    var errnoValue: Int32?
    var cocoaCode: Int?

    /// Fixed names of the errno values worth naming; every other value is shown as its number alone.
    private static let errnoNames: [Int32: String] = [
        EPERM: "EPERM", ENOENT: "ENOENT", EIO: "EIO", ENXIO: "ENXIO", EACCES: "EACCES", EBUSY: "EBUSY",
        EEXIST: "EEXIST", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", EMFILE: "EMFILE", EFBIG: "EFBIG",
        ENOSPC: "ENOSPC", EROFS: "EROFS", ENETDOWN: "ENETDOWN", ENETUNREACH: "ENETUNREACH",
        ECONNRESET: "ECONNRESET", ENOTCONN: "ENOTCONN", ETIMEDOUT: "ETIMEDOUT", EHOSTDOWN: "EHOSTDOWN",
        EHOSTUNREACH: "EHOSTUNREACH", ESTALE: "ESTALE", EDQUOT: "EDQUOT", ENOTSUP: "ENOTSUP", ECANCELED: "ECANCELED"
    ]

    /// e.g. "단계 첫 Heartbeat 쓰기, errno 5(EIO)"; "원인 코드 없음" when neither code is known.
    var summary: String {
        var parts = ["단계 \(phase.label)"]
        if let errnoValue {
            if let name = Self.errnoNames[errnoValue] {
                parts.append("errno \(errnoValue)(\(name))")
            } else {
                parts.append("errno \(errnoValue)")
            }
        } else if let cocoaCode {
            parts.append("Cocoa 코드 \(cocoaCode)")
        } else {
            parts.append("원인 코드 없음")
        }
        return parts.joined(separator: ", ")
    }

    var userMessage: String { "NAS 연결 및 파일 입출력 오류가 발생했습니다 [\(summary)]" }

    /// Tags a real I/O failure with its phase. Cancellation and every semantic failure (rejection, fence, lease,
    /// schema, symlink, path, size/hash mismatch, existing destination, ...) pass through unchanged.
    static func tagged(_ phase: NASIOPhase, _ error: Error) -> Error {
        if error is CancellationError || error is NASWireValidationError { return error }
        if let transport = error as? NASHelperTransportError {
            switch transport {
            case .ioError(let text):
                return NASHelperTransportError.operationFailed(
                    NASIOFailureDiagnostic(phase: phase, errnoValue: errnoValue(in: text), cocoaCode: nil)
                )
            default:
                return error
            }
        }
        let nsError = error as NSError
        let (posix, cocoa) = codes(of: nsError)
        guard posix != nil || cocoa != nil || nsError.domain == NSCocoaErrorDomain || nsError.domain == NSPOSIXErrorDomain else {
            return error
        }
        return NASHelperTransportError.operationFailed(NASIOFailureDiagnostic(phase: phase, errnoValue: posix, cocoaCode: cocoa))
    }

    /// Runs a synchronous I/O step and tags a failing step with its phase.
    static func run<T>(_ phase: NASIOPhase, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw tagged(phase, error)
        }
    }

    /// POSIX code of the error or of its (bounded-depth) underlying error; otherwise the Cocoa code of a Cocoa error.
    private static func codes(of error: NSError, depth: Int = 0) -> (Int32?, Int?) {
        if error.domain == NSPOSIXErrorDomain {
            return (Int32(truncatingIfNeeded: error.code), nil)
        }
        if depth < 3, let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let inner = codes(of: underlying, depth: depth + 1)
            if inner.0 != nil { return inner }
        }
        if error.domain == NSCocoaErrorDomain { return (nil, error.code) }
        return (nil, nil)
    }

    /// Digits following "errno " only; the rest of the (possibly path-bearing) text is never read.
    private static func errnoValue(in text: String) -> Int32? {
        guard let range = text.range(of: "errno ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isASCII && $0.isNumber }
        return Int32(digits)
    }
}

// MARK: - Heartbeat Handshake Diagnostic

/// Bounded, privacy-safe record of a local first-HeartbeatAck timeout. Holds only fixed state roles and
/// counters (never IDs, tokens, paths, file contents or NAS-provided strings).
struct NASHeartbeatHandshakeDiagnostic: Equatable, Sendable {
    /// none / empty / stale_seq / unsent_seq / ignored_status
    var lastReadState: String
    var elapsedSeconds: Int
    var budgetSeconds: Int
    var heartbeatsSent: Int
    var writeFailures: Int
    var ackReads: Int
    var emptyReads: Int
    var staleReads: Int
    var unsentReads: Int
    var ignoredStatusReads: Int
    /// Last actual I/O failure of the ACK read / heartbeat write (fixed phase + errno only), when one occurred.
    var lastReadFailure: NASIOFailureDiagnostic? = nil
    var lastWriteFailure: NASIOFailureDiagnostic? = nil

    var userMessage: String {
        var text = "첫 Heartbeat 승인 응답을 로컬 제한 시간 안에 받지 못했습니다 (NAS 거부 아님: "
            + "대기 \(elapsedSeconds)/\(budgetSeconds)초, 전송 \(heartbeatsSent)회, 쓰기 실패 \(writeFailures)회, "
            + "읽기 \(ackReads)회, 빈 응답 \(emptyReads)회, 지난 seq \(staleReads)회, "
            + "미전송 seq \(unsentReads)회, 무시된 상태 \(ignoredStatusReads)회, 마지막 상태 \(lastReadState)"
        if let lastWriteFailure { text += ", 마지막 쓰기 오류 \(lastWriteFailure.summary)" }
        if let lastReadFailure { text += ", 마지막 읽기 오류 \(lastReadFailure.summary)" }
        return text + ")"
    }
}

// MARK: - Join Diagnostic

/// Bounded, privacy-safe record of why a join_batch attempt ended. Holds only status codes, counters,
/// errno and comparison booleans (never IDs, tokens, paths, file contents or raw localized descriptions).
struct NASJoinDiagnostic: Equatable, Sendable {
    /// not_found / empty / malformed_json / missing_request_id / stale_request_id /
    /// matching_response / identity_mismatch / io_errno
    var lastStatus: String
    /// timeout / schema / io / size_change / symlink / path / identity / other
    var cause: String
    var attempts: Int
    var elapsedSeconds: Int
    var errnoValue: Int32?
    var detail: String?
    var expectedGeneration: Int?
    var actualGeneration: Int?
    var rootIDEqual: Bool?
    var clientIDEqual: Bool?
    var generationEqual: Bool?
    /// Fixed (path/ID free) message of the lower error that is preserved ahead of the diagnostic suffix.
    var lowerMessage: String
    /// Source/refresh facts of the last not_found read (only set when the last poll status was not_found).
    var notFound: NASNotFoundDiagnostic? = nil

    var suffix: String {
        var parts = ["join=\(cause)", "last=\(lastStatus)", "n=\(attempts)", "t=\(elapsedSeconds)s"]
        if let errnoValue { parts.append("errno=\(errnoValue)") }
        if let detail { parts.append("detail=\(detail)") }
        if let notFound { parts.append(contentsOf: notFound.suffixParts) }
        if let rootIDEqual { parts.append("root=\(rootIDEqual ? "Y" : "N")") }
        if let clientIDEqual { parts.append("client=\(clientIDEqual ? "Y" : "N")") }
        if let generationEqual {
            var gen = "gen=\(generationEqual ? "Y" : "N")"
            if let expectedGeneration, let actualGeneration { gen += "(\(expectedGeneration)/\(actualGeneration))" }
            parts.append(gen)
        }
        return "[" + parts.joined(separator: " ") + "]"
    }

    var userMessage: String { "\(lowerMessage) \(suffix)" }

    /// Maps a lower error to a stable category using enum cases and errno only.
    static func classify(_ error: Error) -> (cause: String, errnoValue: Int32?, detail: String?, message: String) {
        let fallback = "NAS 응답을 읽지 못했습니다. 연결을 확인한 뒤 다시 시작해 주세요."
        if let transport = error as? NASHelperTransportError {
            switch transport {
            case .ioError(let text):
                let code = errnoValue(in: text)
                if text.contains("줄어들었습니다") {
                    return ("size_change", code, "shrunk", transport.errorDescription ?? fallback)
                }
                return ("io", code, nil, transport.errorDescription ?? fallback)
            case .unsafeSymlinkDetected:
                return ("symlink", nil, nil, transport.errorDescription ?? fallback)
            case .pathOutsideRoot:
                return ("path", nil, nil, transport.errorDescription ?? fallback)
            case .responseSchemaMismatch:
                return ("schema", nil, nil, transport.errorDescription ?? fallback)
            case .joinDiagnosed(let existing):
                return (existing.cause, existing.errnoValue, existing.detail, existing.lowerMessage)
            default:
                return ("other", nil, nil, transport.errorDescription ?? fallback)
            }
        }
        if let validation = error as? NASWireValidationError {
            if case .invalidJSON = validation {
                return ("size_change", nil, "grew_or_oversize", "NAS 응답 파일 크기가 읽는 도중 변경되었거나 허용 범위를 넘었습니다.")
            }
            return ("schema", nil, validationCode(validation), NASHelperTransportError.responseSchemaMismatch("").errorDescription ?? fallback)
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return ("io", Int32(truncatingIfNeeded: nsError.code), nil, fallback)
        }
        return ("other", nil, nil, fallback)
    }

    /// Stable short code for a validation error case (associated values, which may carry IDs, are dropped).
    static func validationCode(_ error: Error) -> String {
        guard let validation = error as? NASWireValidationError else { return "non_validation" }
        switch validation {
        case .invalidProtocol: return "protocol"
        case .invalidSchemaVersion: return "schema_version"
        case .invalidUUID: return "uuid"
        case .invalidSha256: return "sha256"
        case .invalidFencingToken: return "fencing_token"
        case .invalidPathComponent: return "path_component"
        case .invalidRelativePath: return "relative_path"
        case .unknownProperties: return "unknown_keys"
        case .missingRequiredProperty: return "missing_key"
        case .policyMismatch: return "policy"
        case .offerIdentityMismatch: return "offer_identity"
        case .receiptIdentityMismatch: return "receipt_identity"
        case .responseMismatch: return "response_mismatch"
        case .invalidJSON: return "invalid_json"
        }
    }

    private static func errnoValue(in text: String) -> Int32? {
        guard let range = text.range(of: "errno ") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }
}

/// Facts about the single ENOENT-triggered directory refresh of one failing open. No names, paths or IDs.
struct NASRefreshDiagnostic: Equatable, Sendable {
    /// True once the listing loop was entered (gate passed, dup/fdopendir succeeded, rewinddir done).
    var performed: Bool
    var entries: Int
    var budgetReached: Bool
    /// cooldown / cancelled / dup_failed / fdopendir_failed / fstat_failed / eof / readdir_err / cap / budget
    var stop: String
}

/// Where a not_found came from. Created per read result; never stored in shared mutable state.
struct NASNotFoundDiagnostic: Equatable, Sendable {
    /// root / root_open / component_index_N (numeric index only) / response
    var role: String
    /// Nil when no refresh was attempted for this ENOENT (root / root_open).
    var refresh: NASRefreshDiagnostic?

    var suffixParts: [String] {
        var parts = ["src=\(role)"]
        if let refresh {
            parts.append("rf=\(refresh.performed ? "Y" : "N")")
            parts.append("ent=\(refresh.entries)")
            parts.append("bud=\(refresh.budgetReached ? "Y" : "N")")
            parts.append("stop=\(refresh.stop)")
        }
        return parts
    }
}

/// Result of a successful join poll, carrying poll counters for identity diagnostics.
struct NASJoinWaitResult: Sendable {
    let response: NASWireJoinResponse
    let attempts: Int
    let elapsedSeconds: Int
    /// The authenticated immutable answer (coordinator id/epoch/features) when the NAS published one for this request.
    var immutable: NASWireJoinResponseIC? = nil
}

/// Which join answer file a client waits for.
enum NASJoinResponseSource: Sendable {
    /// `clients/<client>/join_response.json` (backend 0.4.0 and older).
    case legacy
    /// `clients/<client>/join_response-<request_id>.json` (immutable_control_1).
    case immutable
}

/// Which work answer file a client waits for.
enum NASWorkResponseSource: Sendable {
    case legacy
    case immutable
}

// MARK: - Safe Path & Symlink Security Validator

enum NASPathSecurity {
    /// OS-level canonical path (realpath). Foundation's resolvingSymlinksInPath() rewrites /private/var to /var,
    /// which is NOT the realpath the engine requires, so the workspace root must come from realpath(3).
    static func realpathURL(of url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else {
            throw NASHelperTransportError.ioError("경로 정규화 실패 (errno \(errno)): \(url.path)")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Absolute path string of a file URL without any Foundation standardization. standardizedFileURL abbreviates
    /// /private/var to /var, so it can never equal a realpath(3) result; the workspace root must be compared with
    /// realpath as-is. Relative, empty, "." and ".." components are rejected rather than normalized away.
    static func exactAbsolutePath(of url: URL) throws -> String {
        let path = url.path
        guard path.hasPrefix("/"), path.count > 1 else {
            throw NASHelperTransportError.pathOutsideRoot(path)
        }
        for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        where component.isEmpty || component == "." || component == ".." || component.utf8.contains(0) {
            throw NASHelperTransportError.pathOutsideRoot(path)
        }
        return path
    }

    /// Creates the per-attempt workspace root (mode 0700, owned by this user) and verifies it is a real directory
    /// whose path is already its own realpath. Never follows or accepts a symlink at the root.
    static func prepareOwnedWorkspaceRoot(at url: URL) throws {
        let path = try exactAbsolutePath(of: url)
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw NASHelperTransportError.ioError("작업공간 생성 실패 (errno \(errno)): \(path)")
        }
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else {
            throw NASHelperTransportError.ioError("작업공간 확인 실패 (errno \(errno)): \(path)")
        }
        if (statBuf.st_mode & S_IFMT) == S_IFLNK {
            throw NASHelperTransportError.unsafeSymlinkDetected(path)
        }
        guard (statBuf.st_mode & S_IFMT) == S_IFDIR, statBuf.st_uid == geteuid() else {
            throw NASHelperTransportError.ioError("작업공간이 현재 사용자 소유 디렉터리가 아닙니다: \(path)")
        }
        if (statBuf.st_mode & 0o7777) != 0o700 {
            guard chmod(path, 0o700) == 0 else {
                throw NASHelperTransportError.ioError("작업공간 권한 설정 실패 (errno \(errno)): \(path)")
            }
        }
        guard try realpathURL(of: url).path == path else {
            throw NASHelperTransportError.unsafeSymlinkDetected(path)
        }
    }

    /// Validates that targetURL is strictly contained within baseURL and that NO component
    /// along the path from baseURL down to targetURL is a symbolic link.
    static func validateNoSymlinks(along targetURL: URL, relativeTo baseURL: URL) throws {
        let canonicalBase = baseURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL

        let basePrefix = canonicalBase.path.hasSuffix("/") ? canonicalBase.path : canonicalBase.path + "/"
        guard canonicalTarget.path.hasPrefix(basePrefix) || canonicalTarget.path == canonicalBase.path else {
            throw NASHelperTransportError.pathOutsideRoot(targetURL.path)
        }

        // Validate each component using lstat
        var checking = targetURL.standardizedFileURL
        let rootPath = baseURL.standardizedFileURL.path
        while checking.path.count >= rootPath.count && checking.path != "/" {
            var statBuf = stat()
            if lstat(checking.path, &statBuf) == 0 {
                if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                    throw NASHelperTransportError.unsafeSymlinkDetected(checking.path)
                }
            }
            if checking.path == rootPath { break }
            checking = checking.deletingLastPathComponent()
        }
    }

    /// Recursively ensures directory exists component-by-component, guarding against symlinks at every step.
    static func ensureSecureDirectoryExists(at dirURL: URL, within rootURL: URL) throws {
        try validateNoSymlinks(along: dirURL, relativeTo: rootURL)

        let fileManager = FileManager.default
        let standardizedDir = dirURL.standardizedFileURL
        let standardizedRoot = rootURL.standardizedFileURL

        var componentsToCreate: [URL] = []
        var curr = standardizedDir
        while curr.path != standardizedRoot.path && curr.path != "/" {
            if !fileManager.fileExists(atPath: curr.path) {
                componentsToCreate.append(curr)
                curr = curr.deletingLastPathComponent()
            } else {
                var statBuf = stat()
                if lstat(curr.path, &statBuf) == 0 {
                    if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                        throw NASHelperTransportError.unsafeSymlinkDetected(curr.path)
                    }
                    if (statBuf.st_mode & S_IFMT) != S_IFDIR {
                        throw NASHelperTransportError.ioError("경로 중간 구성 요소가 디렉토리가 아닙니다: \(curr.path)")
                    }
                }
                break
            }
        }

        for comp in componentsToCreate.reversed() {
            if mkdir(comp.path, 0o755) != 0 {
                let err = errno
                if err != EEXIST {
                    throw NASHelperTransportError.ioError("디렉토리 생성 실패 (errno \(err)): \(comp.path)")
                }
            }
            var statBuf = stat()
            if lstat(comp.path, &statBuf) == 0 && (statBuf.st_mode & S_IFMT) == S_IFLNK {
                throw NASHelperTransportError.unsafeSymlinkDetected(comp.path)
            }
        }
    }
}

// MARK: - Pure Lexical Component Checks

extension NASPathSecurity {
    /// Byte-level check of an absolute path (no URL, standardization or symlink resolution, no filesystem call): leading "/",
    /// no empty, "." or ".." component, no NUL. The valid Unicode bytes (NFC or NFD) are kept exactly as given.
    static func validatedAbsolutePath(_ path: String) throws -> String {
        let bytes = path.utf8
        guard bytes.count > 1, bytes.first == 0x2F else {
            throw NASHelperTransportError.pathOutsideRoot("")
        }
        for component in bytes.dropFirst().split(separator: 0x2F, omittingEmptySubsequences: false) {
            try checkComponentBytes(component)
        }
        return path
    }

    /// Relative path components below a pinned root: non-empty list, each component non-empty, not "." / "..", no "/" and no NUL.
    static func checkedComponents(_ components: [String]) throws -> [String] {
        guard !components.isEmpty else { throw NASHelperTransportError.pathOutsideRoot("") }
        for component in components {
            try checkComponentBytes(component.utf8)
        }
        return components
    }

    /// Splits a "/"-joined relative path (e.g. `offer.attemptDirectoryRelativePath`) into checked components.
    static func checkedComponents(ofRelativePath relative: String) throws -> [String] {
        let parts = relative.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        return try checkedComponents(parts)
    }

    private static func checkComponentBytes<C: Collection>(_ component: C) throws where C.Element == UInt8 {
        guard !component.isEmpty,
              !component.contains(0),
              !component.contains(0x2F),
              !component.elementsEqual([0x2E]),
              !component.elementsEqual([0x2E, 0x2E]) else {
            throw NASHelperTransportError.pathOutsideRoot("")
        }
    }
}

// MARK: - Pinned Root (one descriptor per approved connection)

/// Root identity facts a pin is bound to once the authenticated immutable join answer was verified.
struct NASPinBinding: Equatable, Sendable {
    let rootID: String
    let generation: Int
    let epoch: Int
}

/// Hands a freshly opened pin from a bounded blocking open to its awaiting caller. A pin that arrives after the caller gave up
/// (timeout / cancellation) is closed instead of leaking its descriptor.
final class NASPinTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var pin: NASPinnedRoot?
    private var abandoned = false

    func deliver(_ value: NASPinnedRoot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !abandoned else { return false }
        pin = value
        return true
    }

    func take() -> NASPinnedRoot? {
        lock.lock()
        defer { lock.unlock() }
        let value = pin
        pin = nil
        return value
    }

    func abandon() {
        lock.lock()
        abandoned = true
        let value = pin
        pin = nil
        lock.unlock()
        value?.close()
    }
}

/// The user-approved NAS root, opened ONCE per connection (after its security scope began, before the fresh descriptor read
/// and the join). It owns the root descriptor, the kernel-reported canonical path, the device/inode identity and the connection
/// identity, and every control read, write and bulk transfer of the connection walks down from this descriptor with openat.
///
/// What it guarantees: all access stays confined to the ORIGINAL directory object, even when the root's name is later replaced
/// by another object (a pathname is never resolved again). What it does NOT do: fstat of the pinned descriptor (device/inode) does
/// not detect such a replacement by itself (the old directory descriptor stays valid); it only detects that the descriptor itself
/// changed identity or went stale, which invalidates the pin for the rest of the connection.
final class NASPinnedRoot: @unchecked Sendable {
    /// State shared by a pin and its duplicates: one fault or one binding applies to all of them.
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var invalid = false
        var binding: NASPinBinding?
    }

    let folderID: UUID
    /// Coordinator connection serial the pin was opened for; a pin of an older connection is never reused.
    let connection: Int
    /// Kernel path of the pinned directory at pin time (raw bytes, not normalized). Identity record only: nothing reopens it.
    let canonicalPath: String
    let device: dev_t
    let inode: ino_t

    private let shared: Shared
    private let lock = NSLock()
    private var fd: Int32

    private init(folderID: UUID, connection: Int, canonicalPath: String, device: dev_t, inode: ino_t, shared: Shared, fd: Int32) {
        self.folderID = folderID
        self.connection = connection
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        self.shared = shared
        self.fd = fd
    }

    /// Fixed phase + errno only (no path, name or ID).
    static func fault(_ err: Int32) -> NASHelperTransportError {
        .operationFailed(NASIOFailureDiagnostic(phase: .rootPin, errnoValue: err, cocoaCode: nil))
    }

    /// Opens the root off the caller's executor (bounded; a hung mount never blocks the main actor).
    static func open(url: URL, folderID: UUID, connection: Int) async throws -> NASPinnedRoot {
        let ticket = NASPinTicket()
        do {
            try await NASBoundedIO.run(timeout: 15) { _ in
                let pin = try openBlocking(rootPath: url.path, folderID: folderID, connection: connection)
                if !ticket.deliver(pin) { pin.close() }
            }
        } catch {
            ticket.abandon()
            throw error
        }
        guard let pin = ticket.take() else { throw fault(ECANCELED) }
        return pin
    }

    /// Blocking open (one open + one fstat + one F_GETPATH). A symlink in the approved path is followed exactly once, here.
    static func openBlocking(rootPath: String, folderID: UUID, connection: Int) throws -> NASPinnedRoot {
        let path = try NASPathSecurity.validatedAbsolutePath(rootPath)
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw fault(errno) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw fault(err)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(fd)
            throw fault(ENOTDIR)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let canonical: String
        if fcntl(fd, F_GETPATH, &buffer) == 0 {
            canonical = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        } else {
            canonical = path
        }
        return NASPinnedRoot(
            folderID: folderID, connection: connection, canonicalPath: canonical,
            device: info.st_dev, inode: info.st_ino, shared: Shared(), fd: fd
        )
    }

    var isInvalid: Bool {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.invalid
    }

    /// Marks the pin (and all its duplicates) unusable for the rest of the connection: stale handle, identity change.
    func invalidate() {
        shared.lock.lock()
        shared.invalid = true
        shared.lock.unlock()
        close()
    }

    /// Binds the connection to the verified immutable join facts, once. A second call must carry identical facts.
    func bind(rootID: String, generation: Int, epoch: Int) -> Bool {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        let wanted = NASPinBinding(rootID: rootID, generation: generation, epoch: epoch)
        if let current = shared.binding { return current == wanted }
        shared.binding = wanted
        return true
    }

    /// An offer is only acceptable for the root and generation this pin was bound to, from the same or a later coordinator epoch.
    func requireBinding(rootID: String, generation: Int, epoch: Int) throws {
        shared.lock.lock()
        let current = shared.binding
        shared.lock.unlock()
        guard let current, current.rootID == rootID, current.generation == generation, epoch >= current.epoch else {
            throw NASHelperTransportError.attemptFenced("루트 바인딩 불일치")
        }
    }

    /// Own descriptor of the same directory object for a background task that must outlive this pin (e.g. a release after stop).
    func duplicate() -> NASPinnedRoot? {
        lock.lock()
        defer { lock.unlock() }
        guard !isInvalid, fd >= 0 else { return nil }
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        return NASPinnedRoot(
            folderID: folderID, connection: connection, canonicalPath: canonicalPath,
            device: device, inode: inode, shared: shared, fd: copy
        )
    }

    /// Releases this pin's own descriptor (the close itself runs off the caller's thread). Duplicates and in-flight operations
    /// keep their own descriptors until they finish; no new operation can start on this pin.
    func close() {
        lock.lock()
        let old = fd
        fd = -1
        lock.unlock()
        if old >= 0 {
            DispatchQueue.global(qos: .utility).async { _ = Darwin.close(old) }
        }
    }

    /// Runs `body` with a private duplicate of the root descriptor (so a concurrent close/invalidate can never pull the
    /// descriptor away or let its number be reused under the operation). The duplicate is verified against the recorded
    /// device/inode first and closed when `body` returns. `body` must not close it.
    func withDirectoryFD<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        let source = fd
        let copy = (source >= 0 && !isInvalid) ? dup(source) : -1
        let dupErr = errno
        lock.unlock()
        guard copy >= 0 else {
            throw Self.fault(source < 0 || isInvalid ? EBADF : dupErr)
        }
        defer { Darwin.close(copy) }

        var info = stat()
        guard fstat(copy, &info) == 0 else {
            let err = errno
            if err == ESTALE || err == EBADF || err == ENXIO { invalidate() }
            throw Self.fault(err)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_dev == device, info.st_ino == inode else {
            invalidate()
            throw Self.fault(ESTALE)
        }
        return try body(copy)
    }
}

// MARK: - Descriptor-Relative Helpers

enum NASPinnedFS {
    /// Walks (and, when `create` is set, creates with mode 0755) the directory chain `components` below `rootFD`; every step is
    /// openat(O_DIRECTORY | O_NOFOLLOW). Returns an OWNED descriptor of the last directory (a duplicate of `rootFD` for no components).
    static func openDirectoryChain(
        _ rootFD: Int32,
        _ components: [String],
        create: Bool,
        stopRequested: () -> Bool = { false }
    ) throws -> Int32 {
        var current = dup(rootFD)
        guard current >= 0 else {
            throw NASHelperTransportError.ioError("디렉토리 확인 실패 (errno \(errno))")
        }
        for component in components {
            if stopRequested() {
                Darwin.close(current)
                throw CancellationError()
            }
            let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            var next = openat(current, component, flags)
            if next < 0, create, errno == ENOENT {
                if mkdirat(current, component, 0o755) != 0 && errno != EEXIST {
                    let err = errno
                    Darwin.close(current)
                    throw NASHelperTransportError.ioError("디렉토리 생성 실패 (errno \(err))")
                }
                next = openat(current, component, flags)
            }
            if next < 0 {
                let err = errno
                var info = stat()
                let isLink = fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
                Darwin.close(current)
                if err == ELOOP || isLink { throw NASHelperTransportError.unsafeSymlinkDetected("") }
                throw NASHelperTransportError.ioError("디렉토리 열기 실패 (errno \(err))")
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    /// Opens the regular file `components` below `rootFD` read-only without following links and returns an owned blocking descriptor.
    static func openRegularFile(_ rootFD: Int32, _ components: [String]) throws -> Int32 {
        let dirFD = try openDirectoryChain(rootFD, Array(components.dropLast()), create: false)
        defer { Darwin.close(dirFD) }
        guard let name = components.last else { throw NASHelperTransportError.pathOutsideRoot("") }
        let fd = openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP { throw NASHelperTransportError.unsafeSymlinkDetected("") }
            throw NASHelperTransportError.ioError("파일 열기 실패 (errno \(err))")
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NASHelperTransportError.ioError("파일 상태 확인 실패 (errno \(err))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw NASHelperTransportError.ioError("일반 파일이 아닙니다")
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        return fd
    }

    /// True when any directory entry (a symlink counts as an entry, it is not followed) exists under `name`.
    static func entryExists(_ dirFD: Int32, _ name: String) -> Bool {
        var info = stat()
        return fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
    }
}

// MARK: - Heartbeat Writer Gate (one real write per attempt)

/// Allows at most ONE real heartbeat write per attempt at any time, until its worker has really returned. A caller whose await
/// timed out does not release the slot; only the worker's genuine completion does. There is no queue and no coalescing: while the
/// slot is taken a caller simply gets nil and writes nothing (and reserves no sequence number).
final class NASHeartbeatWriteGate: @unchecked Sendable {
    final class Slot: @unchecked Sendable {
        fileprivate let gate: NASHeartbeatWriteGate
        fileprivate var started = false
        fileprivate var ended = false
        fileprivate var invalidated = false

        fileprivate init(gate: NASHeartbeatWriteGate) {
            self.gate = gate
        }

        /// False once the attempt/connection closed or the slot ended: the worker must then not touch the filesystem.
        var isLive: Bool {
            gate.lock.lock()
            defer { gate.lock.unlock() }
            return !ended && !invalidated
        }

        /// Called by the worker before any filesystem effect. False = it must return at once without effects.
        func tryStartWorker() -> Bool {
            gate.lock.lock()
            defer { gate.lock.unlock() }
            guard !ended, !invalidated else { return false }
            started = true
            return true
        }

        /// The worker really returned (success, failure or bail-out): the only event that frees the slot after it started.
        func workerFinished() {
            gate.lock.lock()
            defer { gate.lock.unlock() }
            endLocked()
        }

        /// The caller failed before the worker ever started (gate full, cancelled early, timed out while still queued).
        /// Atomic with `tryStartWorker`: a worker that started in the meantime keeps the slot until it really returns.
        func endIfNotStarted() {
            gate.lock.lock()
            defer { gate.lock.unlock() }
            guard !started else { return }
            endLocked()
        }

        private func endLocked() {
            guard !ended else { return }
            ended = true
            if gate.current === self {
                gate.current = nil
            }
        }
    }

    fileprivate let lock = NSLock()
    fileprivate var current: Slot?
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// The slot when no write is in flight and the gate is open; otherwise nil (busy or closed).
    func tryBegin() -> Slot? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, current == nil else { return nil }
        let slot = Slot(gate: self)
        current = slot
        return slot
    }

    /// Attempt/connection closed: no new write, and a worker that has not passed its last check stops. A write whose rename
    /// already began cannot be undone.
    func close() {
        lock.lock()
        closed = true
        current?.invalidated = true
        lock.unlock()
    }
}

// MARK: - Bounded Control I/O

/// Counts the blocking filesystem calls issued for control traffic. A call that hangs on a dead mount cannot be interrupted,
/// so at most `capacity` of them may exist at the same time; beyond that new control I/O fails fast instead of piling up threads.
final class NASBoundedIOGate: @unchecked Sendable {
    static let shared = NASBoundedIOGate()
    static let capacity = 8

    private let lock = NSLock()
    private var inFlight = 0

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight < Self.capacity else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        lock.lock()
        inFlight = max(0, inFlight - 1)
        lock.unlock()
    }
}

/// One-shot bridge between a blocking operation on a dispatch queue and an awaiting task: whichever of
/// completion, timeout or cancellation comes first resumes the awaiting task exactly once.
final class NASIOCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            early = result
            lock.unlock()
        }
    }
}

enum NASBoundedIO {
    /// Runs a blocking filesystem operation on a utility queue and returns its result, a timeout error after `timeout`
    /// seconds, or `CancellationError` as soon as the awaiting task is cancelled. The caller (heartbeat reader, lease deadline,
    /// cancel) is therefore never held hostage by a stuck mount; the operation itself keeps its gate slot until it returns.
    static func run<T: Sendable>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable (NASControlReadCancellation) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard NASBoundedIOGate.shared.tryEnter() else {
            throw NASHelperTransportError.ioError("파일 입출력이 정체되어 새 요청을 보류합니다 (errno \(EBUSY))")
        }
        let cancellation = NASControlReadCancellation()
        let completion = NASIOCompletion<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                completion.install(continuation)
                DispatchQueue.global(qos: .utility).async {
                    let result: Result<T, Error>
                    do {
                        result = .success(try operation(cancellation))
                    } catch {
                        result = .failure(error)
                    }
                    NASBoundedIOGate.shared.leave()
                    completion.finish(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    cancellation.cancel()
                    completion.finish(.failure(NASHelperTransportError.ioError("파일 입출력 제한 시간 초과 (errno \(ETIMEDOUT))")))
                }
            }
        } onCancel: {
            cancellation.cancel()
            completion.finish(.failure(CancellationError()))
        }
    }
}

// MARK: - Safe Control Protocol File Reader (WebDAV Negative Cache Workaround)

/// Cooperative cancellation flag shared between an async caller and a blocking descriptor read.
final class NASControlReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Per-directory (dev, inode) cooldown bookkeeping for ENOENT-triggered directory refreshes.
/// Memory is bounded: expired entries are purged on every call and the map never exceeds `capacity`.
private final class NASDirectoryRefreshGate: @unchecked Sendable {
    struct Key: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    static let shared = NASDirectoryRefreshGate()

    private let lock = NSLock()
    private var lastRefresh: [Key: TimeInterval] = [:]
    private let capacity = 64
    private let cooldown: TimeInterval = 2

    /// Returns true (and records `now`) only when this directory has not been refreshed within the cooldown.
    func tryBegin(_ key: Key, now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        lastRefresh = lastRefresh.filter { now - $0.value < cooldown }
        if let last = lastRefresh[key], now - last < cooldown {
            return false
        }
        if lastRefresh.count >= capacity,
           let oldest = lastRefresh.min(by: { $0.value < $1.value })?.key {
            lastRefresh.removeValue(forKey: oldest)
        }
        lastRefresh[key] = now
        return true
    }
}

enum NASControlFileReader {
    private static let refreshMaxEntries = 4096
    private static let refreshBudgetSeconds: TimeInterval = 2

    enum ReadResult {
        case notFound(NASNotFoundDiagnostic)
        case incomplete(Data)
        case ready(Data)
    }

    /// Reads bounded control protocol JSON through a descriptor-relative walk (openat) from the connection's pinned root,
    /// bypassing Finder/WebDAV listing and stat negative-cache false-negatives.
    ///
    /// Rules:
    /// - The target is given as checked path components below the pinned root (pure lexical check: no empty, "." or ".."
    ///   component, no NUL); it never exists as a URL or path string, so no standardization, realpath or stat of a path happens.
    /// - The root is the pin's descriptor (verified against its recorded device/inode); it is never resolved by name again, so
    ///   a replaced root name cannot redirect the read to another object.
    /// - Every component below the root is opened with openat (parents: O_DIRECTORY | O_NOFOLLOW,
    ///   final file: O_NOFOLLOW) and verified with fstat; no path-based existence/lstat gates are used. No parent descriptor is cached.
    /// - fstat must succeed, the file must be regular, and its size must be within 0...maxBytes.
    /// - Exactly the declared size is read, followed by a mandatory 1-byte EOF check;
    ///   short reads, growth, oversize and read errors are rejected.
    /// - Returns .notFound only on true ENOENT from openat().
    /// - Returns .incomplete if the file is empty (in-flight flush).
    /// - On ENOENT from a component openat, the already verified parent directory descriptor (never above
    ///   the pinned root, never recursive) is listed once (best-effort, bounded, cooldown-limited) to refresh
    ///   the WebDAV/SMB negative cache, then the identical openat is retried exactly once. The retried
    ///   openat + fstat + exact-size read + EOF check remain the sole authority.
    /// - ESTALE on an open invalidates the pin for the rest of the connection.
    ///
    /// This function blocks; async callers must use `readControlFileAsync`.
    static func readControlFile(
        root: NASPinnedRoot,
        components rawComponents: [String],
        maxBytes: Int = 64 * 1024,
        cancellation: NASControlReadCancellation? = nil
    ) throws -> ReadResult {
        let components = try NASPathSecurity.checkedComponents(rawComponents)
        return try root.withDirectoryFD { rootFD in
            try readControlFile(rootFD: rootFD, root: root, components: components, maxBytes: maxBytes, cancellation: cancellation)
        }
    }

    private static func readControlFile(
        rootFD: Int32,
        root: NASPinnedRoot,
        components: [String],
        maxBytes: Int,
        cancellation: NASControlReadCancellation?
    ) throws -> ReadResult {
        // `rootFD` belongs to the caller; only descriptors opened below it are closed here.
        var dirFD = rootFD
        var ownsDir = false
        defer { if ownsDir { close(dirFD) } }

        for (index, component) in components.dropLast().enumerated() {
            let opened = try openatRefreshingOnENOENT(
                dirFD, component,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC,
                cancellation: cancellation
            )
            let nextFD = opened.fd
            if nextFD < 0 {
                let err = opened.err
                if err == ENOENT {
                    return .notFound(NASNotFoundDiagnostic(role: "component_index_\(index)", refresh: opened.refresh))
                }
                if err == ESTALE {
                    root.invalidate()
                    throw NASPinnedRoot.fault(ESTALE)
                }
                if err == ELOOP || isSymlink(dirFD, component) {
                    throw NASHelperTransportError.unsafeSymlinkDetected("")
                }
                throw NASHelperTransportError.ioError("디렉토리 열기 실패 (errno \(err))")
            }
            if ownsDir { close(dirFD) }
            dirFD = nextFD
            ownsDir = true
            try requireKind(S_IFDIR, fd: dirFD)
        }

        // Open the final file (O_NONBLOCK so a FIFO cannot hang the open) and verify with fstat.
        guard let fileName = components.last else { throw NASHelperTransportError.pathOutsideRoot("") }
        let openedFile = try openatRefreshingOnENOENT(
            dirFD, fileName,
            flags: O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
            cancellation: cancellation
        )
        let fd = openedFile.fd
        if fd < 0 {
            let err = openedFile.err
            if err == ENOENT {
                return .notFound(NASNotFoundDiagnostic(role: "response", refresh: openedFile.refresh))
            }
            if err == ESTALE {
                root.invalidate()
                throw NASPinnedRoot.fault(ESTALE)
            }
            if err == ELOOP || isSymlink(dirFD, fileName) {
                throw NASHelperTransportError.unsafeSymlinkDetected("")
            }
            throw NASHelperTransportError.ioError("파일 열기 실패 (errno \(err))")
        }
        defer { close(fd) }

        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            let err = errno
            throw NASHelperTransportError.ioError("파일 상태 확인 실패 (errno \(err))")
        }
        guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
            throw NASHelperTransportError.ioError("일반 파일이 아닙니다")
        }
        guard statBuf.st_size >= 0, statBuf.st_size <= Int64(maxBytes) else {
            throw NASWireValidationError.invalidJSON("파일 크기가 \(maxBytes)바이트를 초과합니다")
        }
        let declaredSize = Int(statBuf.st_size)

        // Read exactly the declared size, limited by the remaining byte count.
        var data = Data()
        data.reserveCapacity(declaredSize)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while data.count < declaredSize {
            let bytesToRead = min(buffer.count, declaredSize - data.count)
            let bytesRead = read(fd, &buffer, bytesToRead)
            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                throw NASHelperTransportError.ioError("파일 읽기 실패 (errno \(err))")
            }
            if bytesRead == 0 {
                throw NASHelperTransportError.ioError("파일이 읽는 도중 줄어들었습니다")
            }
            data.append(buffer, count: bytesRead)
        }

        // Mandatory extra 1-byte EOF check: any additional byte means the file grew.
        var extra: UInt8 = 0
        while true {
            let extraRead = read(fd, &extra, 1)
            if extraRead < 0 {
                let err = errno
                if err == EINTR { continue }
                throw NASHelperTransportError.ioError("파일 끝 확인 실패 (errno \(err))")
            }
            if extraRead > 0 {
                throw NASWireValidationError.invalidJSON("파일이 읽는 도중 커졌습니다")
            }
            break
        }

        if data.isEmpty {
            return .incomplete(data)
        }

        return .ready(data)
    }

    /// Runs the blocking control read on a utility-priority detached task so neither the main actor nor the
    /// transport actor is blocked by readdir/open/read. Cancellation is cooperative (checked between
    /// syscalls); an individual syscall already in flight cannot be interrupted and no hard timeout is claimed.
    static func readControlFileAsync(
        root: NASPinnedRoot,
        components: [String],
        maxBytes: Int = 64 * 1024
    ) async throws -> ReadResult {
        try await NASBoundedIO.run(timeout: 15) { cancellation in
            try readControlFile(root: root, components: components, maxBytes: maxBytes, cancellation: cancellation)
        }
    }

    /// openat() whose ENOENT (and only ENOENT) triggers one bounded refresh of `dirFD` and one identical retry.
    /// Returns the descriptor (or -1) with the errno of the last openat() captured immediately, plus the refresh
    /// facts when a refresh was attempted for this open.
    private static func openatRefreshingOnENOENT(
        _ dirFD: Int32,
        _ name: String,
        flags: Int32,
        cancellation: NASControlReadCancellation?
    ) throws -> (fd: Int32, err: Int32, refresh: NASRefreshDiagnostic?) {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let first = openat(dirFD, name, flags)
        let firstErr = errno
        if first >= 0 { return (first, 0, nil) }
        guard firstErr == ENOENT else { return (first, firstErr, nil) }

        let refresh = refreshDirectoryListing(dirFD, cancellation: cancellation)
        if cancellation?.isCancelled == true { throw CancellationError() }
        let retried = openat(dirFD, name, flags)
        let retryErr = errno
        return (retried, retried >= 0 ? 0 : retryErr, refresh)
    }

    /// Best-effort, non-recursive listing of an already verified directory descriptor to refresh the
    /// network-filesystem entry cache. Entry names are never used; failures are ignored.
    /// The returned facts (entry count, stop reason) are diagnostic only and never alter the listing.
    private static func refreshDirectoryListing(_ dirFD: Int32, cancellation: NASControlReadCancellation?) -> NASRefreshDiagnostic {
        func skipped(_ stop: String) -> NASRefreshDiagnostic {
            NASRefreshDiagnostic(performed: false, entries: 0, budgetReached: false, stop: stop)
        }

        var statBuf = stat()
        guard fstat(dirFD, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFDIR else { return skipped("fstat_failed") }

        let start = ProcessInfo.processInfo.systemUptime
        let key = NASDirectoryRefreshGate.Key(dev: statBuf.st_dev, ino: UInt64(statBuf.st_ino))
        guard NASDirectoryRefreshGate.shared.tryBegin(key, now: start) else { return skipped("cooldown") }

        // fdopendir takes ownership of the duplicate on success; closedir closes only the duplicate.
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else { return skipped("dup_failed") }
        guard let dir = fdopendir(dupFD) else {
            close(dupFD)
            return skipped("fdopendir_failed")
        }
        defer { closedir(dir) }
        // dup shares the file offset with dirFD; always list from the beginning.
        rewinddir(dir)

        var entries = 0
        while entries < refreshMaxEntries {
            if cancellation?.isCancelled == true {
                return NASRefreshDiagnostic(performed: true, entries: entries, budgetReached: false, stop: "cancelled")
            }
            if ProcessInfo.processInfo.systemUptime - start >= refreshBudgetSeconds {
                return NASRefreshDiagnostic(performed: true, entries: entries, budgetReached: true, stop: "budget")
            }
            errno = 0
            guard readdir(dir) != nil else {
                // NULL is both end-of-directory and error; errno (reset above) tells them apart.
                return NASRefreshDiagnostic(performed: true, entries: entries, budgetReached: false, stop: errno == 0 ? "eof" : "readdir_err")
            }
            entries += 1
        }
        return NASRefreshDiagnostic(performed: true, entries: entries, budgetReached: false, stop: "cap")
    }

    private static func requireKind(_ kind: mode_t, fd: Int32) throws {
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            let err = errno
            throw NASHelperTransportError.ioError("상태 확인 실패 (errno \(err))")
        }
        guard (statBuf.st_mode & S_IFMT) == kind else {
            throw NASHelperTransportError.ioError("디렉토리가 아닙니다")
        }
    }

    /// Diagnostic only (after a failed openat): distinguishes a symlink from other failures.
    private static func isSymlink(_ dirFD: Int32, _ name: String) -> Bool {
        var statBuf = stat()
        return fstatat(dirFD, name, &statBuf, AT_SYMLINK_NOFOLLOW) == 0
            && (statBuf.st_mode & S_IFMT) == S_IFLNK
    }
}

// MARK: - Safe Atomic File Writer

enum NASAtomicFileWriter {
    /// Writes data atomically to `<directory>/<fileName>` below the pinned root with fsync and exclusive creation, strictly
    /// rejecting symlinks. Every step is descriptor-relative to the pinned root (openat / mkdirat / renameat with O_NOFOLLOW),
    /// so the write can only reach the original root object and never a different object that took over the root's name.
    /// If allowOverwrite is false and the destination already exists, fails closed rather than removing it.
    ///
    /// `cancellation` / `isLive` are checked before the directory walk, before creating the temp file, before every write chunk,
    /// before fsync and before the final rename; a stop request removes the temp file and throws CancellationError. A rename that
    /// already began in the kernel cannot be undone.
    static func writeJSONAtomically(
        data: Data,
        root: NASPinnedRoot,
        directory: [String],
        fileName: String,
        allowOverwrite: Bool = false,
        cancellation: NASControlReadCancellation? = nil,
        isLive: (() -> Bool)? = nil
    ) throws {
        let components = try NASPathSecurity.checkedComponents(directory + [fileName])
        let directoryComponents = Array(components.dropLast())

        func stopRequested() -> Bool {
            cancellation?.isCancelled == true || isLive?() == false
        }
        if stopRequested() { throw CancellationError() }

        let dirFD = try root.withDirectoryFD { rootFD in
            try NASPinnedFS.openDirectoryChain(rootFD, directoryComponents, create: true, stopRequested: stopRequested)
        }
        defer { close(dirFD) }

        if !allowOverwrite && NASPinnedFS.entryExists(dirFD, fileName) {
            throw NASHelperTransportError.destinationAlreadyExists("")
        }

        let tempName = ".\(fileName).\(UUID().uuidString).tmp"

        if stopRequested() { throw CancellationError() }
        let fd = openat(dirFD, tempName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let err = errno
            throw NASHelperTransportError.ioError("임시 파일 생성 실패 (errno \(err))")
        }
        var fdOpen = true
        func fail(_ error: Error) -> Error {
            if fdOpen {
                close(fd)
                fdOpen = false
            }
            unlinkat(dirFD, tempName, 0)
            return error
        }

        let chunk = 64 * 1024
        var written = 0
        while written < data.count {
            if stopRequested() { throw fail(CancellationError()) }
            let result = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: written), min(chunk, raw.count - written))
            }
            if result < 0 {
                let err = errno
                if err == EINTR { continue }
                throw fail(NASHelperTransportError.ioError("파일 쓰기 실패 (errno \(err))"))
            }
            if result == 0 {
                throw fail(NASHelperTransportError.ioError("파일 쓰기 실패 (errno \(EIO))"))
            }
            written += result
        }

        if stopRequested() { throw fail(CancellationError()) }
        if fsync(fd) != 0 {
            let err = errno
            throw fail(NASHelperTransportError.ioError("fsync 동기화 실패 (errno \(err))"))
        }
        close(fd)
        fdOpen = false

        if !allowOverwrite && NASPinnedFS.entryExists(dirFD, fileName) {
            throw fail(NASHelperTransportError.destinationAlreadyExists(""))
        }

        if stopRequested() { throw fail(CancellationError()) }
        if renameat(dirFD, tempName, dirFD, fileName) != 0 {
            let err = errno
            throw fail(NASHelperTransportError.ioError("파일 원자적 교체(rename) 실패 (errno \(err))"))
        }
    }
}

// MARK: - Nonisolated Background Bulk Transfer Worker
// Separate from NASHelperTransport actor to ensure multi-minute bulk I/O never blocks
// the actor's executor or heartbeat/status control protocol messages.

enum NASHelperBulkTransferWorker {
    static let chunkSize = 512 * 1024 // 512 KiB streaming chunk buffer

    /// Streams source media from NAS to local private cache.
    ///
    /// Rules:
    /// - Checks each intermediate directory for symlinks.
    /// - Reads in chunks up to `expectedSize`.
    /// - Attempts to read 1 extra byte: if readable, fails closed (size exceeds expected).
    /// - Verifies computed SHA-256 against NAS declared SHA-256.
    /// - Sets destination file mode to 0600 (owner exclusive).
    /// - Runs nonisolated in a background task; propagates task cancellation.
    nonisolated static func downloadSource(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        destinationURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws {
        // Source is opened descriptor-relative to the pinned root (every component NOFOLLOW, regular file only): no path of the
        // NAS is ever resolved by name here, so a replaced root name or a swapped intermediate link cannot redirect the read.
        let sourceComponents = try NASPathSecurity.checkedComponents(offer.source_path_components)
        let sourceFD = try NASIOFailureDiagnostic.run(.sourceOpen) {
            try root.withDirectoryFD { rootFD in try NASPinnedFS.openRegularFile(rootFD, sourceComponents) }
        }
        let sourceHandle = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false)
        defer { close(sourceFD) }

        let fileManager = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        let destHandle: FileHandle = try NASIOFailureDiagnostic.run(.sourceCopy) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentDir.path)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            fileManager.createFile(atPath: destinationURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            return try FileHandle(forWritingTo: destinationURL)
        }
        defer { try? destHandle.close() }

        var hasher = SHA256()
        var bytesRead: Int64 = 0
        let expectedBytes = offer.source_size_bytes

        var lastProgressReportTime = Date.distantPast
        var lastReportedRatio: Double = -1.0

        while bytesRead < expectedBytes {
            try Task.checkCancellation()

            let toRead = Int(min(Int64(chunkSize), expectedBytes - bytesRead))
            let chunk = sourceHandle.readData(ofLength: toRead)
            guard !chunk.isEmpty else {
                throw NASHelperTransportError.sourceSizeMismatch(expected: expectedBytes, actual: bytesRead)
            }

            hasher.update(data: chunk)
            try NASIOFailureDiagnostic.run(.sourceCopy) { try destHandle.write(contentsOf: chunk) }
            bytesRead += Int64(chunk.count)

            // Throttled progress reporting (at most every 200ms or 1% step)
            let now = Date()
            let currentRatio = Double(bytesRead) / Double(expectedBytes)
            if now.timeIntervalSince(lastProgressReportTime) >= 0.2 || (currentRatio - lastReportedRatio) >= 0.01 || bytesRead == expectedBytes {
                lastProgressReportTime = now
                lastReportedRatio = currentRatio
                onProgress?(bytesRead, expectedBytes)
            }
        }

        // Read 1 extra byte to detect stat under-reporting / trailing data
        let extraByte = sourceHandle.readData(ofLength: 1)
        if !extraByte.isEmpty {
            try? fileManager.removeItem(at: destinationURL)
            throw NASHelperTransportError.sourceFileExceedsExpectedSize(expected: expectedBytes)
        }

        try NASIOFailureDiagnostic.run(.sourceCopy) { try destHandle.synchronize() }

        let calculatedDigest = hasher.finalize()
        let calculatedHex = calculatedDigest.map { String(format: "%02x", $0) }.joined()

        guard calculatedHex.lowercased() == offer.source_sha256.lowercased() else {
            try? fileManager.removeItem(at: destinationURL)
            throw NASHelperTransportError.sourceShaMismatch(expected: offer.source_sha256, actual: calculatedHex)
        }
    }

    /// Uploads candidate file (strictly "output.mp4" or "thumb.jpg") into client attempt directory.
    ///
    /// Rules:
    /// - Strict allowed filenames: output.mp4 -> output.part, thumb.jpg -> thumb.part.
    /// - Fails closed if final destination already exists (never silently deletes existing files).
    /// - Fails closed if .part already exists (never silently overwrites).
    /// - Opens .part with O_CREAT | O_EXCL | O_NOFOLLOW.
    /// - Streams chunk by chunk (512 KiB), fsyncs, then renames to final target name.
    /// - Runs nonisolated in a background task; propagates task cancellation.
    nonisolated static func uploadCandidateFile(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        sourceURL: URL,
        targetFilename: String,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> (size: Int64, sha256: String) {
        // Strict candidate name check and part mapping
        let partFilename: String
        switch targetFilename {
        case "output.mp4":
            partFilename = "output.part"
        case "thumb.jpg":
            partFilename = "thumb.part"
        default:
            throw NASHelperTransportError.invalidCandidateFilename(targetFilename)
        }

        let attemptClientComponents = try NASPathSecurity.checkedComponents(
            [NASHelperWire.handoffDirectoryName, NASHelperWire.versionDirectoryName]
                + NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath)
                + ["client"]
        )

        // Descriptor-relative to the pinned root: directory chain (created with NOFOLLOW), exclusive .part, renameat.
        let dirFD = try NASIOFailureDiagnostic.run(.uploadOpen) {
            try root.withDirectoryFD { rootFD in
                try NASPinnedFS.openDirectoryChain(rootFD, attemptClientComponents, create: true)
            }
        }
        defer { close(dirFD) }

        // Never silently delete existing paths! Fail closed.
        if NASPinnedFS.entryExists(dirFD, targetFilename) {
            throw NASHelperTransportError.destinationAlreadyExists("")
        }
        if NASPinnedFS.entryExists(dirFD, partFilename) {
            throw NASHelperTransportError.destinationAlreadyExists("")
        }

        // Exclusive nofollow creation of the .part file
        let fd = openat(dirFD, partFilename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let err = errno
            throw NASHelperTransportError.operationFailed(NASIOFailureDiagnostic(phase: .uploadOpen, errnoValue: err, cocoaCode: nil))
        }

        let sourceHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            close(fd)
            unlinkat(dirFD, partFilename, 0)
            throw NASIOFailureDiagnostic.tagged(.uploadOpen, error)
        }
        defer { try? sourceHandle.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0

        let sourceValues = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let expectedSourceBytes = Int64(sourceValues?.fileSize ?? 0)

        var lastProgressReportTime = Date.distantPast
        var lastReportedRatio: Double = -1.0

        var uploadError: Error? = nil
        while true {
            if Task.isCancelled {
                uploadError = CancellationError()
                break
            }

            let chunk = sourceHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            hasher.update(data: chunk)

            var written = 0
            var writeFailed = false
            chunk.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                while written < rawBuffer.count {
                    let res = write(fd, base.advanced(by: written), rawBuffer.count - written)
                    if res <= 0 {
                        let err = errno
                        uploadError = NASHelperTransportError.operationFailed(NASIOFailureDiagnostic(phase: .uploadWrite, errnoValue: err, cocoaCode: nil))
                        writeFailed = true
                        return
                    }
                    written += res
                }
            }

            if writeFailed { break }

            totalBytes += Int64(chunk.count)

            if expectedSourceBytes > 0 {
                let now = Date()
                let currentRatio = Double(totalBytes) / Double(expectedSourceBytes)
                if now.timeIntervalSince(lastProgressReportTime) >= 0.2 || (currentRatio - lastReportedRatio) >= 0.01 || totalBytes == expectedSourceBytes {
                    lastProgressReportTime = now
                    lastReportedRatio = currentRatio
                    onProgress?(totalBytes, expectedSourceBytes)
                }
            }
        }

        if let uploadError {
            close(fd)
            unlinkat(dirFD, partFilename, 0)
            throw uploadError
        }

        if fsync(fd) != 0 {
            let err = errno
            close(fd)
            unlinkat(dirFD, partFilename, 0)
            throw NASHelperTransportError.operationFailed(NASIOFailureDiagnostic(phase: .uploadFinalize, errnoValue: err, cocoaCode: nil))
        }
        close(fd)

        if NASPinnedFS.entryExists(dirFD, targetFilename) {
            unlinkat(dirFD, partFilename, 0)
            throw NASHelperTransportError.destinationAlreadyExists("")
        }

        if renameat(dirFD, partFilename, dirFD, targetFilename) != 0 {
            let err = errno
            unlinkat(dirFD, partFilename, 0)
            throw NASHelperTransportError.operationFailed(NASIOFailureDiagnostic(phase: .uploadFinalize, errnoValue: err, cocoaCode: nil))
        }

        let digest = hasher.finalize()
        let sha256Hex = digest.map { String(format: "%02x", $0) }.joined()

        return (totalBytes, sha256Hex)
    }
}

// MARK: - Actor Managing Control Protocol Transport

/// Actor managing responsive, thread-safe control protocol transport with the NAS.
///
/// Bulk I/O (download/upload) is delegated to `NASHelperBulkTransferWorker` outside this actor
/// so that heartbeat, status reading, and request submission are NEVER blocked by long file transfers.
actor NASHelperTransport {
    private let fileManager = FileManager.default

    // Serializes inbox requests per root to enforce at most 1 pending request per root/client
    private var pendingRequestLocks: [String: Bool] = [:]

    init() {}

    // MARK: - Root Descriptor Resolution (Exact Root Only, No Ancestor Search)

    /// Resolves the authoritative RootDescriptor located strictly at `<folderURL>/.NasFinder-Handoff/v1/root.json`.
    /// Never performs ancestor search. If missing, returns nil.
    ///
    /// Connected helper runs read it through the connection's pinned root (`resolveRootDescriptor(root:)`). This URL form is only the
    /// non-connected folder-picker resolution (add / refresh): it pins the folder once for this single read and releases it.
    nonisolated func resolveRootDescriptor(at folderURL: URL) async throws -> NASWireRootDescriptor? {
        let pin = try await NASPinnedRoot.open(url: folderURL, folderID: UUID(), connection: 0)
        defer { pin.close() }
        return try await resolveRootDescriptor(root: pin)
    }

    nonisolated func resolveRootDescriptor(root: NASPinnedRoot) async throws -> NASWireRootDescriptor? {
        let readResult = try await NASControlFileReader.readControlFileAsync(
            root: root, components: Self.handoff("root.json"), maxBytes: 64 * 1024
        )
        switch readResult {
        case .notFound, .incomplete:
            return nil
        case .ready(let data):
            let descriptor = try NASWireCodec.decode(
                NASWireRootDescriptor.self,
                from: data,
                allowedKeys: NASWireRootDescriptor.allowedKeys
            )
            try descriptor.validate()
            return descriptor
        }
    }

    // MARK: - Inbox Request and Response (Serialized per Root/Client)

    /// Submits an InboxRequest to `<root>/.NasFinder-Handoff/v1/inbox/<request_id>.json`.
    /// Serialized so that only 1 pending inbox request is active per root/client.
    nonisolated func submitInboxRequest(root: NASPinnedRoot, request: NASWireInboxRequest) async throws {
        let fileName = "\(request.request_id).json"
        let data = try NASWireCodec.encode(request)

        // Bounded detached I/O: a stuck mount never blocks the transport or the caller's deadline.
        try await NASBoundedIO.run(timeout: 20) { cancellation in
            // Write atomically with fsync and exclusive creation (descriptor-relative to the pinned root)
            try NASAtomicFileWriter.writeJSONAtomically(
                data: data,
                root: root,
                directory: Self.handoff("inbox"),
                fileName: fileName,
                allowOverwrite: false,
                cancellation: cancellation
            )
        }
    }

    /// Waits for `join_response.json` matching `requestID`.
    /// Bypasses stat/directory listing negative caches by opening directly with O_NOFOLLOW.
    /// Poll behavior is unchanged; the last poll status, attempt count and elapsed seconds are remembered and
    /// attached (as a bounded, privacy-safe `NASJoinDiagnostic`) to every failure except task cancellation.
    func waitForJoinResponse(
        root: NASPinnedRoot,
        clientID: String,
        requestID: String,
        timeoutSeconds: TimeInterval = 20,
        source: NASJoinResponseSource = .legacy
    ) async throws -> NASJoinWaitResult {
        let responseComponents = Self.handoff("clients", clientID, source == .immutable ? "join_response-\(requestID).json" : "join_response.json")

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeoutSeconds)
        var attempts = 0
        var lastStatus = "not_found"
        var lastNotFound: NASNotFoundDiagnostic?

        func elapsedSeconds() -> Int { Int(Date().timeIntervalSince(startedAt).rounded()) }

        while Date() < deadline {
            try Task.checkCancellation()
            attempts += 1

            do {
                let readResult = try await NASControlFileReader.readControlFileAsync(
                    root: root,
                    components: responseComponents,
                    maxBytes: 64 * 1024
                )
                switch readResult {
                case .notFound(let source):
                    // File does not exist yet; continue polling
                    lastStatus = "not_found"
                    lastNotFound = source
                case .incomplete:
                    // In-flight flush; continue polling
                    lastStatus = "empty"
                    lastNotFound = nil
                case .ready(let data):
                    lastNotFound = nil
                    guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                          let dict = jsonObject as? [String: Any] else {
                        // Data incomplete or midway through write; continue polling
                        lastStatus = "malformed_json"
                        break
                    }
                    guard let respRequestID = dict["request_id"] as? String else {
                        lastStatus = "missing_request_id"
                        break
                    }
                    if respRequestID != requestID {
                        // Stale response from a prior request; wait for current response to overwrite
                        lastStatus = "stale_request_id"
                        break
                    }
                    lastStatus = "matching_response"

                    // Strict validation and decoding for the matching request
                    do {
                        if source == .immutable {
                            try NASWireValidators.assertNoUnknownKeys(in: dict, allowedKeys: NASWireJoinResponseIC.allowedKeys)
                            let ic = try JSONDecoder().decode(NASWireJoinResponseIC.self, from: data)
                            try ic.validate(expectedRequestID: requestID, expectedClientID: clientID)
                            guard ic.supportsImmutableControl else {
                                throw NASWireValidationError.policyMismatch("immutable control feature missing")
                            }
                            return NASJoinWaitResult(response: ic.legacyView, attempts: attempts, elapsedSeconds: elapsedSeconds(), immutable: ic)
                        }
                        try NASWireValidators.assertNoUnknownKeys(in: dict, allowedKeys: NASWireJoinResponse.allowedKeys)
                        let response = try JSONDecoder().decode(NASWireJoinResponse.self, from: data)
                        try response.validate(expectedRequestID: requestID, expectedClientID: clientID)
                        return NASJoinWaitResult(response: response, attempts: attempts, elapsedSeconds: elapsedSeconds())
                    } catch {
                        // Permanent schema or identity failure: fail fast, keeping the exact validation category
                        throw NASHelperTransportError.joinDiagnosed(NASJoinDiagnostic(
                            lastStatus: lastStatus,
                            cause: "schema",
                            attempts: attempts,
                            elapsedSeconds: elapsedSeconds(),
                            errnoValue: nil,
                            detail: error is DecodingError ? "decode" : NASJoinDiagnostic.validationCode(error),
                            expectedGeneration: nil,
                            actualGeneration: nil,
                            rootIDEqual: nil,
                            clientIDEqual: nil,
                            generationEqual: nil,
                            lowerMessage: NASHelperTransportError.responseSchemaMismatch("").errorDescription ?? ""
                        ))
                    }
                }
            } catch is CancellationError {
                // Cancellation stays distinct from any NAS/read failure
                throw CancellationError()
            } catch let err as NASHelperTransportError {
                if case .joinDiagnosed = err { throw err }
                throw Self.joinReadFailure(err, attempts: attempts, startedAt: startedAt)
            } catch {
                throw Self.joinReadFailure(error, attempts: attempts, startedAt: startedAt)
            }

            try await Task.sleep(for: .milliseconds(400))
        }

        throw NASHelperTransportError.joinDiagnosed(NASJoinDiagnostic(
            lastStatus: lastStatus,
            cause: "timeout",
            attempts: attempts,
            elapsedSeconds: elapsedSeconds(),
            errnoValue: nil,
            detail: nil,
            expectedGeneration: nil,
            actualGeneration: nil,
            rootIDEqual: nil,
            clientIDEqual: nil,
            generationEqual: nil,
            lowerMessage: NASHelperTransportError.responseReadFailed("").errorDescription ?? "",
            notFound: lastStatus == "not_found" ? lastNotFound : nil
        ))
    }

    /// After a LEGACY join answer: looks for the immutable answer of the same request for a short bounded grace
    /// (the NAS publishes it BEFORE the legacy file). Returns nil only when the file is truly absent (a 0.4.0 NAS); a
    /// present but invalid/mismatching file fails closed. A hit lets a client that read a stale root.json adopt the NAS's
    /// authenticated coordinator epoch and switch to immutable control.
    func probeImmutableJoinResponse(
        root: NASPinnedRoot,
        clientID: String,
        requestID: String,
        attempts: Int = 5,
        interval: Duration = .milliseconds(800)
    ) async throws -> NASWireJoinResponseIC? {
        let responseComponents = Self.handoff("clients", clientID, "join_response-\(requestID).json")
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            switch try await NASControlFileReader.readControlFileAsync(root: root, components: responseComponents, maxBytes: 64 * 1024) {
            case .notFound, .incomplete:
                break
            case .ready(let data):
                do {
                    let ic = try NASWireCodec.decode(NASWireJoinResponseIC.self, from: data, allowedKeys: NASWireJoinResponseIC.allowedKeys)
                    try ic.validate(expectedRequestID: requestID, expectedClientID: clientID)
                    return ic.supportsImmutableControl ? ic : nil
                } catch {
                    throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
                }
            }
            if attempt + 1 < max(1, attempts) {
                try await Task.sleep(for: interval)
            }
        }
        return nil
    }

    /// Wraps a read-phase failure with its classified category (enum/errno only) without discarding the lower error's message.
    private static func joinReadFailure(_ error: Error, attempts: Int, startedAt: Date) -> NASHelperTransportError {
        let classified = NASJoinDiagnostic.classify(error)
        return .joinDiagnosed(NASJoinDiagnostic(
            lastStatus: "io_errno",
            cause: classified.cause,
            attempts: attempts,
            elapsedSeconds: Int(Date().timeIntervalSince(startedAt).rounded()),
            errnoValue: classified.errnoValue,
            detail: classified.detail,
            expectedGeneration: nil,
            actualGeneration: nil,
            rootIDEqual: nil,
            clientIDEqual: nil,
            generationEqual: nil,
            lowerMessage: classified.message
        ))
    }

    /// Waits for `work_response.json` matching `requestID`.
    /// Bypasses stat/directory listing negative caches by opening directly with O_NOFOLLOW.
    func waitForWorkResponse(
        root: NASPinnedRoot,
        clientID: String,
        requestID: String,
        timeoutSeconds: TimeInterval = 20,
        source: NASWorkResponseSource = .legacy
    ) async throws -> NASWireWorkResponse {
        // Immutable answers live under a name that carries the request id: a cached older answer cannot be mistaken for it.
        let responseComponents = Self.handoff("clients", clientID, source == .immutable ? "work_response-\(requestID).json" : "work_response.json")

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()

            do {
                let readResult = try await NASControlFileReader.readControlFileAsync(
                    root: root,
                    components: responseComponents,
                    maxBytes: 64 * 1024
                )
                switch readResult {
                case .notFound, .incomplete:
                    // File does not exist yet or in-flight flush; continue polling
                    break
                case .ready(let data):
                    guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                          let dict = jsonObject as? [String: Any] else {
                        // Data incomplete or midway through write; continue polling
                        break
                    }
                    guard let respRequestID = dict["request_id"] as? String else {
                        break
                    }
                    if respRequestID != requestID {
                        if source == .immutable {
                            // The file name names this request: a different id inside is an identity failure, never "stale".
                            throw NASHelperTransportError.responseSchemaMismatch("work_response 요청 ID 불일치")
                        }
                        // Stale response from a prior request; wait for current response to overwrite
                        break
                    }

                    // Strict validation and decoding for the matching request
                    do {
                        try NASWireValidators.assertNoUnknownKeys(in: dict, allowedKeys: NASWireWorkResponse.allowedKeys)
                        let response = try JSONDecoder().decode(NASWireWorkResponse.self, from: data)
                        try response.validate(expectedRequestID: requestID, expectedClientID: clientID)
                        return response
                    } catch {
                        // Permanent schema or identity failure: fail fast with clear diagnostic
                        throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
                    }
                }
            } catch let err as NASHelperTransportError {
                throw err
            } catch {
                throw error
            }

            try await Task.sleep(for: .milliseconds(400))
        }

        throw NASHelperTransportError.pendingRequestTimeout("request_work 응답 대기 시간 초과")
    }

    // MARK: - Offer Validation and Reading

    /// Reads and strictly validates an Offer from its exact relative path.
    /// Expected syntax: `attempts/<epoch>/<job>/<item>/<attempt>/<client>/offer.json`
    func readOffer(
        root: NASPinnedRoot,
        offerRelativePath: String,
        expectedClientID: String
    ) async throws -> NASWireOffer {
        let components = offerRelativePath.split(separator: "/").map(String.init)
        guard components.count == 7,
              components[0] == "attempts",
              components[6] == "offer.json",
              components[5] == expectedClientID else {
            throw NASHelperTransportError.invalidOfferPath(offerRelativePath)
        }

        let readResult = try await NASControlFileReader.readControlFileAsync(
            root: root,
            components: Self.handoff(components),
            maxBytes: 64 * 1024
        )

        let data: Data
        switch readResult {
        case .notFound:
            // True ENOENT from openat() only; path syntax, containment, symlink and identity checks above/below stay strict.
            throw NASHelperTransportError.offerNotVisible
        case .incomplete:
            throw NASHelperTransportError.responseReadFailed("Offer 파일이 비어 있습니다")
        case .ready(let d):
            data = d
        }

        let offer: NASWireOffer
        do {
            offer = try NASWireCodec.decode(
                NASWireOffer.self,
                from: data,
                allowedKeys: NASWireOffer.allowedKeys
            )
            try offer.validate(expectedClientID: expectedClientID)
        } catch {
            throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
        }
        // The offer must belong to the root and generation the connection was bound to at the verified join.
        try root.requireBinding(rootID: offer.root_id, generation: offer.root_generation, epoch: offer.coordinator_epoch)

        guard let expiresAt = NASHelperWire.parseISO8601Date(offer.offer_expires_at) else {
            throw NASHelperTransportError.responseSchemaMismatch("offer_expires_at 형식이 올바르지 않습니다.")
        }
        if expiresAt < Date() {
            throw NASHelperTransportError.offerExpired(offer.offer_expires_at)
        }

        return offer
    }

    // MARK: - Heartbeat and Acknowledgement

    static let periodicHeartbeatWriteTimeout: TimeInterval = 8
    static let firstHeartbeatWriteMaxTimeout: TimeInterval = 30

    /// Writes a heartbeat to `<root>/.NasFinder-Handoff/v1/attempts/<epoch>/<job>/<item>/<attempt>/<client>/client/heartbeat.json`.
    /// Periodic heartbeat updates are atomic and fsynced.
    /// Runs as bounded detached I/O (never on the actor executor), so a hung write cannot hold back the other attempts,
    /// the ACK reader or the lease deadline of this attempt.
    ///
    /// `firstWriteTimeout` is ONLY for the very first heartbeat of an attempt (the handshake's seq=1 write): the caller's
    /// I/O budget instead of the periodic 8s. It must be finite, > 0 and <= `firstHeartbeatWriteMaxTimeout`; anything else
    /// fails closed (before any worker starts, the slot is freed). It never extends the offer, the NAS lease or the send anchor.
    nonisolated func writeHeartbeat(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        heartbeat: NASWireHeartbeat,
        slot: NASHeartbeatWriteGate.Slot,
        firstWriteTimeout: TimeInterval? = nil
    ) async throws {
        do {
            var ioTimeout = Self.periodicHeartbeatWriteTimeout
            if let firstWriteTimeout {
                guard firstWriteTimeout.isFinite, firstWriteTimeout > 0, firstWriteTimeout <= Self.firstHeartbeatWriteMaxTimeout else {
                    throw NASHelperTransportError.ioError("첫 Heartbeat 쓰기 제한 시간이 유효하지 않습니다.")
                }
                ioTimeout = firstWriteTimeout
            }
            let directory = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["client"])
            let data = try NASWireCodec.encode(heartbeat)

            try await NASBoundedIO.run(timeout: ioTimeout) { cancellation in
                // Everything below runs on the worker. Only its genuine return frees the attempt's single writer slot;
                // the caller's timeout or cancellation never does (and then no second write may start).
                guard slot.tryStartWorker() else { throw CancellationError() }
                defer { slot.workerFinished() }
                try NASAtomicFileWriter.writeJSONAtomically(
                    data: data,
                    root: root,
                    directory: directory,
                    fileName: "heartbeat.json",
                    allowOverwrite: true, // Periodic heartbeat updates overwrite heartbeat.json
                    cancellation: cancellation,
                    isLive: { slot.isLive }
                )
            }
        } catch {
            // Failed before a worker ever started (gate full, cancelled early, timed out while still queued): free the slot now.
            slot.endIfNotStarted()
            throw error
        }
    }

    /// Reads latest HeartbeatAck from `<root>/.NasFinder-Handoff/v1/attempts/<epoch>/<job>/<item>/<attempt>/<client>/server/heartbeat_ack.json`.
    func readHeartbeatAck(root: NASPinnedRoot, offer: NASWireOffer) async throws -> NASWireHeartbeatAck? {
        let ackComponents = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["server", "heartbeat_ack.json"])

        let readResult = try await NASControlFileReader.readControlFileAsync(
            root: root,
            components: ackComponents,
            maxBytes: 64 * 1024
        )
        switch readResult {
        case .notFound, .incomplete:
            return nil
        case .ready(let data):
            do {
                let ack = try NASWireCodec.decode(
                    NASWireHeartbeatAck.self,
                    from: data,
                    allowedKeys: NASWireHeartbeatAck.allowedKeys
                )
                try ack.validate(matching: offer)
                return ack
            } catch {
                throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
            }
        }
    }

    // MARK: - Immutable Control Reads (immutable_control_1)

    /// How many of the newest sent heartbeat seqs are looked at per ACK poll (the NAS keeps the newest 16 files).
    static let immutableAckWindow = 6

    /// Per-file I/O budget, whole-poll budget and how many stuck files one poll tolerates (every stuck read keeps one of the
    /// `NASBoundedIOGate.capacity` slots until the mount answers, so the second stuck file ends the poll).
    static let immutableAckFileTimeout: TimeInterval = 3
    static let immutableAckPollBudget: TimeInterval = 10
    static let immutableAckMaxTimeouts = 2

    /// Reads the immutable ACK files `server/ack-<seq>.json` for the seqs in `(afterSeq, highestSentSeq]`, newest
    /// `immutableAckWindow` only, NEWEST FIRST, one bounded read per file. Every file must carry the attempt's exact 9-tuple
    /// AND `ack_seq == <seq>` of its own name. A file that is absent is simply not there yet (never an error); an invalid one
    /// fails closed. The scan stops at the first decisive ACK (`received` or a genuine rejection): a newer ACK covers all older
    /// seqs, so older files (e.g. superseded `STALE_SEQ` rejections) are never looked at, and an ACK that was already read is
    /// never discarded because a different file is missing or slow. A file that times out is skipped once (it cannot starve
    /// the older ACKs); the second timeout, or a gate-full/IO failure, ends the poll with that error.
    /// This path NEVER falls back to the mutable `heartbeat_ack.json`.
    nonisolated func readImmutableHeartbeatAcks(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        afterSeq: Int,
        highestSentSeq: Int
    ) async throws -> [NASWireHeartbeatAck] {
        guard highestSentSeq > afterSeq else { return [] }
        let first = max(afterSeq + 1, highestSentSeq - Self.immutableAckWindow + 1, 1)
        let serverDir = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["server"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.immutableAckPollBudget)
        var found: [NASWireHeartbeatAck] = []
        var timeouts = 0
        var lastTimeout: Error?
        for seq in stride(from: highestSentSeq, through: first, by: -1) {
            try Task.checkCancellation()
            let remaining = (deadline - clock.now) / .seconds(1)
            guard remaining > 0.5 else { break }
            let ackComponents = serverDir + ["ack-\(seq).json"]
            do {
                let ack: NASWireHeartbeatAck? = try await NASBoundedIO.run(timeout: min(Self.immutableAckFileTimeout, remaining)) { cancellation in
                    let read = try NASControlFileReader.readControlFile(root: root, components: ackComponents, maxBytes: 64 * 1024, cancellation: cancellation)
                    guard case .ready(let data) = read else { return nil }
                    do {
                        let ack = try NASWireCodec.decode(NASWireHeartbeatAck.self, from: data, allowedKeys: NASWireHeartbeatAck.allowedKeys)
                        try ack.validate(matching: offer)
                        guard ack.ack_seq == seq else {
                            throw NASWireValidationError.offerIdentityMismatch("ACK 파일 이름과 ack_seq 불일치")
                        }
                        return ack
                    } catch {
                        throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
                    }
                }
                guard let ack else { continue }
                found.append(ack)
                if ack.isDecisive { return found }
            } catch NASHelperTransportError.ioError(let message) where message.contains("errno \(ETIMEDOUT)") {
                timeouts += 1
                lastTimeout = NASHelperTransportError.ioError(message)
                if timeouts >= Self.immutableAckMaxTimeouts { throw NASHelperTransportError.ioError(message) }
            }
        }
        // Nothing decisive and a file was stuck: report the real cause instead of an indistinguishable "empty" read.
        if let lastTimeout { throw lastTimeout }
        return found
    }

    /// Per-file I/O budget and whole-call budget of one immutable receipt read (separate bounded reads, so a slow or missing
    /// file never discards a receipt that was already read and validated in the same call).
    static let immutableReceiptFileTimeout: TimeInterval = 5
    static let immutableReceiptPollBudget: TimeInterval = 12

    /// Only a bounded-I/O timeout or a full I/O gate is a transient condition of the mount; every other failure (path, symlink,
    /// identity, schema, permission, ...) is not and keeps failing closed.
    nonisolated static func isTransientReadIOError(_ error: Error) -> Bool {
        guard case NASHelperTransportError.ioError(let message) = error else { return false }
        return message.contains("errno \(ETIMEDOUT)") || message.contains("errno \(EBUSY)")
    }

    /// Immutable receipts `server/receipt-<rev>.json` (one file per revision, created exactly once). Reads the revision the
    /// newest ACK advertised first, then probes the following revisions in ascending order. Each file is its own bounded read
    /// and must carry the attempt's exact 9-tuple, `receipt_revision == <rev of its name>` and the strict schema; a malformed
    /// file fails closed. A TERMINAL receipt is returned the moment it is validated (no further file is read). A valid
    /// non-terminal receipt is returned as soon as the next revision is absent, or when reading it hit a transient mount
    /// timeout/busy condition (the receipt already read is never discarded). Returns the HIGHEST valid revision found, or nil
    /// (also when the first read itself hit a transient condition, which is thrown as `ioError` for the caller's bounded retry).
    /// Never falls back to the mutable `receipt.json`.
    nonisolated func readImmutableServerReceipt(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        lastRevision: Int,
        hintRevision: Int
    ) async throws -> NASWireServerReceipt? {
        let serverDir = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["server"])
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(Self.immutableReceiptPollBudget)

        func receipt(at revision: Int) async throws -> NASWireServerReceipt? {
            let remaining = (deadline - clock.now) / .seconds(1)
            guard remaining > 0.5 else {
                throw NASHelperTransportError.ioError("영수증 읽기 제한 시간 초과 (errno \(ETIMEDOUT))")
            }
            return try await NASBoundedIO.run(timeout: min(Self.immutableReceiptFileTimeout, remaining)) { cancellation in
                let receiptComponents = serverDir + ["receipt-\(revision).json"]
                let read = try NASControlFileReader.readControlFile(root: root, components: receiptComponents, maxBytes: 64 * 1024, cancellation: cancellation)
                guard case .ready(let data) = read else { return nil }
                do {
                    let value = try NASWireCodec.decode(NASWireServerReceipt.self, from: data, allowedKeys: NASWireServerReceipt.allowedKeys)
                    try value.validate(matching: offer)
                    guard value.receipt_revision == revision else {
                        throw NASWireValidationError.receiptIdentityMismatch("영수증 파일 이름과 revision 불일치")
                    }
                    return value
                } catch {
                    throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
                }
            }
        }

        let lowest = max(0, lastRevision) + 1
        var best: NASWireServerReceipt?
        do {
            // A skipped revision (its publication failed) must not hide a later one the ACK already advertised.
            var next = lowest
            if hintRevision > lowest, hintRevision <= lowest + 16, let value = try await receipt(at: hintRevision) {
                best = value
                if value.status.isTerminalReceipt { return value }
                next = hintRevision + 1
            }
            var probes = 0
            while probes < 8, let value = try await receipt(at: next) {
                best = value
                if value.status.isTerminalReceipt { return value }
                next += 1
                probes += 1
            }
        } catch where best != nil && Self.isTransientReadIOError(error) {
            // The next revision could not be read in time: the valid receipt already read stands.
        }
        return best
    }

    /// Job status freshness by explicit request-response: a unique `status_request` (inbox) is answered by a uniquely named,
    /// immutable `clients/<client>/status_response-<request_id>.json`. Returns nil when no answer arrived in time.
    /// `timeoutSeconds` is only the CALLER's I/O budget for this wait, not the end-to-end life of the request: a caller that
    /// needs longer (a slow WebDAV/SMB mount can take well over 10 s to show a new file) keeps the returned request ID
    /// and polls the SAME request again with `awaitStatusResponse` instead of issuing new IDs.
    nonisolated func requestFreshJobStatus(
        root: NASPinnedRoot,
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        jobID: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> NASWireJobStatus? {
        let request = try await submitStatusRequest(root: root, rootID: rootID, rootGeneration: rootGeneration, clientID: clientID, jobID: jobID)
        return try await awaitStatusResponse(root: root, clientID: clientID, requestID: request.request_id, timeoutSeconds: timeoutSeconds)
    }

    /// Submits exactly one `status_request` and returns it (its `request_id` identifies the only acceptable answer).
    nonisolated func submitStatusRequest(
        root: NASPinnedRoot,
        rootID: String,
        rootGeneration: Int,
        clientID: String,
        jobID: String
    ) async throws -> NASWireInboxRequest {
        let request = NASWireInboxRequest.makeStatusRequest(rootID: rootID, rootGeneration: rootGeneration, clientID: clientID, jobID: jobID)
        try await submitInboxRequest(root: root, request: request)
        return request
    }

    /// Waits up to `timeoutSeconds` (caller I/O budget) for the answer of ONE already submitted `status_request`.
    /// Only the exact `status_response-<requestID>.json` of this client is read; a present answer must carry exactly this
    /// request and client ID and decode strictly, otherwise it fails closed. nil = not visible (yet).
    nonisolated func awaitStatusResponse(
        root: NASPinnedRoot,
        clientID: String,
        requestID: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> NASWireJobStatus? {
        let responseComponents = Self.handoff("clients", clientID, "status_response-\(requestID).json")
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            switch try await NASControlFileReader.readControlFileAsync(root: root, components: responseComponents, maxBytes: 256 * 1024) {
            case .notFound, .incomplete:
                break
            case .ready(let data):
                do {
                    let answer = try NASWireCodec.decode(NASWireJobStatusResponse.self, from: data, allowedKeys: NASWireJobStatusResponse.allowedKeys)
                    try answer.validate(expectedRequestID: requestID, expectedClientID: clientID)
                    return answer.jobStatus
                } catch {
                    throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// The write-once final snapshot `status/<job>/job_status-final.json` the NAS creates when a job ends (completed, failed,
    /// cancelled). It is the only status source once the root's inbox is no longer polled. Same strict identity checks.
    nonisolated func readFinalJobStatus(root: NASPinnedRoot, jobID: String) async throws -> NASWireJobStatus? {
        let statusComponents = Self.handoff("status", jobID, "job_status-final.json")
        switch try await NASControlFileReader.readControlFileAsync(root: root, components: statusComponents, maxBytes: 256 * 1024) {
        case .notFound, .incomplete:
            return nil
        case .ready(let data):
            do {
                let status = try NASWireCodec.decode(NASWireJobStatus.self, from: data, allowedKeys: NASWireJobStatus.allowedKeys)
                try status.validate()
                return status
            } catch {
                throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
            }
        }
    }

    // MARK: - Client Result Publication (Must be Published Last!)

    /// Publishes `result.json` strictly after candidate files have been uploaded and fsynced.
    /// Fails closed if result.json already exists.
    nonisolated func publishResult(
        root: NASPinnedRoot,
        offer: NASWireOffer,
        result: NASWireClientResult
    ) async throws {
        let directory = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["client"])
        let data = try NASWireCodec.encode(result)

        try await NASBoundedIO.run(timeout: 20) { cancellation in
            try NASAtomicFileWriter.writeJSONAtomically(
                data: data,
                root: root,
                directory: directory,
                fileName: "result.json",
                allowOverwrite: false, // Result manifest is published exactly once; fail closed if present
                cancellation: cancellation
            )
        }
    }

    // MARK: - Server Receipt Polling

    /// Reads the authoritative `receipt.json` published by the NAS.
    func readServerReceipt(
        root: NASPinnedRoot,
        offer: NASWireOffer
    ) async throws -> NASWireServerReceipt? {
        let receiptComponents = Self.handoff(try NASPathSecurity.checkedComponents(ofRelativePath: offer.attemptDirectoryRelativePath) + ["server", "receipt.json"])

        let readResult = try await NASControlFileReader.readControlFileAsync(
            root: root,
            components: receiptComponents,
            maxBytes: 64 * 1024
        )
        switch readResult {
        case .notFound, .incomplete:
            return nil
        case .ready(let data):
            do {
                let receipt = try NASWireCodec.decode(
                    NASWireServerReceipt.self,
                    from: data,
                    allowedKeys: NASWireServerReceipt.allowedKeys
                )
                try receipt.validate(matching: offer)
                return receipt
            } catch {
                throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
            }
        }
    }

    // MARK: - Job Status Reading

    /// Reads aggregate `job_status.json` from `.NasFinder-Handoff/v1/status/<job_id>/job_status.json`.
    func readJobStatus(root: NASPinnedRoot, jobID: String) async throws -> NASWireJobStatus? {
        let statusComponents = Self.handoff("status", jobID, "job_status.json")

        let readResult = try await NASControlFileReader.readControlFileAsync(
            root: root,
            components: statusComponents,
            maxBytes: 256 * 1024
        )
        switch readResult {
        case .notFound, .incomplete:
            return nil
        case .ready(let data):
            do {
                let status = try NASWireCodec.decode(
                    NASWireJobStatus.self,
                    from: data,
                    allowedKeys: NASWireJobStatus.allowedKeys
                )
                try status.validate()
                return status
            } catch {
                throw NASHelperTransportError.responseSchemaMismatch(error.localizedDescription)
            }
        }
    }

    // MARK: - Helper Base URL

    /// Components of a control file below the pinned root: `.NasFinder-Handoff/v1/<rest...>` (checked when read or written).
    nonisolated private static func handoff(_ rest: String...) -> [String] {
        handoff(rest)
    }

    nonisolated private static func handoff(_ rest: [String]) -> [String] {
        [NASHelperWire.handoffDirectoryName, NASHelperWire.versionDirectoryName] + rest
    }
}
