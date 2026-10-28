import CryptoKit
import Darwin
import Foundation

/// Removes absolute user locations from diagnostic text that the user may paste into a chat.
enum NASDiagnosticRedaction {
    static func redact(_ text: String) -> String {
        var result = text
        let home = NSHomeDirectory()
        if home.count > 1 {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        let rules: [(pattern: String, template: String)] = [
            ("/Users/[^/\\s\"']+", "/Users/<사용자>"),
            ("/Volumes/[^/\\s\"']+", "/Volumes/<볼륨>"),
            ("/(private/)?var/folders/[^/\\s\"']+/[^/\\s\"']+/[^/\\s\"']+", "<임시폴더>")
        ]
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return result
    }

    /// Hardware architecture the process really runs on (`arm64` / `x86_64`).
    static var machineArchitecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }
}

/// Detection and validation of required local tool binaries and embedded scripts.
/// The runtime bundled in the app (`Resources/Runtime/<arch>`) is used first; the Homebrew/system directories
/// (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`) are only a development fallback.
/// Fixed trusted tools rule: `ffmpeg` and `ffprobe` must both reside in the exact same directory.
struct NASToolEnvironment: Equatable, Sendable {
    enum RuntimeSource: String, Equatable, Sendable {
        case bundled = "앱 내장 런타임"
        case system = "시스템 폴더(개발용)"
        case none = "찾지 못함"
    }

    let python3URL: URL?
    let ffmpegURL: URL?
    let ffprobeURL: URL?
    let toolsDirURL: URL?
    let engineScriptURL: URL?
    let engineWorkerURL: URL?
    var runtimeSource: RuntimeSource = .none

    /// Architecture folder name of the bundled runtime that matches this build.
    static var compiledArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    var hasRequiredMediaTools: Bool {
        python3URL != nil && ffmpegURL != nil && ffprobeURL != nil && toolsDirURL != nil
    }

    var hasBundledEngine: Bool {
        engineScriptURL != nil && engineWorkerURL != nil
    }

    var isReadyToExecute: Bool {
        hasRequiredMediaTools && hasBundledEngine
    }

    /// Clear, user-friendly diagnostic message.
    var diagnosticMessage: String {
        if !hasRequiredMediaTools {
            var missing: [String] = []
            if python3URL == nil { missing.append("python3") }
            if ffmpegURL == nil || ffprobeURL == nil || toolsDirURL == nil {
                missing.append("ffmpeg/ffprobe(동일 디렉토리)")
            }
            return "앱에 포함된 영상 변환 도구(\(missing.joined(separator: ", ")))를 찾을 수 없습니다. 앱 설치가 불완전하거나 손상되었을 수 있으니 최신 버전 앱을 다시 설치해 주세요. 계속되면 변환 기록의 '진단 내용 복사'로 전달해 주세요."
        }
        if !hasBundledEngine {
            return "변환 엔진(engine_cli.py, worker.py)이 앱 번들에 준비되지 않았습니다. 앱 번들에 엔진 스크립트를 포함해 주세요."
        }
        return "로컬 변환 도구 및 번들 엔진 준비 완료"
    }

    /// One line per required executable (location or missing flag) for the pasteable diagnostics text.
    var diagnosticReportLines: [String] {
        func line(_ label: String, _ url: URL?) -> String {
            guard let url else { return "\(label): 누락" }
            return "\(label): \(NASDiagnosticRedaction.redact(url.path))"
        }
        return [
            "도구 출처: \(runtimeSource.rawValue) (빌드 아키텍처 \(Self.compiledArchitecture))",
            line("python3", python3URL),
            line("ffmpeg", ffmpegURL),
            line("ffprobe", ffprobeURL),
            line("도구 폴더", toolsDirURL),
            line("engine_cli.py", engineScriptURL),
            line("worker.py", engineWorkerURL),
            "변환 도구 준비: \(hasRequiredMediaTools ? "예" : "아니오") · 엔진 스크립트 준비: \(hasBundledEngine ? "예" : "아니오")"
        ]
    }

    /// Detects the bundled runtime first, then (development only) standard system locations,
    /// and verifies trusted bundle scripts.
    static func detect(bundle: Bundle = .main) -> NASToolEnvironment {
        let (engineScript, engineWorker) = findBundledEngineScripts(in: bundle)

        if let runtime = findBundledRuntime(in: bundle) {
            return NASToolEnvironment(
                python3URL: runtime.python3,
                ffmpegURL: runtime.ffmpeg,
                ffprobeURL: runtime.ffprobe,
                toolsDirURL: runtime.binDir,
                engineScriptURL: engineScript,
                engineWorkerURL: engineWorker,
                runtimeSource: .bundled
            )
        }

        let toolSearchDirs = [
            "/opt/homebrew/bin", // Apple Silicon Homebrew
            "/usr/local/bin"     // Intel Homebrew / local tools
        ]

        let pythonSearchDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin"
        ]

        let python3 = findExecutable(named: "python3", in: pythonSearchDirs)

        // Find toolsDir where BOTH ffmpeg and ffprobe exist together as regular non-symlink executables
        var toolsDir: URL? = nil
        var ffmpeg: URL? = nil
        var ffprobe: URL? = nil

        let fileManager = FileManager.default
        for dirPath in toolSearchDirs {
            let dirURL = URL(fileURLWithPath: dirPath, isDirectory: true)
            let f1 = dirURL.appendingPathComponent("ffmpeg")
            let f2 = dirURL.appendingPathComponent("ffprobe")
            if fileManager.isExecutableFile(atPath: f1.path) &&
               fileManager.isExecutableFile(atPath: f2.path) {
                toolsDir = dirURL
                ffmpeg = f1
                ffprobe = f2
                break
            }
        }

        return NASToolEnvironment(
            python3URL: python3,
            ffmpegURL: ffmpeg,
            ffprobeURL: ffprobe,
            toolsDirURL: toolsDir,
            engineScriptURL: engineScript,
            engineWorkerURL: engineWorker,
            runtimeSource: (python3 != nil || ffmpeg != nil) ? .system : .none
        )
    }

    /// `Resources/Runtime/<compiled arch>/{bin/ffmpeg, bin/ffprobe, python/bin/python3}` under the absolute bundle
    /// resource root; all three must be executable, otherwise the bundled runtime counts as absent.
    private static func findBundledRuntime(in bundle: Bundle) -> (python3: URL, ffmpeg: URL, ffprobe: URL, binDir: URL)? {
        guard let resourceURL = bundle.resourceURL?.standardizedFileURL, resourceURL.path.hasPrefix("/") else { return nil }
        let root = resourceURL
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent(compiledArchitecture, isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let ffmpeg = binDir.appendingPathComponent("ffmpeg", isDirectory: false)
        let ffprobe = binDir.appendingPathComponent("ffprobe", isDirectory: false)
        let python3 = root
            .appendingPathComponent("python", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("python3", isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ffmpeg.path),
              fileManager.isExecutableFile(atPath: ffprobe.path),
              fileManager.isExecutableFile(atPath: python3.path) else { return nil }
        return (python3, ffmpeg, ffprobe, binDir)
    }

    private static func findExecutable(named name: String, in directories: [String]) -> URL? {
        let fileManager = FileManager.default
        for dir in directories {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Strictly finds both `engine_cli.py` and `worker.py` together within `Resources/ConversionEngine`.
    /// Fallback to directory or main.py is prohibited.
    private static func findBundledEngineScripts(in bundle: Bundle) -> (cli: URL?, worker: URL?) {
        let fileManager = FileManager.default

        // 1. App Bundle Resources
        if let resourceURL = bundle.resourceURL {
            let engineDir = resourceURL.appendingPathComponent("ConversionEngine", isDirectory: true)
            let cli = engineDir.appendingPathComponent("engine_cli.py", isDirectory: false)
            let worker = engineDir.appendingPathComponent("worker.py", isDirectory: false)
            if fileManager.fileExists(atPath: cli.path) && fileManager.fileExists(atPath: worker.path) {
                return (cli, worker)
            }
        }

        // 2. Fallback relative to executable for dev testing
        if let execURL = bundle.executableURL {
            let engineDir = execURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/ConversionEngine", isDirectory: true)
            let cli = engineDir.appendingPathComponent("engine_cli.py", isDirectory: false)
            let worker = engineDir.appendingPathComponent("worker.py", isDirectory: false)
            if fileManager.fileExists(atPath: cli.path) && fileManager.fileExists(atPath: worker.path) {
                return (cli, worker)
            }
        }

        return (nil, nil)
    }
}

// MARK: - Engine NDJSON Models

struct NASEngineProgressLine: Codable, Sendable {
    let type: String
    let schema: Int
    let operation: String
    let job_id: String
    let ref: String?
    let seq: Int
    let elapsed_s: Double?
    let phase: String
    let phase_label: String?
    let phase_pct: Double?
    let phase_pos_s: Double?
    let phase_total_s: Double?
    let phase_done_bytes: Int64?
    let phase_total_bytes: Int64?
}

struct NASEngineResultLine: Codable, Sendable {
    let type: String
    let schema: Int
    let operation: String
    let job_id: String
    let ref: String?
    let status: String
    let code: String
    let message: String
    let elapsed_s: Double?
    let source: FileSummary?
    let output: OutputSummary?
    let candidate: CandidateSummary?
    let timeline: String?
    /// Structured flag from `encode-local`: true when the MP4 was built on a repaired video clock, so the original must be
    /// kept. Callers delete the original only when this is explicitly `false` (absent = keep).
    let retain_original: Bool?

    struct FileSummary: Codable, Sendable {
        let size: Int64
        let sha256: String
    }

    struct OutputSummary: Codable, Sendable {
        let path: String
        let size: Int64
        let sha256: String
    }

    struct CandidateSummary: Codable, Sendable {
        let size: Int64
        let sha256: String
        let duration_s: Double?
    }
}

// MARK: - Engine Errors

enum NASEngineExecutionError: LocalizedError, Equatable {
    case missingEngineScript
    case missingMediaTools
    case lineLimitExceeded
    case invalidOutputLine(String)
    case engineRejected(code: String, message: String)
    case engineFailed(code: String, message: String)
    case processExitedUnexpectedly(code: Int32, stderr: String)
    case outputVerificationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingEngineScript:
            return "변환 엔진 스크립트를 찾을 수 없습니다."
        case .missingMediaTools:
            return "ffmpeg 또는 ffprobe를 찾을 수 없습니다."
        case .lineLimitExceeded:
            return "엔진 출력 줄 한도(64KiB)를 초과하여 작업이 중단되었습니다."
        case .invalidOutputLine(let line):
            return "올바르지 않은 엔진 출력 형식: \(line)"
        case .engineRejected(let code, let msg):
            return "엔진 요청 거부됨 (\(code)): \(msg)"
        case .engineFailed(let code, let msg):
            return "엔진 변환 실패 (\(code)): \(msg)"
        case .processExitedUnexpectedly(let code, let stderr):
            return "엔진 프로세스 비정상 종료 (코드 \(code)): \(stderr)"
        case .outputVerificationFailed(let msg):
            return "출력 파일 검증 실패: \(msg)"
        case .cancelled:
            return "변환 작업이 취소되었습니다."
        }
    }
}

// MARK: - Bounded Process Runner

/// Robust, bounded local process runner.
///
/// Rules:
/// - No sticky cancel bug: each run creates and manages its own execution state.
/// - Line-by-line NDJSON streaming without accumulating unbounded stdout in memory.
/// - Max line limit 64 KiB, max stderr tail limit 8 KiB.
/// - Closes stdin and provides sanitized environment.
/// - Cancels via SIGTERM to engine process PID first, allowing engine to clean up child ffmpeg/ffprobe.
/// - Exactly one valid result line required; process must exit with code 0 for ok.
final class NASBoundedProcessRunner: @unchecked Sendable {
    final class StreamState: @unchecked Sendable {
        let lock = NSLock()
        var currentLineBuffer = Data()
        var stderrData = Data()
        var didExceedLineLimit = false
        var lastSeq: Int = 0
        var finalResult: NASEngineResultLine? = nil
        var multipleResultsFound = false
    }

    static let maxLineBytes: Int = 64 * 1024       // 64 KB per line fail-closed limit
    static let maxStderrTailBytes: Int = 8 * 1024  // 8 KB tail of stderr

    private let lock = NSLock()
    private var activeProcess: Process?

    init() {}

    /// Executes an engine command line directly without a shell.
    func runEngine(
        python3URL: URL,
        engineScriptURL: URL,
        operation: String,
        requestFileURL: URL,
        toolsDirURL: URL?,
        expectedJobID: String,
        expectedRef: String,
        onProgress: (@Sendable (NASEngineProgressLine) -> Void)? = nil
    ) async throws -> NASEngineResultLine {
        try Task.checkCancellation()

        // Keep the signed app bundle read-only when Python imports its bundled modules.
        var arguments = ["-I", "-B", engineScriptURL.path, operation, "--request", requestFileURL.path]
        if let toolsDirURL {
            arguments.append(contentsOf: ["--tools-dir", toolsDirURL.path])
        }

        let process = Process()
        process.executableURL = python3URL
        process.arguments = arguments

        // Sanitized environment
        var env: [String: String] = [
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "HOME": NSHomeDirectory()
        ]
        if let toolsDirURL {
            env["PATH"] = toolsDirURL.path
        }
        process.environment = env

        // Close stdin
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.lock()
        if Task.isCancelled {
            lock.unlock()
            throw CancellationError()
        }
        activeProcess = process
        lock.unlock()

        defer {
            lock.lock()
            activeProcess = nil
            lock.unlock()
        }

        let state = StreamState()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        let expectedJobLower = expectedJobID.lowercased()

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            state.lock.lock()
            defer { state.lock.unlock() }

            var chunkToScan = chunk
            while let newlineIndex = chunkToScan.firstIndex(of: UInt8(ascii: "\n")) {
                let lineSegment = chunkToScan[..<newlineIndex]
                chunkToScan = chunkToScan[chunkToScan.index(after: newlineIndex)...]

                if state.currentLineBuffer.count + lineSegment.count > NASBoundedProcessRunner.maxLineBytes {
                    state.didExceedLineLimit = true
                    return
                }
                state.currentLineBuffer.append(lineSegment)

                do {
                    let lineData = state.currentLineBuffer
                    Self.parseAndHandleLine(
                        lineData: lineData,
                        expectedJobID: expectedJobLower,
                        expectedRef: expectedRef,
                        expectedOperation: operation,
                        state: state,
                        onProgress: onProgress
                    )
                }
                state.currentLineBuffer.removeAll(keepingCapacity: true)
            }

            if !chunkToScan.isEmpty {
                if state.currentLineBuffer.count + chunkToScan.count > NASBoundedProcessRunner.maxLineBytes {
                    state.didExceedLineLimit = true
                } else {
                    state.currentLineBuffer.append(chunkToScan)
                }
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            state.lock.lock()
            defer { state.lock.unlock() }

            state.stderrData.append(chunk)
            if state.stderrData.count > NASBoundedProcessRunner.maxStderrTailBytes {
                let overflow = state.stderrData.count - NASBoundedProcessRunner.maxStderrTailBytes
                state.stderrData.removeSubrange(0..<overflow)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            throw error
        }

        await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                process.waitUntilExit()
            }.value
        } onCancel: {
            self.sendSigtermToActiveProcess()
        }

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        // Flush remaining buffer if any
        state.lock.lock()
        if !state.currentLineBuffer.isEmpty && !state.didExceedLineLimit {
            Self.parseAndHandleLine(
                lineData: state.currentLineBuffer,
                expectedJobID: expectedJobLower,
                expectedRef: expectedRef,
                expectedOperation: operation,
                state: state,
                onProgress: onProgress
            )
            state.currentLineBuffer.removeAll()
        }
        let lineExceeded = state.didExceedLineLimit
        let finalResult = state.finalResult
        let multipleResults = state.multipleResultsFound
        let stderrTail = String(data: state.stderrData, encoding: .utf8) ?? ""
        state.lock.unlock()

        if lineExceeded {
            throw NASEngineExecutionError.lineLimitExceeded
        }

        if multipleResults {
            throw NASEngineExecutionError.invalidOutputLine("복수의 결과(result) 라인이 출력되었습니다.")
        }

        try Task.checkCancellation()

        let exitCode = process.terminationStatus
        if exitCode == 3 {
            throw NASEngineExecutionError.cancelled
        }

        guard let result = finalResult else {
            throw NASEngineExecutionError.processExitedUnexpectedly(code: exitCode, stderr: stderrTail)
        }

        if exitCode != 0 || result.status != "ok" {
            if result.status == "rejected" {
                throw NASEngineExecutionError.engineRejected(code: result.code, message: result.message)
            }
            if result.status == "cancelled" {
                throw NASEngineExecutionError.cancelled
            }
            throw NASEngineExecutionError.engineFailed(code: result.code, message: result.message)
        }

        return result
    }

    private static func parseAndHandleLine(
        lineData: Data,
        expectedJobID: String,
        expectedRef: String,
        expectedOperation: String,
        state: StreamState,
        onProgress: (@Sendable (NASEngineProgressLine) -> Void)?
    ) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = jsonObject["type"] as? String else {
            return
        }

        if type == "progress" {
            if let progress = try? JSONDecoder().decode(NASEngineProgressLine.self, from: lineData) {
                guard progress.schema == 1,
                      progress.operation == expectedOperation,
                      progress.job_id.lowercased() == expectedJobID,
                      progress.ref == expectedRef,
                      progress.seq > state.lastSeq else {
                    return
                }
                // Verify finite percentage in 0...100 if present
                if let pct = progress.phase_pct, (!pct.isFinite || pct < 0.0 || pct > 100.0) {
                    return
                }
                state.lastSeq = progress.seq
                onProgress?(progress)
            }
        } else if type == "result" {
            if let result = try? JSONDecoder().decode(NASEngineResultLine.self, from: lineData) {
                guard result.schema == 1,
                      result.operation == expectedOperation,
                      result.job_id.lowercased() == expectedJobID,
                      result.ref == expectedRef else {
                    return
                }
                if state.finalResult != nil {
                    state.multipleResultsFound = true
                }
                state.finalResult = result
            }
        }
    }

    /// Sends SIGTERM to the active engine process PID.
    /// Engine catches SIGTERM and gracefully terminates its own child ffmpeg/ffprobe processes.
    func sendSigtermToActiveProcess() {
        lock.lock()
        defer { lock.unlock() }
        guard let proc = activeProcess, proc.isRunning else { return }
        kill(proc.processIdentifier, SIGTERM)
    }

    func terminate() {
        sendSigtermToActiveProcess()
    }
}

// MARK: - Engine Bridge Protocol and Implementation

protocol NASConversionEngineBridging: Sendable {
    func checkReadiness(environment: NASToolEnvironment) -> String

    func encodeLocal(
        environment: NASToolEnvironment,
        workspaceRoot: URL,
        jobID: String,
        ref: String,
        sourceLocalRelativePath: String,
        sourceExt: String,
        sourceExpectedSize: Int64,
        sourceExpectedSha256: String,
        outputRelativePath: String,
        allowClockRecovery: Bool,
        onProgress: (@Sendable (NASEngineProgressLine) -> Void)?
    ) async throws -> NASEngineResultLine

    func cancel(jobID: String)
    /// Terminates only the engine run of one attempt (parallel attempts of the same NAS job stay untouched).
    func cancel(ref: String)
    func cancelAll()
}

final class DefaultNASConversionEngineBridge: NASConversionEngineBridging {
    private let lock = NSLock()
    /// Keyed by `ref` (epoch + item): unique per concurrently running attempt, even inside the same NAS job.
    private var activeRunners: [String: (jobID: String, runner: NASBoundedProcessRunner)] = [:]

    init() {}

    func checkReadiness(environment: NASToolEnvironment) -> String {
        environment.diagnosticMessage
    }

    func encodeLocal(
        environment: NASToolEnvironment,
        workspaceRoot: URL,
        jobID: String,
        ref: String,
        sourceLocalRelativePath: String,
        sourceExt: String,
        sourceExpectedSize: Int64,
        sourceExpectedSha256: String,
        outputRelativePath: String,
        allowClockRecovery: Bool = false,
        onProgress: (@Sendable (NASEngineProgressLine) -> Void)?
    ) async throws -> NASEngineResultLine {
        guard let python3 = environment.python3URL else {
            throw NASEngineExecutionError.missingMediaTools
        }
        guard let cli = environment.engineScriptURL, environment.hasBundledEngine else {
            throw NASEngineExecutionError.missingEngineScript
        }

        // The workspace root must already be its own realpath (no /var -> /private/var alias, no symlink);
        // every request/input/output path below derives from this exact string.
        let canonicalRoot = try NASPathSecurity.realpathURL(of: workspaceRoot)
        guard try canonicalRoot.path == NASPathSecurity.exactAbsolutePath(of: workspaceRoot) else {
            throw NASHelperTransportError.unsafeSymlinkDetected(workspaceRoot.path)
        }
        let fileManager = FileManager.default

        // Create 0600 request file inside private 0700 workspace
        let requestFileURL = canonicalRoot.appendingPathComponent("job_\(jobID).json", isDirectory: false)

        var requestDict: [String: Any] = [
            "schema": 1,
            "operation": "encode-local",
            "job_id": jobID.lowercased(),
            "ref": ref,
            "root": canonicalRoot.path,
            "source": [
                "path": sourceLocalRelativePath,
                "ext": sourceExt,
                "size": sourceExpectedSize,
                "sha256": sourceExpectedSha256.lowercased()
            ],
            "output": [
                "path": outputRelativePath
            ]
        ]

        if allowClockRecovery {
            requestDict["allow_clock_recovery"] = true  // sent only by the local Mac flow; absent = recovery off
        }

        let requestData = try JSONSerialization.data(withJSONObject: requestDict, options: [.sortedKeys])
        guard requestData.count <= 64 * 1024 else {
            throw NASWireValidationError.invalidJSON("요청 JSON 크기 64KiB 초과")
        }

        if fileManager.fileExists(atPath: requestFileURL.path) {
            try? fileManager.removeItem(at: requestFileURL)
        }
        fileManager.createFile(atPath: requestFileURL.path, contents: requestData, attributes: [.posixPermissions: 0o600])

        // Ensure output parent directory exists and output file does not exist
        let outputURL = canonicalRoot.appendingPathComponent(outputRelativePath, isDirectory: false)
        let outputParent = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputParent, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        defer {
            try? fileManager.removeItem(at: requestFileURL)
        }

        // Dedicated runner for this job execution (eliminates runner reuse sticky-cancel bugs)
        let runner = NASBoundedProcessRunner()
        lock.lock()
        activeRunners[ref] = (jobID: jobID, runner: runner)
        lock.unlock()

        defer {
            lock.lock()
            if activeRunners[ref]?.runner === runner {
                activeRunners.removeValue(forKey: ref)
            }
            lock.unlock()
        }

        let result = try await runner.runEngine(
            python3URL: python3,
            engineScriptURL: cli,
            operation: "encode-local",
            requestFileURL: requestFileURL,
            toolsDirURL: environment.toolsDirURL,
            expectedJobID: jobID,
            expectedRef: ref,
            onProgress: onProgress
        )

        // Verify output file exists, matches result size and sha256
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw NASEngineExecutionError.outputVerificationFailed("엔진 출력 파일이 존재하지 않습니다: \(outputURL.path)")
        }

        let values = try withFileErrorPhase("엔진 출력 크기 확인") { try outputURL.resourceValues(forKeys: [.fileSizeKey]) }
        let actualSize = Int64(values.fileSize ?? 0)

        guard let outputSummary = result.output, outputSummary.size == actualSize else {
            throw NASEngineExecutionError.outputVerificationFailed("출력 파일 크기 불일치: 기대 \(result.output?.size ?? -1), 실제 \(actualSize)")
        }

        // Verify SHA-256 of generated output
        let handle = try withFileErrorPhase("엔진 출력 SHA-256 검증용 열기") { try FileHandle(forReadingFrom: outputURL) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 512 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.lowercased() == outputSummary.sha256.lowercased() else {
            throw NASEngineExecutionError.outputVerificationFailed("출력 파일 SHA-256 불일치: 기대 \(outputSummary.sha256), 실제 \(digest)")
        }

        return result
    }

    func cancel(jobID: String) {
        lock.lock()
        let runners = activeRunners.values.filter { $0.jobID == jobID }.map(\.runner)
        lock.unlock()
        for runner in runners {
            runner.terminate()
        }
    }

    func cancel(ref: String) {
        lock.lock()
        let runner = activeRunners[ref]?.runner
        lock.unlock()
        runner?.terminate()
    }

    func cancelAll() {
        lock.lock()
        let runners = activeRunners.values.map(\.runner)
        lock.unlock()
        for runner in runners {
            runner.terminate()
        }
    }
}


/// Runs a local file operation; a failure keeps its plain message and appends the phase plus NSError domain/code and the
/// underlying error chain (e.g. a bare "파일을 열 수 없습니다." is NSCocoaErrorDomain 256 over a POSIX errno), so the failing site is identifiable.
func withFileErrorPhase<T>(_ phase: String, _ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as NSError {
        var chain = ["\(error.domain) \(error.code)"]
        var underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        while let u = underlying, chain.count < 4 {
            chain.append("\(u.domain) \(u.code)")
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        var info = error.userInfo
        info[NSLocalizedDescriptionKey] = "\(error.localizedDescription) [진단: \(phase), \(chain.joined(separator: " ← "))]"
        info[NSUnderlyingErrorKey] = error
        throw NSError(domain: error.domain, code: error.code, userInfo: info)
    }
}
