import Darwin
import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class LocalJournalSyncRetryTests: XCTestCase {
    private var directory: URL!
    private var dirFD: Int32 = -1

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("journal-sync-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dirFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dirFD, 0)
    }

    override func tearDownWithError() throws {
        if dirFD >= 0 { close(dirFD) }
        try? FileManager.default.removeItem(at: directory)
    }

    private let target = ".clip.journal-f6851a2f-e2a9-4ebf-ae26-9edefafb7916-published.json"

    private func record() -> LocalJournalRecord {
        LocalJournalRecord(
            attemptID: "f6851a2f-e2a9-4ebf-ae26-9edefafb7916",
            originalFileName: "clip.avi",
            backupFileName: "clip_원본.avi",
            finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-f6851a2f-e2a9-4ebf-ae26-9edefafb7916.mp4",
            sourceDevice: 1,
            sourceInode: 2,
            sourceSize: 3,
            sourceMtime: 4,
            outputSize: 5,
            outputSha256: String(repeating: "ab", count: 32),
            state: .outputPublished,
            createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238),
            thumbnailFileName: nil
        )
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func tempNames() throws -> [String] {
        try names().filter { $0.contains(".tmp-") }
    }

    /// Records every call; `script` decides the result per call (index counted per descriptor kind).
    private final class Recorder {
        var fileCalls: [Int32] = []
        var dirCalls = 0
        var sleeps: [UInt32] = []
    }

    private func hooks(
        _ recorder: Recorder,
        file: @escaping (Int) -> Int32 /* errno to inject, 0 = really fsync */,
        dir: @escaping (Int) -> Int32 = { _ in 0 },
        onFileCall: @escaping (Int) -> Void = { _ in }
    ) -> LocalPublicationManager.JournalSyncHooks {
        let dirFD = self.dirFD
        var hooks = LocalPublicationManager.JournalSyncHooks()
        hooks.sleep = { recorder.sleeps.append($0) }
        hooks.fsync = { fd in
            if fd == dirFD {
                recorder.dirCalls += 1
                let e = dir(recorder.dirCalls)
                if e == 0 { return Darwin.fsync(fd) }
                errno = e
                return -1
            }
            recorder.fileCalls.append(fd)
            let index = recorder.fileCalls.count
            onFileCall(index)
            let e = file(index)
            if e == 0 { return Darwin.fsync(fd) }
            errno = e
            return -1
        }
        return hooks
    }

    func testTransientBusyThenSuccessRetriesSameDescriptorAndPublishes() throws {
        let recorder = Recorder()
        try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(recorder, file: { $0 <= 2 ? EBUSY : 0 })
        )
        XCTAssertEqual(recorder.fileCalls.count, 3)
        XCTAssertEqual(Set(recorder.fileCalls).count, 1, "all file retries must use the same descriptor")
        XCTAssertEqual(recorder.sleeps, [250_000, 500_000])
        XCTAssertEqual(try names(), [target])
        let data = try Data(contentsOf: directory.appendingPathComponent(target))
        XCTAssertEqual(try JSONDecoder().decode(LocalJournalRecord.self, from: data), record())
    }

    func testEAGAINAndEINTRAreAlsoRetried() throws {
        let recorder = Recorder()
        try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(recorder, file: { $0 == 1 ? EAGAIN : ($0 == 2 ? EINTR : 0) })
        )
        XCTAssertEqual(recorder.fileCalls.count, 3)
        XCTAssertEqual(try names(), [target])
    }

    func testExhaustedBusyFailsWithOriginalErrnoRetryCountAndLeavesNothing() throws {
        let recorder = Recorder()
        XCTAssertThrowsError(try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(recorder, file: { _ in EBUSY })
        )) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(ns.code, Int(EBUSY))
            XCTAssertTrue(ns.localizedDescription.contains("저널 fsync 실패 (errno 16, 재시도 4회)"), ns.localizedDescription)
        }
        XCTAssertEqual(recorder.fileCalls.count, 5, "one attempt plus the existing limit of 4 retries")
        XCTAssertEqual(recorder.sleeps, [250_000, 500_000, 750_000, 1_000_000])
        XCTAssertEqual(try names(), [], "owned temp is removed, nothing published")
    }

    func testPermanentErrorIsNotRetried() throws {
        for code in [EIO, ENOTSUP, EINVAL] {
            let recorder = Recorder()
            XCTAssertThrowsError(try LocalPublicationManager.writeJournalRecord(
                record(), fileName: target, dirFD: dirFD,
                hooks: hooks(recorder, file: { _ in code })
            )) { error in
                XCTAssertEqual((error as NSError).code, Int(code))
                XCTAssertTrue((error as NSError).localizedDescription.contains("저널 fsync 실패 (errno \(code))"))
            }
            XCTAssertEqual(recorder.fileCalls.count, 1)
            XCTAssertTrue(recorder.sleeps.isEmpty)
            XCTAssertEqual(try names(), [])
        }
    }

    func testCancellationDuringFileSyncRetryStopsAndRemovesOnlyOwnTemp() async throws {
        let recorder = Recorder()
        let task = Task { [self] in
            try LocalPublicationManager.writeJournalRecord(
                record(), fileName: target, dirFD: dirFD,
                hooks: hooks(recorder, file: { _ in EBUSY }, onFileCall: { index in
                    if index == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            )
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(recorder.fileCalls.count, 2, "no fsync after cancellation")
        XCTAssertEqual(try names(), [])
    }

    func testReplacedTempEntryStopsRetryAndIsNeverTouched() throws {
        let recorder = Recorder()
        var foreignName = ""
        XCTAssertThrowsError(try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(recorder, file: { _ in EBUSY }, onFileCall: { [self] index in
                guard index == 1 else { return }
                // Swap the temp name for a different file while the original inode stays open.
                foreignName = try! tempNames().first!
                let url = directory.appendingPathComponent(foreignName)
                try! FileManager.default.removeItem(at: url)
                try! Data("foreign".utf8).write(to: url)
            })
        )) { error in
            XCTAssertEqual((error as NSError).code, Int(EBUSY))
            XCTAssertTrue((error as NSError).localizedDescription.contains("보존"))
        }
        XCTAssertEqual(recorder.fileCalls.count, 1, "no fsync retry once the name no longer binds the owned inode")
        XCTAssertEqual(try names(), [foreignName])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(foreignName)), Data("foreign".utf8))
    }

    func testDirectorySyncBusyThenSuccessRetriesAndKeepsPublishedJournal() throws {
        let recorder = Recorder()
        try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(recorder, file: { _ in 0 }, dir: { $0 <= 2 ? EBUSY : 0 })
        )
        XCTAssertEqual(recorder.dirCalls, 3)
        XCTAssertEqual(try names(), [target])
    }

    func testDirectorySyncFailureStillThrowsAndKeepsPublishedJournal() throws {
        let busy = Recorder()
        XCTAssertThrowsError(try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(busy, file: { _ in 0 }, dir: { _ in EBUSY })
        )) { error in
            XCTAssertEqual((error as NSError).code, Int(EBUSY))
            XCTAssertTrue((error as NSError).localizedDescription.contains("디렉터리 fsync 실패 (errno 16, 재시도 4회)"))
        }
        XCTAssertEqual(busy.dirCalls, 5)
        XCTAssertEqual(try names(), [target])

        try FileManager.default.removeItem(at: directory.appendingPathComponent(target))
        let permanent = Recorder()
        XCTAssertThrowsError(try LocalPublicationManager.writeJournalRecord(
            record(), fileName: target, dirFD: dirFD,
            hooks: hooks(permanent, file: { _ in 0 }, dir: { _ in EIO })
        )) { error in
            XCTAssertEqual((error as NSError).code, Int(EIO))
        }
        XCTAssertEqual(permanent.dirCalls, 1)
    }

    func testCancellationDuringDirectorySyncRetryThrowsCancellation() async throws {
        let recorder = Recorder()
        let task = Task { [self] in
            var h = hooks(recorder, file: { _ in 0 }, dir: { _ in EBUSY })
            let inner = h.fsync
            h.fsync = { fd in
                let r = inner(fd)
                let saved = errno
                if fd == self.dirFD { withUnsafeCurrentTask { $0?.cancel() } }
                errno = saved
                return r
            }
            try LocalPublicationManager.writeJournalRecord(record(), fileName: target, dirFD: dirFD, hooks: h)
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(recorder.dirCalls, 1)
    }
}
