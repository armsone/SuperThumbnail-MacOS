import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class LocalSourceCopyTests: XCTestCase {
    private var directory: URL!
    private var sourceURL: URL!
    private var destURL: URL!
    private var sourceFD: Int32 = -1
    private let payload = Data((0..<1000).map { UInt8(($0 * 7 + 3) % 251) })

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("source-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("source.bin")
        destURL = directory.appendingPathComponent("copy.bin")
        try payload.write(to: sourceURL)
        sourceFD = open(sourceURL.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(sourceFD, 0)
    }

    override func tearDownWithError() throws {
        if sourceFD >= 0 { close(sourceFD) }
        if let destURL { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path) }
        try? FileManager.default.removeItem(at: directory)
    }

    private final class ReadScript {
        var calls = 0
        let inject: (Int) -> Int32 /* errno to inject for the 1-based call, 0 = real read */
        init(_ inject: @escaping (Int) -> Int32) { self.inject = inject }
    }

    private func hooks(_ script: ReadScript) -> LocalSourceCopier.Hooks {
        var hooks = LocalSourceCopier.Hooks()
        hooks.read = { fd, buffer, count in
            script.calls += 1
            let e = script.inject(script.calls)
            if e == 0 { return Darwin.read(fd, buffer, count) }
            errno = e
            return -1
        }
        return hooks
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func copy(_ hooks: LocalSourceCopier.Hooks, to dest: URL? = nil) throws -> (sha256: String, copiedBytes: Int64) {
        try LocalSourceCopier.copy(
            sourceFD: sourceFD, to: dest ?? destURL, fileSize: Int64(payload.count), chunkSize: 300,
            hooks: hooks, onProgress: { _, _ in }
        )
    }

    private func assertSourceIntact(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: sourceURL), payload, file: file, line: line)
    }

    func testPlainCopyMatchesSizeAndHashAndIsReadOnly() throws {
        let script = ReadScript { _ in 0 }
        let result = try copy(hooks(script))
        XCTAssertEqual(result.copiedBytes, Int64(payload.count))
        XCTAssertEqual(result.sha256, sha(payload))
        XCTAssertEqual(try Data(contentsOf: destURL), payload)
        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o400)
    }

    func testEINTRThenSuccessDoesNotDuplicateOrDropBytes() throws {
        // Interrupt before the first read, and twice in a row in the middle of the file.
        let script = ReadScript { call in [1, 3, 4].contains(call) ? EINTR : 0 }
        let result = try copy(hooks(script))
        XCTAssertEqual(result.copiedBytes, Int64(payload.count))
        XCTAssertEqual(result.sha256, sha(payload))
        XCTAssertEqual(try Data(contentsOf: destURL), payload)
        XCTAssertEqual(script.calls, 4 + 3 + 1) // 4 real chunks (300,300,300,100) + EOF read, plus 3 interrupted attempts
    }

    func testRepeatedEINTRIsBoundedAndReportsPhaseErrnoAndOffset() throws {
        let script = ReadScript { call in call == 1 ? 0 : EINTR }
        XCTAssertThrowsError(try copy(hooks(script))) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(ns.code, Int(EINTR))
            XCTAssertTrue(ns.localizedDescription.contains("errno 4"), ns.localizedDescription)
            XCTAssertTrue(ns.localizedDescription.contains("3회 재시도"), ns.localizedDescription)
            XCTAssertTrue(ns.localizedDescription.contains("원본 복사 읽기 (offset 300/1000)"), ns.localizedDescription)
        }
        XCTAssertEqual(script.calls, 1 + 1 + LocalSourceCopier.maxReadInterruptRetries)
        XCTAssertEqual(try Data(contentsOf: destURL), payload.prefix(300)) // only the successfully read chunk was written
        try assertSourceIntact()
    }

    func testPermanentErrorsFailImmediatelyWithoutRetry() throws {
        for code in [EIO, EBUSY, EAGAIN, ETIMEDOUT, ESTALE] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path)
            let script = ReadScript { call in call == 2 ? code : 0 }
            XCTAssertThrowsError(try copy(hooks(script)), "errno \(code)") { error in
                let ns = error as NSError
                XCTAssertEqual(ns.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(ns.code, Int(code))
                XCTAssertTrue(ns.localizedDescription.contains("errno \(code)"), ns.localizedDescription)
                XCTAssertTrue(ns.localizedDescription.contains("원본 복사 읽기 (offset 300/1000)"), ns.localizedDescription)
                XCTAssertEqual(ns.localizedDescription.components(separatedBy: "[진단:").count - 1, 1, ns.localizedDescription)
            }
            XCTAssertEqual(script.calls, 2, "errno \(code) must not be retried")
            XCTAssertEqual(try Data(contentsOf: destURL), payload.prefix(300))
        }
        try assertSourceIntact()
    }

    func testCancellationIsCheckedBeforeFirstAttempt() async throws {
        let script = ReadScript { _ in 0 }
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do { _ = try copy(hooks(script)) } catch is CancellationError { return true }
            return false
        }
        task.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(script.calls, 0)
        try assertSourceIntact()
    }

    func testCancellationStopsBeforeTheNextEINTRRetry() async throws {
        let script = ReadScript { call in
            if call == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            return EINTR
        }
        let task = Task { () -> Bool in
            do { _ = try copy(hooks(script)) } catch is CancellationError { return true } catch { return false }
            return false
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(script.calls, 1) // no second attempt after cancellation
        try assertSourceIntact()
    }

    func testWriteFailureKeepsSourceAndReportsPhaseAndUnderlyingErrno() throws {
        var failing = hooks(ReadScript { _ in 0 })
        var writes = 0
        failing.write = { handle, data in
            writes += 1
            if writes == 2 {
                throw NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                ])
            }
            try handle.write(contentsOf: data)
        }
        XCTAssertThrowsError(try copy(failing)) { error in
            let text = (error as NSError).localizedDescription
            XCTAssertTrue(text.contains("원본 복사 쓰기 (offset 300/1000)"), text)
            XCTAssertTrue(text.contains("NSCocoaErrorDomain 640 ← NSPOSIXErrorDomain \(ENOSPC)"), text)
            XCTAssertEqual(text.components(separatedBy: "[진단:").count - 1, 1, text)
        }
        XCTAssertEqual(writes, 2)
        try assertSourceIntact()
        XCTAssertEqual(try Data(contentsOf: destURL), payload.prefix(300))
    }

    func testDestinationCreateFailureIsCheckedWithPhaseAndErrno() throws {
        let missing = directory.appendingPathComponent("no-such-dir/copy.bin")
        XCTAssertThrowsError(try copy(hooks(ReadScript { _ in 0 }), to: missing)) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(ns.code, Int(ENOENT))
            XCTAssertTrue(ns.localizedDescription.contains("원본 복사 대상 생성"), ns.localizedDescription)
        }
        try assertSourceIntact()
    }

    func testPhaseWrapperKeepsInnerPhaseAndCancellation() throws {
        XCTAssertThrowsError(try withFileErrorPhase("바깥") {
            try withFileErrorPhase("안쪽") { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
        }) { error in
            let text = (error as NSError).localizedDescription
            XCTAssertTrue(text.contains("안쪽"), text)
            XCTAssertFalse(text.contains("바깥"), text)
            XCTAssertEqual(text.components(separatedBy: "[진단:").count - 1, 1, text)
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
        XCTAssertThrowsError(try withFileErrorPhase("x") { throw CancellationError() }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testFallbackMessageKeepsDomainCodeChainWithoutDuplicatingPhase() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        let outer = NSError(domain: NSCocoaErrorDomain, code: 256, userInfo: [NSUnderlyingErrorKey: underlying])
        let text = fileErrorFallbackMessage(outer)
        XCTAssertTrue(text.contains("NSCocoaErrorDomain 256 ← NSPOSIXErrorDomain \(EIO)"), text)
        let wrapped = fileErrorAddingPhase(outer, phase: "단계")
        let again = fileErrorFallbackMessage(wrapped)
        XCTAssertEqual(again, wrapped.localizedDescription)
        XCTAssertEqual(again.components(separatedBy: "[진단:").count - 1, 1, again)
    }
}
