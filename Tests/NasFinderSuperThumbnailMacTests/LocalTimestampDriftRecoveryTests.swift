import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import NasFinderSuperThumbnailMac

/// Timestamp-only drift of the original (a WebDAV mount shows other mtime/ctime for an unchanged file): the attempt may continue
/// only as a retained-only attempt after the SAME locked descriptor was re-hashed. Everything runs on owned local fixtures;
/// `assumeWebDAVSource` is the test seam that runs the webdav branch on a local directory (a real time change is made with utimes).
final class LocalTimestampDriftRecoveryTests: XCTestCase {
    private var directory: URL!
    private var workspace: URL!
    private var releaseOnTearDown: [() -> Void] = []

    private let attemptID = "f6851a2f-e2a9-4ebf-ae26-9edefafb7916"
    private let sourceBytes = Data((0..<4096).map { UInt8($0 % 251) })
    private let engineBytes = Data("engine-output-mp4-bytes".utf8)
    private let oldTime: Int = 1_282_564_372
    private let driftTime: Int = 1_787_670_834

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = base.appendingPathComponent("ts-drift-\(UUID().uuidString)", isDirectory: true)
        workspace = base.appendingPathComponent("ts-drift-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try sourceBytes.write(to: path("clip.avi"))
        setTimes("clip.avi", oldTime)
        try engineBytes.write(to: workspace.appendingPathComponent("engine.mp4"))
    }

    override func tearDownWithError() throws {
        releaseOnTearDown.reversed().forEach { $0() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: helpers

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private var engineURL: URL { workspace.appendingPathComponent("engine.mp4") }
    private var vaultURL: URL { directory.appendingPathComponent(LocalConversionConstants.vaultDirName, isDirectory: true) }

    private func setTimes(_ name: String, _ seconds: Int) {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(path(name).path, &times), 0)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func lockAndClaim() throws -> (lock: LocalFileLock, claim: VideoConversionClaim) {
        let parentFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        let fd = openat(parentFD, "clip.avi", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let lock = try LocalFileLockManager.shared.acquireLock(parentFD: parentFD, fd: fd, fileName: "clip.avi", relativeComponents: ["clip.avi"])
        let claim = try VideoConversionClaim.acquire(
            parentFD: lock.parentFD, sourceName: "clip.avi", outputName: "clip.mp4", backupName: "clip_원본.avi", sourceIdentity: lock.identity
        )
        releaseOnTearDown.append { _ = claim.release(success: false); lock.unlock() }
        return (lock, claim)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func publish(
        _ lock: LocalFileLock, _ claim: VideoConversionClaim, sha: String? = nil, proof: LocalSourceDriftProof? = nil,
        attempt: String? = nil, assumeWebDAV: Bool = true, intent: LocalRetainedOriginalReason? = nil,
        onCopy: (@Sendable (Double) -> Void)? = nil, onRecheck: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> LocalPublishedMP4 {
        try LocalPublicationManager.publishMP4(
            sourceLock: lock,
            engineOutputURL: engineURL,
            outputExpectedSize: Int64(engineBytes.count),
            outputExpectedSha256: sha256(engineBytes),
            attemptID: attempt ?? attemptID,
            claim: claim,
            sourceSha256: sha,
            driftProof: proof,
            retentionIntent: intent,
            assumeWebDAVSource: assumeWebDAV,
            onCopyProgress: onCopy,
            onSourceRecheckProgress: onRecheck
        )
    }

    /// Counts how often the original was re-read (each full re-hash reports once for the 4 KiB fixture) and keeps the numbers.
    private final class RecheckLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Int64, Int64)] = []
        func add(_ done: Int64, _ total: Int64) { lock.lock(); items.append((done, total)); lock.unlock() }
        var values: [(Int64, Int64)] { lock.lock(); defer { lock.unlock() }; return items }
        var count: Int { values.count }
    }

    private func prove(
        _ lock: LocalFileLock, _ claim: VideoConversionClaim, sha: String? = nil, assumeWebDAV: Bool = true
    ) throws -> LocalSourceDriftProof {
        try LocalPublicationManager.proveSourceTimestampDrift(
            sourceLock: lock, sourceSha256: sha ?? sha256(sourceBytes), claim: claim, attemptID: attemptID,
            assumeWebDAVSource: assumeWebDAV
        )
    }

    private func validJPEGData() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// Thumbnail for the published clip.mp4: a valid JPEG pre-placed at the exact Vault key (no media decoding in tests).
    private func thumbnail(for published: LocalPublishedMP4, lock: LocalFileLock) async throws -> LocalPublishedThumbnail {
        let finalURL = path(published.finalFileName)
        let values = try URL(fileURLWithPath: finalURL.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = NasFinderVaultCompatibility.thumbnailFilename(
            name: finalURL.lastPathComponent, size: Int64(try XCTUnwrap(values.fileSize)), modifiedAt: try XCTUnwrap(values.contentModificationDate)
        )
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try validJPEGData().write(to: vaultURL.appendingPathComponent(key))
        return try await LocalPublicationManager.createVerifiedThumbnail(sourceLock: lock, published: published, finalURL: finalURL)
    }

    private func readJournal(_ state: String) throws -> LocalJournalRecord {
        let data = try Data(contentsOf: path(".clip.journal-\(attemptID)-\(state).json"))
        return try JSONDecoder().decode(LocalJournalRecord.self, from: data)
    }

    private func assertOriginalUntouched(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: path("clip.avi")), sourceBytes, file: file, line: line)
    }

    // MARK: same bytes, only times changed

    func testTimestampOnlyDriftWithSameBytesPublishesThumbnailsAndRetainsOriginal() async throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)

        // Times move after the copy: same dev/inode/size, different mtime/ctime.
        setTimes("clip.avi", driftTime)
        let drifted = try LocalFileIdentity.inspect(fd: lock.fd)
        XCTAssertTrue(drifted.isTimestampOnlyDrift(from: lock.identity))

        let proof = try prove(lock, claim)
        XCTAssertTrue(proof.observedFD.isTimestampOnlyDrift(from: lock.identity))
        XCTAssertTrue(proof.observedEntry.isTimestampOnlyDrift(from: lock.identity))
        XCTAssertEqual(proof.claimToken, claim.token)
        XCTAssertTrue(proof.isBound(to: lock, claim: claim, attemptID: attemptID, sourceSha256: sha))

        let published = try publish(lock, claim, sha: sha, proof: proof)
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
        XCTAssertEqual(try Data(contentsOf: path("clip.mp4")), engineBytes)
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .sourceTimestampOnlyDrift)
        let left = try names()
        XCTAssertFalse(left.contains { $0.contains(".stage-") || $0.contains("-staged.json") }, "\(left)")

        let thumb = try await thumbnail(for: published, lock: lock)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path), [thumb.fileName])

        // Deletion is unreachable for a retained-only attempt, also when the times are put back.
        setTimes("clip.avi", oldTime)
        XCTAssertThrowsError(try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: published, thumbnail: thumb, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        )) { XCTAssertEqual(($0 as NSError).code, 55) }
        try assertOriginalUntouched()
        XCTAssertEqual(try Data(contentsOf: path("clip.mp4")), engineBytes)
        XCTAssertTrue(try names().contains(".clip.journal-\(attemptID)-published.json"))
        XCTAssertFalse(try names().contains { $0.contains("-deleting.json") })
    }

    func testTimesChangingOnlyLaterBeforePublicationAreProvenInsidePublishAndRetainTheOriginal() throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        // Exact at the copy (no proof), then the mount shows other times right before publication.
        setTimes("clip.avi", driftTime)

        let published = try publish(lock, claim, sha: sha, proof: nil)
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .sourceTimestampOnlyDrift)
        XCTAssertEqual(try Data(contentsOf: path("clip.mp4")), engineBytes)
        try assertOriginalUntouched()
    }

    // MARK: proof reuse and progress

    func testBoundProofWithExactlyTheObservedIdentityIsReusedAndNeverRehashedInsidePublish() throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        setTimes("clip.avi", driftTime)
        let proof = try prove(lock, claim)
        let log = RecheckLog()
        let published = try publish(lock, claim, sha: sha, proof: proof, onRecheck: { log.add($0, $1) })
        XCTAssertEqual(log.count, 0, "unchanged observed fd+entry: both checks reuse the proof")
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .sourceTimestampOnlyDrift)
        try assertOriginalUntouched()
    }

    func testLateDriftIsHashedOnceAndTheSameProofCoversTheCheckBeforeTheRename() throws {
        let (lock, claim) = try lockAndClaim()
        setTimes("clip.avi", driftTime)
        let log = RecheckLog()
        let published = try publish(lock, claim, sha: sha256(sourceBytes), onRecheck: { log.add($0, $1) })
        XCTAssertEqual(log.count, 1, "one hash for the first check, the check before the rename reuses it")
        XCTAssertEqual(log.values.last?.0, Int64(sourceBytes.count))
        XCTAssertEqual(log.values.last?.1, Int64(sourceBytes.count))
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
    }

    func testObservedIdentityChangingAfterTheProofForcesANewHashAndRetentionStaysSticky() throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        setTimes("clip.avi", driftTime)
        let proof = try prove(lock, claim)
        let log = RecheckLog()
        // While the output is copied the mount shows yet other times (same dev/inode/size, but not what the proof observed).
        let published = try publish(
            lock, claim, sha: sha, proof: proof,
            onCopy: { [self] _ in setTimes("clip.avi", driftTime + 77) }, onRecheck: { log.add($0, $1) }
        )
        XCTAssertEqual(log.count, 1, "different times than the proof observed: re-proven, not reused")
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)

        // Exact again afterwards: still retained-only (sticky), deletion refused.
        setTimes("clip.avi", oldTime)
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .sourceTimestampOnlyDrift)
        try assertOriginalUntouched()
    }

    func testReasonFoundOnlyRightBeforeTheRenameIsPersistedInTheJournalAndNothingStrayRemains() throws {
        let (lock, claim) = try lockAndClaim()
        let log = RecheckLog()
        // Exact at the first check; the mount shows other times only after the staged journal was written.
        let published = try publish(
            lock, claim, sha: sha256(sourceBytes),
            onCopy: { [self] _ in setTimes("clip.avi", driftTime) }, onRecheck: { log.add($0, $1) }
        )
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(published.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .sourceTimestampOnlyDrift)
        let left = try names()
        XCTAssertFalse(left.contains { $0.contains(".stage-") || $0.contains("-staged.json") || $0.contains(".tmp-") }, "\(left)")
        XCTAssertEqual(try Data(contentsOf: path("clip.mp4")), engineBytes)
        try assertOriginalUntouched()
    }

    func testHashProgressReportsActualBytesAndTotalMonotonically() throws {
        let big = Data((0..<(3 * 512 * 1024 + 123)).map { UInt8($0 % 241) })
        let url = path("big.bin")
        try big.write(to: url)
        let fd = open(url.path, O_RDONLY)
        defer { Darwin.close(fd) }
        let log = RecheckLog()
        let result = try LocalPublicationManager.sha256Streaming(fd: fd, expectedTotal: Int64(big.count)) { log.add($0, $1) }
        XCTAssertEqual(result.bytes, Int64(big.count))
        XCTAssertEqual(result.digest, sha256(big))
        let values = log.values
        XCTAssertGreaterThanOrEqual(values.count, 2)
        XCTAssertTrue(values.allSatisfy { $0.1 == Int64(big.count) && $0.0 > 0 && $0.0 <= $0.1 })
        XCTAssertEqual(values.map { $0.0 }, values.map { $0.0 }.sorted())
        XCTAssertEqual(values.last?.0, Int64(big.count))
    }

    func testCopySizeRetryIntentIsPersistedAndDeniesDeletion() async throws {
        let (lock, claim) = try lockAndClaim()
        let published = try publish(lock, claim, sha: sha256(sourceBytes), proof: nil, intent: .copySizeRetry)
        XCTAssertEqual(published.record.retainedOriginalReason, .copySizeRetry)
        // Persisted in the published journal; the encode/decode round trip keeps the distinct reason.
        XCTAssertEqual(try readJournal("published").retainedOriginalReason, .copySizeRetry)
        XCTAssertEqual(try readJournal("published"), published.record)
        XCTAssertEqual(LocalRetainedOriginalReason(rawValue: "copy_size_retry"), .copySizeRetry)

        let thumb = try await thumbnail(for: published, lock: lock)
        XCTAssertThrowsError(try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: published, thumbnail: thumb, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        )) { XCTAssertEqual(($0 as NSError).code, 55) }
        try assertOriginalUntouched()
    }

    func testCopySizeRetryIntentIsNotATimestampProof() throws {
        let (lock, claim) = try lockAndClaim()
        setTimes("clip.avi", driftTime)
        // Without a bound content proof (here no captured hash) a time difference is rejected exactly as for a normal attempt.
        XCTAssertThrowsError(try publish(lock, claim, sha: nil, proof: nil, intent: .copySizeRetry)) {
            XCTAssertEqual(($0 as NSError).code, 13)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.mp4").path))
        try assertOriginalUntouched()
    }

    func testNormalAttemptStillMayDeleteTheVerifiedOriginal() async throws {
        let (lock, claim) = try lockAndClaim()
        let published = try publish(lock, claim, sha: sha256(sourceBytes), proof: nil)
        XCTAssertNil(published.record.retainedOriginalReason)
        let thumb = try await thumbnail(for: published, lock: lock)
        try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: published, thumbnail: thumb, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.avi").path))
    }

    func testRetainedMessageIsPlainLanguage() {
        let message = LocalRetainedOriginalReason.sourceTimestampOnlyDrift.userMessage
        XCTAssertFalse(message.contains("SHA"))
        XCTAssertFalse(message.contains("WebDAV"))
        XCTAssertTrue(message.contains("원본 파일 정보") && message.contains("내용") && message.contains("그대로"))
    }

    func testNormalPublicationStaysExactAndHasNoRetentionReason() throws {
        let (lock, claim) = try lockAndClaim()
        let published = try publish(lock, claim, sha: sha256(sourceBytes), proof: nil)
        XCTAssertNil(published.record.retainedOriginalReason)
        XCTAssertNil(try readJournal("published").retainedOriginalReason)

        // Without the captured hash (no proof capability) a time difference is still rejected exactly as before.
        let other = try makeSecondDirectoryLock()
        setTimes2(other.dir, "clip.avi", driftTime)
        XCTAssertThrowsError(try LocalPublicationManager.publishMP4(
            sourceLock: other.lock, engineOutputURL: engineURL, outputExpectedSize: Int64(engineBytes.count),
            outputExpectedSha256: sha256(engineBytes), attemptID: attemptID, claim: other.claim
        )) { XCTAssertEqual(($0 as NSError).code, 13) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.dir.path).filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])
    }

    func testTimeDifferenceOnANonWebDAVSourceIsRejectedWithoutAnyPublication() throws {
        let (lock, claim) = try lockAndClaim()
        setTimes("clip.avi", driftTime)
        XCTAssertThrowsError(try prove(lock, claim, assumeWebDAV: false)) { XCTAssertEqual(($0 as NSError).code, 71) }
        XCTAssertThrowsError(try publish(lock, claim, sha: sha256(sourceBytes), assumeWebDAV: false)) { XCTAssertEqual(($0 as NSError).code, 71) }
        XCTAssertEqual(try names().filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])
        try assertOriginalUntouched()
    }

    // MARK: rejected: bytes / object / ownership / binding

    func testSameSizeChangedBytesAreRejectedEverywhereAndNothingIsPublished() throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        // In-place rewrite: same inode, same size, other bytes (this also moves the times).
        let tampered = Data(repeating: 0x41, count: sourceBytes.count)
        let handle = try FileHandle(forWritingTo: path("clip.avi"))
        try handle.write(contentsOf: tampered)
        try handle.close()
        setTimes("clip.avi", driftTime)

        XCTAssertThrowsError(try prove(lock, claim)) { XCTAssertEqual(($0 as NSError).code, 74) }
        XCTAssertThrowsError(try publish(lock, claim, sha: sha)) { XCTAssertEqual(($0 as NSError).code, 74) }
        XCTAssertEqual(try names().filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
        XCTAssertEqual(try Data(contentsOf: path("clip.avi")), tampered, "the original is only read, never rewritten")
    }

    func testSizeChangeAndNamePathSwapAreRejected() throws {
        // Size change (append): not the same file object.
        do {
            let (lock, claim) = try lockAndClaim()
            let handle = try FileHandle(forWritingTo: path("clip.avi"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([1]))
            try handle.close()
            XCTAssertThrowsError(try prove(lock, claim)) { XCTAssertEqual(($0 as NSError).code, 72) }
            XCTAssertThrowsError(try publish(lock, claim, sha: sha256(sourceBytes)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.mp4").path))
        }
    }

    func testPathSwapToAnotherInodeWithTheSameBytesIsRejected() throws {
        let (lock, claim) = try lockAndClaim()
        // A different file with identical bytes and size takes the name; the locked descriptor still points to the old inode.
        let swap = path("swap.tmp")
        try sourceBytes.write(to: swap)
        XCTAssertEqual(rename(swap.path, path("clip.avi").path), 0)
        setTimes("clip.avi", driftTime)

        XCTAssertThrowsError(try prove(lock, claim)) { XCTAssertEqual(($0 as NSError).code, 72) }
        XCTAssertThrowsError(try publish(lock, claim, sha: sha256(sourceBytes)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.mp4").path))
        XCTAssertEqual(try names().filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])
    }

    func testLostClaimIsRejectedBeforeAnyHashOrPublication() throws {
        let (lock, claim) = try lockAndClaim()
        setTimes("clip.avi", driftTime)
        _ = claim.release(success: false)   // the claim files are gone: ownership can no longer be proven
        XCTAssertThrowsError(try prove(lock, claim))
        XCTAssertThrowsError(try publish(lock, claim, sha: sha256(sourceBytes)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.mp4").path))
        try assertOriginalUntouched()
    }

    func testProofIsBoundToItsAttemptHashClaimAndLock() throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        setTimes("clip.avi", driftTime)
        let proof = try prove(lock, claim)

        // Another attempt ID / another source hash: the proof is not accepted.
        let otherAttempt = "0a7f4c1e-1111-4222-8333-444455556666"
        XCTAssertFalse(proof.isBound(to: lock, claim: claim, attemptID: otherAttempt, sourceSha256: sha))
        XCTAssertFalse(proof.isBound(to: lock, claim: claim, attemptID: attemptID, sourceSha256: sha256(Data("x".utf8))))
        XCTAssertThrowsError(try publish(lock, claim, sha: sha, proof: proof, attempt: otherAttempt)) { XCTAssertEqual(($0 as NSError).code, 75) }
        XCTAssertThrowsError(try publish(lock, claim, sha: sha256(Data("x".utf8)), proof: proof)) { XCTAssertEqual(($0 as NSError).code, 75) }
        XCTAssertThrowsError(try publish(lock, claim, sha: nil, proof: proof)) { XCTAssertEqual(($0 as NSError).code, 75) }
        XCTAssertEqual(try names().filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])

        // A proof made for another lock object / claim object (a second directory) is not accepted either.
        let other = try makeSecondDirectoryLock()
        XCTAssertFalse(proof.isBound(to: other.lock, claim: other.claim, attemptID: attemptID, sourceSha256: sha))
        XCTAssertThrowsError(try LocalPublicationManager.publishMP4(
            sourceLock: other.lock, engineOutputURL: engineURL, outputExpectedSize: Int64(engineBytes.count),
            outputExpectedSha256: sha256(engineBytes), attemptID: attemptID, claim: other.claim,
            sourceSha256: sha, driftProof: proof, assumeWebDAVSource: true
        )) { XCTAssertEqual(($0 as NSError).code, 75) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.dir.appendingPathComponent("clip.mp4").path))
    }

    // MARK: journal resume, cancellation

    func testResumeOfAJournalWithTheReasonKeepsTheOriginalEvenWithExactIdentity() async throws {
        // Hand-made earlier run: published MP4 + published journal carrying the reason; the original shows its exact old identity.
        try engineBytes.write(to: path("clip.mp4"))
        var st = stat()
        XCTAssertEqual(stat(path("clip.avi").path, &st), 0)
        let journal = LocalJournalRecord(
            attemptID: attemptID, originalFileName: "clip.avi", backupFileName: "clip_원본.avi", finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(attemptID).mp4", sourceDevice: Int64(st.st_dev), sourceInode: UInt64(st.st_ino),
            sourceSize: Int64(st.st_size), sourceMtime: Int64(st.st_mtimespec.tv_sec), outputSize: Int64(engineBytes.count),
            outputSha256: sha256(engineBytes), state: .outputPublished, createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238),
            retainedOriginalReason: .sourceTimestampOnlyDrift
        )
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(dirFD) }
        try LocalPublicationManager.writeJournalRecord(journal, fileName: ".clip.journal-\(attemptID)-published.json", dirFD: dirFD)
        // The reason survives the encode/decode round trip that recovery and the worker both use.
        XCTAssertEqual(try readJournal("published"), journal)

        let folder = LocalFolderItem(url: directory)
        let pin = try NASPinnedRoot.openBlocking(rootPath: directory.path, folderID: folder.id, connection: 1)
        defer { pin.close() }
        let inspection = LocalConversionRecovery.inspectKnownPublishedResume(
            targets: [LocalRetryTarget(folderID: folder.id, components: ["clip.avi"])], folders: [folder], pins: [folder.id: pin]
        )
        let proof = try XCTUnwrap(inspection.candidates.first?.publishedResume, "\(inspection.notes) \(inspection.errors)")
        XCTAssertEqual(proof.record.retainedOriginalReason, .sourceTimestampOnlyDrift)

        let (lock, claim) = try lockAndClaim()
        let proven = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        XCTAssertEqual(proven.record.retainedOriginalReason, .sourceTimestampOnlyDrift)
        let thumb = try await thumbnail(for: proven, lock: lock)

        XCTAssertThrowsError(try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: proven, thumbnail: thumb, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        )) { XCTAssertEqual(($0 as NSError).code, 55) }
        try assertOriginalUntouched()
        XCTAssertEqual(try Data(contentsOf: path("clip.mp4")), engineBytes)
    }

    func testControlTheSameFixtureWithoutTheReasonStillDeletesSoTheReasonIsTheOnlyBarrier() async throws {
        try engineBytes.write(to: path("clip.mp4"))
        var st = stat()
        XCTAssertEqual(stat(path("clip.avi").path, &st), 0)
        let journal = LocalJournalRecord(
            attemptID: attemptID, originalFileName: "clip.avi", backupFileName: "clip_원본.avi", finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(attemptID).mp4", sourceDevice: Int64(st.st_dev), sourceInode: UInt64(st.st_ino),
            sourceSize: Int64(st.st_size), sourceMtime: Int64(st.st_mtimespec.tv_sec), outputSize: Int64(engineBytes.count),
            outputSha256: sha256(engineBytes), state: .outputPublished, createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238)
        )
        let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(dirFD) }
        try LocalPublicationManager.writeJournalRecord(journal, fileName: ".clip.journal-\(attemptID)-published.json", dirFD: dirFD)
        let (lock, claim) = try lockAndClaim()
        let published = LocalPublishedMP4(
            finalFileName: "clip.mp4", identity: try LocalFileIdentity.inspect(path: path("clip.mp4").path), record: journal
        )
        let thumb = try await thumbnail(for: published, lock: lock)
        try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: published, thumbnail: thumb, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("clip.avi").path))
    }

    func testCancellationDuringTheReHashPreservesEverything() async throws {
        let (lock, claim) = try lockAndClaim()
        let sha = sha256(sourceBytes)
        setTimes("clip.avi", driftTime)
        let attempt = attemptID
        let task = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try LocalPublicationManager.proveSourceTimestampDrift(
                    sourceLock: lock, sourceSha256: sha, claim: claim, attemptID: attempt, assumeWebDAVSource: true
                )
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let error = await task.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")

        // Late drift inside publishMP4 with a cancelled task: nothing staged, nothing published.
        let publishTask = Task { () -> Error? in
            while !Task.isCancelled { await Task.yield() }
            do {
                _ = try self.publish(lock, claim, sha: sha)
                return nil
            } catch {
                return error
            }
        }
        publishTask.cancel()
        let publishError = await publishTask.value
        XCTAssertTrue(publishError is CancellationError, "\(String(describing: publishError))")
        XCTAssertEqual(try names().filter { $0 != VideoConversionClaim.containerDirName }, ["clip.avi"])
        try assertOriginalUntouched()
    }

    // MARK: second fixture directory (own lock + claim)

    private func makeSecondDirectoryLock() throws -> (dir: URL, lock: LocalFileLock, claim: VideoConversionClaim) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ts-drift-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try sourceBytes.write(to: dir.appendingPathComponent("clip.avi"))
        setTimes2(dir, "clip.avi", oldTime)
        let parentFD = open(dir.path, O_RDONLY | O_DIRECTORY)
        let fd = openat(parentFD, "clip.avi", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let lock = try LocalFileLockManager.shared.acquireLock(parentFD: parentFD, fd: fd, fileName: "clip.avi", relativeComponents: ["clip.avi"])
        let claim = try VideoConversionClaim.acquire(
            parentFD: lock.parentFD, sourceName: "clip.avi", outputName: "clip.mp4", backupName: "clip_원본.avi", sourceIdentity: lock.identity
        )
        releaseOnTearDown.append {
            _ = claim.release(success: false)
            lock.unlock()
            try? FileManager.default.removeItem(at: dir)
        }
        return (dir, lock, claim)
    }

    private func setTimes2(_ dir: URL, _ name: String, _ seconds: Int) {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(dir.appendingPathComponent(name).path, &times), 0)
    }
}
