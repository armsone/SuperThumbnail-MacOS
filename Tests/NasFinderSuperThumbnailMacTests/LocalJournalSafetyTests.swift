import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class LocalJournalSafetyTests: XCTestCase {
    private var directory: URL!
    private var dirFD: Int32 = -1

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("journal-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dirFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dirFD, 0)
    }

    override func tearDownWithError() throws {
        if dirFD >= 0 { close(dirFD) }
        try? FileManager.default.removeItem(at: directory)
    }

    private let stem = "clip"
    private let attemptID = "f6851a2f-e2a9-4ebf-ae26-9edefafb7916"
    private let sha = String(repeating: "ab", count: 32)

    private func record(state: LocalJournalRecord.State, sha: String? = nil, attemptID: String? = nil, thumbnail: String? = nil) -> LocalJournalRecord {
        let id = attemptID ?? self.attemptID
        return LocalJournalRecord(
            attemptID: id,
            originalFileName: "clip.avi",
            backupFileName: "clip_원본.avi",
            finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(id).mp4",
            sourceDevice: 1,
            sourceInode: 2,
            sourceSize: 3,
            sourceMtime: 4,
            outputSize: 5,
            outputSha256: sha ?? self.sha,
            state: state,
            createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238),
            thumbnailFileName: thumbnail
        )
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func write(_ name: String, _ data: Data) throws {
        try data.write(to: directory.appendingPathComponent(name))
    }

    // MARK: writeJournalRecord

    func testJournalWritePublishesExactBytesAndLeavesNoTemp() throws {
        let published = record(state: .outputPublished)
        try LocalPublicationManager.writeJournalRecord(published, fileName: ".clip.journal-\(attemptID)-published.json", dirFD: dirFD)

        XCTAssertEqual(try names(), [".clip.journal-\(attemptID)-published.json"])
        let data = try Data(contentsOf: directory.appendingPathComponent(".clip.journal-\(attemptID)-published.json"))
        XCTAssertEqual(try JSONDecoder().decode(LocalJournalRecord.self, from: data), published)
    }

    func testJournalWriteToExistingTargetKeepsTargetAndForeignTempAndRemovesOnlyOwnTemp() throws {
        let target = ".clip.journal-\(attemptID)-deleting.json"
        let foreignTemp = "\(target).tmp-\(UUID().uuidString.lowercased())"
        try write(target, Data("existing".utf8))
        try write(foreignTemp, Data())

        XCTAssertThrowsError(
            try LocalPublicationManager.writeJournalRecord(record(state: .deletionStarted), fileName: target, dirFD: dirFD)
        )

        // The existing target and an unrelated (even empty) temp-looking file are never touched; our own temp is gone.
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(target)), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(foreignTemp)), Data())
        XCTAssertEqual(try names(), [foreignTemp, target].sorted())
    }

    // MARK: recognized journal temp files

    private func validate(_ tempNames: [String], published: LocalJournalRecord? = nil) throws -> [String] {
        try LocalConversionRecovery.validateAttemptJournalTemps(
            parentFD: dirFD, names: tempNames, stem: stem, published: published ?? record(state: .outputPublished)
        )
    }

    private func tempName(_ kind: String, id: String? = nil) -> String {
        ".clip.journal-\(id ?? attemptID)-\(kind).json.tmp-\(UUID().uuidString.lowercased())"
    }

    func testEmptyAndMatchingDeletionTempAreRecognizedAndKept() throws {
        let empty = tempName("deleting")
        let populated = tempName("deleting")
        try write(empty, Data())
        try write(populated, JSONEncoder().encode(record(state: .deletionStarted, thumbnail: "v1-\(String(repeating: "0", count: 64)).jpg")))

        let ignored = try validate([empty, populated])
        XCTAssertEqual(ignored, [empty, populated])
        XCTAssertEqual(try names(), [empty, populated].sorted())
    }

    func testUnknownOrMismatchedTempsBlock() throws {
        // Different output hash.
        let wrongHash = tempName("deleting")
        try write(wrongHash, JSONEncoder().encode(record(state: .deletionStarted, sha: String(repeating: "cd", count: 32))))
        XCTAssertThrowsError(try validate([wrongHash]))

        // Different attempt in both name and content.
        let otherID = "11111111-2222-4333-8444-555555555555"
        let otherAttempt = tempName("deleting", id: otherID)
        try write(otherAttempt, JSONEncoder().encode(record(state: .deletionStarted, attemptID: otherID)))
        XCTAssertThrowsError(try validate([otherAttempt]))

        // State that does not fit the name.
        let wrongState = tempName("deleting")
        try write(wrongState, JSONEncoder().encode(record(state: .outputPublished)))
        XCTAssertThrowsError(try validate([wrongState]))

        // Name outside the generation rule (uppercase uuid / free text).
        let upper = ".clip.journal-\(attemptID)-deleting.json.tmp-\(UUID().uuidString.uppercased())"
        try write(upper, Data())
        XCTAssertThrowsError(try validate([upper]))
        let other = ".clip.journal-\(attemptID)-notes.txt"
        try write(other, Data())
        XCTAssertThrowsError(try validate([other]))

        // Nothing was modified or removed.
        XCTAssertEqual(try names().count, 5)
    }

    // MARK: known failed history with a published MP4 (candidate-local, read-only)

    private let mp4Bytes = Data("published-mp4-bytes".utf8)

    /// clip.avi + clip.mp4 + exact published journal; returns the journal file name.
    @discardableResult
    private func makePublished(mp4: Data? = nil, journalMtimeOffset: Int64 = 0, writeJournal: Bool = true) throws -> String {
        try write("clip.avi", Data("original-avi".utf8))
        try write("clip.mp4", mp4 ?? mp4Bytes)
        var st = stat()
        XCTAssertEqual(stat(directory.appendingPathComponent("clip.avi").path, &st), 0)
        let journal = LocalJournalRecord(
            attemptID: attemptID,
            originalFileName: "clip.avi",
            backupFileName: "clip_원본.avi",
            finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(attemptID).mp4",
            sourceDevice: Int64(st.st_dev),
            sourceInode: UInt64(st.st_ino),
            sourceSize: Int64(st.st_size),
            sourceMtime: Int64(st.st_mtimespec.tv_sec) + journalMtimeOffset,
            outputSize: Int64(mp4Bytes.count),
            outputSha256: SHA256.hash(data: mp4Bytes).map { String(format: "%02x", $0) }.joined(),
            state: .outputPublished,
            createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238),
            thumbnailFileName: nil
        )
        let name = ".clip.journal-\(attemptID)-published.json"
        if writeJournal {
            try LocalPublicationManager.writeJournalRecord(journal, fileName: name, dirFD: dirFD)
        }
        return name
    }

    private func inspectKnown() throws -> LocalRetryInspection {
        let folder = LocalFolderItem(url: directory)
        let pin = try NASPinnedRoot.openBlocking(rootPath: directory.path, folderID: folder.id, connection: 1)
        defer { pin.close() }
        return LocalConversionRecovery.inspectKnownPublishedResume(
            targets: [LocalRetryTarget(folderID: folder.id, components: ["clip.avi"])],
            folders: [folder],
            pins: [folder.id: pin]
        )
    }

    func testKnownFailedHistoryWithExactJournalAndMP4ProducesResumeCandidateWithoutTouchingFiles() throws {
        try makePublished()
        let before = try names()
        let result = try inspectKnown()

        XCTAssertEqual(result.candidates.count, 1, "\(result.notes) \(result.errors)")
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume)
        XCTAssertFalse(proof.sourceTimestampDrift)
        XCTAssertEqual(proof.record.attemptID, attemptID)
        XCTAssertEqual(try names(), before)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.mp4")), mp4Bytes)
    }

    func testKnownFailedHistoryBlocksOnWrongSizeMP4OrNonWebDAVTimeChangeOrMissingJournal() throws {
        // Different size than the journal: blocked cheaply at start-up and nothing is touched.
        try makePublished(mp4: Data(repeating: 0x41, count: mp4Bytes.count + 1))
        var result = try inspectKnown()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.notes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.mp4")), Data(repeating: 0x41, count: mp4Bytes.count + 1))
        for name in try names() { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }

        // Original mtime differs from the journal on a non-webdav volume: blocked (only webdav time drift is tolerated).
        try makePublished(journalMtimeOffset: 100)
        result = try inspectKnown()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertFalse(result.notes.isEmpty)
        for name in try names() { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }

        // No journal at all: not a resume candidate (regular retry/scan rules stay in charge).
        try makePublished(writeJournal: false)
        result = try inspectKnown()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertEqual(try names(), ["clip.avi", "clip.mp4"])
    }

    // MARK: unverified candidate → worker proof (bad hash is never written)

    private var vaultURL: URL { directory.appendingPathComponent(".NasFinder-Vault", isDirectory: true) }

    /// Opens the lock and a fresh own claim exactly like the worker does for the original of `makePublished`.
    private func lockAndClaim() throws -> (lock: LocalFileLock, claim: VideoConversionClaim) {
        let parentFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        let fd = openat(parentFD, "clip.avi", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let lock = try LocalFileLockManager.shared.acquireLock(parentFD: parentFD, fd: fd, fileName: "clip.avi", relativeComponents: ["clip.avi"])
        let claim = try VideoConversionClaim.acquire(
            parentFD: lock.parentFD, sourceName: "clip.avi", outputName: "clip.mp4", backupName: "clip_원본.avi", sourceIdentity: lock.identity
        )
        return (lock, claim)
    }

    func testKnownCandidateIsUnverifiedAndTamperedSameSizeMP4IsRejectedByWorkerBeforeAnyWrite() throws {
        let tampered = Data(repeating: 0x41, count: mp4Bytes.count)
        try makePublished(mp4: tampered)
        let result = try inspectKnown()
        // Start-up reads no MP4 content: the same-size tampered file is a candidate, explicitly marked unverified.
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        XCTAssertFalse(proof.outputHashVerifiedByRecovery)

        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        XCTAssertThrowsError(try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)) { error in
            XCTAssertEqual((error as NSError).code, 66)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path), "no thumbnail/vault write before the full SHA-256 matches")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.mp4")), tampered)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.avi")), Data("original-avi".utf8))
    }

    func testResumeNeverAcceptsAnotherSourceTimeOutsideWebDAVEvenWithDriftFlag() throws {
        try makePublished()
        let result = try inspectKnown()
        let candidate = try XCTUnwrap(result.candidates.first, "\(result.notes) \(result.errors)")
        let proof = try XCTUnwrap(candidate.publishedResume)

        // The journal says another mtime second, this volume is not webdav: the flag alone must not relax anything.
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proof.record)) as? [String: Any])
        fields["sourceMtime"] = proof.record.sourceMtime + 100
        let changed = try JSONDecoder().decode(LocalJournalRecord.self, from: JSONSerialization.data(withJSONObject: fields))
        let forged = LocalPublishedResumeProof(record: changed, outputIdentity: proof.outputIdentity, sourceTimestampDrift: true)
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        XCTAssertThrowsError(try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: forged, claim: claim)) { error in
            XCTAssertEqual((error as NSError).code, 62)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
    }

    func testSameFileIgnoresOnlyTimesNeverInodeOrSize() {
        let base = LocalFileIdentity(device: 1, inode: 2, size: 3, mtime: 4, mtime_nsec: 5, ctime: 6, ctime_nsec: 7)
        XCTAssertTrue(base.isSameFile(as: LocalFileIdentity(device: 1, inode: 2, size: 3, mtime: 99, mtime_nsec: 0, ctime: 98, ctime_nsec: 1)))
        XCTAssertFalse(base.isSameFile(as: LocalFileIdentity(device: 1, inode: 9, size: 3, mtime: 4, mtime_nsec: 5, ctime: 6, ctime_nsec: 7)))
        XCTAssertFalse(base.isSameFile(as: LocalFileIdentity(device: 1, inode: 2, size: 4, mtime: 4, mtime_nsec: 5, ctime: 6, ctime_nsec: 7)))
        XCTAssertFalse(base.isSameFile(as: LocalFileIdentity(device: 2, inode: 2, size: 3, mtime: 4, mtime_nsec: 5, ctime: 6, ctime_nsec: 7)))
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

    func testResumeReusesExistingValidJPEGAtTheKeyWithoutOverwritingAndKeepsOriginal() async throws {
        try makePublished()
        let result = try inspectKnown()
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }

        let published = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        let finalURL = directory.appendingPathComponent("clip.mp4")
        let key = try NasFinderVaultCompatibility.thumbnailFilename(for: finalURL)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let existing = try validJPEGData()
        let keyURL = vaultURL.appendingPathComponent(key)
        try existing.write(to: keyURL)

        let thumbnail = try await LocalPublicationManager.createVerifiedThumbnail(
            sourceLock: lock, published: published, finalURL: finalURL, resumedPublication: true
        )
        XCTAssertEqual(thumbnail.fileName, key)
        XCTAssertEqual(try Data(contentsOf: keyURL), existing, "an existing valid JPEG at the key is reused, never rewritten")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path), [key])
        XCTAssertEqual(try Data(contentsOf: finalURL), mp4Bytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.avi")), Data("original-avi".utf8))
    }

    // MARK: webdav stale first identity (normal publication): key from server-refreshed metadata

    /// What a webdav client showed right after publication: the right dev/inode/size but a time the server never had.
    private func staleIdentity(of real: LocalFileIdentity, mtimeOffset: Int = -6000, size: Int64? = nil, inode: ino_t? = nil) -> LocalFileIdentity {
        LocalFileIdentity(
            device: real.device, inode: inode ?? real.inode, size: size ?? real.size,
            mtime: real.mtime + time_t(mtimeOffset), mtime_nsec: 0, ctime: real.ctime + time_t(mtimeOffset), ctime_nsec: 0
        )
    }

    private func setMP4Time(_ seconds: Int) {
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        XCTAssertEqual(utimes(directory.appendingPathComponent("clip.mp4").path, &times), 0)
    }

    func testEnumerationRefreshSeesTheEntryByCanonicalNameAndFailsWhenAbsent() throws {
        try write("한글.mp4", Data("x".utf8))
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        defer { Darwin.close(fd) }
        XCTAssertTrue(LocalPublicationManager.enumerateDirectoryRefreshingMetadata(dirFD: fd, expecting: "한글.mp4"))
        XCTAssertTrue(LocalPublicationManager.enumerateDirectoryRefreshingMetadata(dirFD: fd, expecting: "한글.mp4".decomposedStringWithCanonicalMapping))
        XCTAssertFalse(LocalPublicationManager.enumerateDirectoryRefreshingMetadata(dirFD: fd, expecting: "없음.mp4"))
    }

    func testWebDAVNormalPublicationWithStaleTimeKeysFromRefreshedMetadataAfterSHAReproof() async throws {
        try makePublished()
        setMP4Time(1_793_175_532)
        let result = try inspectKnown()
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        let proven = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        let real = try LocalFileIdentity.inspect(path: directory.appendingPathComponent("clip.mp4").path)
        let stale = LocalPublishedMP4(finalFileName: "clip.mp4", identity: staleIdentity(of: real), record: proven.record)

        let finalURL = directory.appendingPathComponent("clip.mp4")
        let correctKey = NasFinderVaultCompatibility.thumbnailFilename(name: "clip.mp4", size: real.size, modifiedAt: Date(timeIntervalSince1970: 1_793_175_532))
        let staleKey = NasFinderVaultCompatibility.thumbnailFilename(name: "clip.mp4", size: real.size, modifiedAt: Date(timeIntervalSince1970: Double(real.mtime - 6000)))
        XCTAssertNotEqual(correctKey, staleKey)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try validJPEGData().write(to: vaultURL.appendingPathComponent(correctKey))

        let thumbnail = try await LocalPublicationManager.createVerifiedThumbnail(
            sourceLock: lock, published: stale, finalURL: finalURL, resumedPublication: false, assumeWebDAVParent: true
        )
        XCTAssertEqual(thumbnail.fileName, correctKey)
        XCTAssertEqual(thumbnail.mp4Identity.mtime, 1_793_175_532, "the refreshed identity (not the stale first one) is what deletion will be checked against")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vaultURL.path), [correctKey])
        XCTAssertEqual(try Data(contentsOf: finalURL), mp4Bytes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.avi")), Data("original-avi".utf8))
    }

    func testWebDAVStaleTimeIsNotAcceptedWhenContentChangedOrFileReplacedOrSizeDiffers() async throws {
        try makePublished()
        let result = try inspectKnown()
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        let proven = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        let mp4URL = directory.appendingPathComponent("clip.mp4")
        let real = try LocalFileIdentity.inspect(path: mp4URL.path)

        // Same dev/inode/size but different bytes: the SHA-256 reproof fails.
        let tampered = Data(repeating: 0x41, count: mp4Bytes.count)
        let handle = try FileHandle(forWritingTo: mp4URL)
        try handle.write(contentsOf: tampered)
        try handle.close()
        let staleSame = LocalPublishedMP4(finalFileName: "clip.mp4", identity: staleIdentity(of: real), record: proven.record)
        do {
            _ = try await LocalPublicationManager.createVerifiedThumbnail(
                sourceLock: lock, published: staleSame, finalURL: mp4URL, assumeWebDAVParent: true
            )
            XCTFail("tampered content must not be keyed")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path), "nothing is written to the Vault")
        XCTAssertEqual(try Data(contentsOf: mp4URL), tampered)

        // Restored content, but the expected identity claims another inode / size: not the same file.
        try mp4Bytes.write(to: mp4URL)
        let now = try LocalFileIdentity.inspect(path: mp4URL.path)
        for wrong in [staleIdentity(of: now, inode: now.inode &+ 1), staleIdentity(of: now, size: now.size + 1)] {
            let published = LocalPublishedMP4(finalFileName: "clip.mp4", identity: wrong, record: proven.record)
            do {
                _ = try await LocalPublicationManager.createVerifiedThumbnail(
                    sourceLock: lock, published: published, finalURL: mp4URL, assumeWebDAVParent: true
                )
                XCTFail("a different inode or size is never tolerated")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.avi")), Data("original-avi".utf8))
    }

    func testStaleTimeIsStillRejectedOnANonWebDAVParent() async throws {
        try makePublished()
        let result = try inspectKnown()
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        let proven = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        let mp4URL = directory.appendingPathComponent("clip.mp4")
        let real = try LocalFileIdentity.inspect(path: mp4URL.path)
        let stale = LocalPublishedMP4(finalFileName: "clip.mp4", identity: staleIdentity(of: real), record: proven.record)
        do {
            _ = try await LocalPublicationManager.createVerifiedThumbnail(sourceLock: lock, published: stale, finalURL: mp4URL)
            XCTFail("time drift is only tolerated on webdav")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: vaultURL.path))
    }

    func testDeletionRefusesAThumbnailKeyedFromADifferentMP4File() throws {
        try makePublished()
        let result = try inspectKnown()
        let proof = try XCTUnwrap(result.candidates.first?.publishedResume, "\(result.notes) \(result.errors)")
        let (lock, claim) = try lockAndClaim()
        defer { _ = claim.release(success: false); lock.unlock() }
        let proven = try LocalPublicationManager.verifyResumedPublication(sourceLock: lock, proof: proof, claim: claim)
        let other = LocalPublishedThumbnail(
            fileName: "v1-x.jpg", identity: proven.identity, vaultDevice: 0, vaultInode: 0,
            mp4Identity: staleIdentity(of: proven.identity, inode: proven.identity.inode &+ 1)
        )
        XCTAssertThrowsError(try LocalPublicationManager.deleteVerifiedOriginal(
            sourceLock: lock, published: proven, thumbnail: other, attemptID: attemptID, claim: claim, verifyParentPinned: {}
        ))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.avi")), Data("original-avi".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("clip.mp4")), mp4Bytes)
    }
}
