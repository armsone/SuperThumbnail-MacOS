import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class LocalRecoveryScopeTests: XCTestCase {
    private let caution = "/Volumes/home/temp/Caution"
    private let base = Date(timeIntervalSinceReferenceDate: 814_860_000)

    private func identity() -> LocalFileIdentity {
        LocalFileIdentity(device: 1, inode: 2, size: 3, mtime: 4, mtime_nsec: 0)
    }

    private func item(
        folderID: UUID = UUID(),
        path: String,
        components: [String],
        stage: LocalConversionStage,
        at offset: TimeInterval
    ) -> LocalConversionItem {
        LocalConversionItem(
            folderID: folderID,
            sourceURL: URL(fileURLWithPath: path),
            relativePath: components.joined(separator: "/"),
            relativeComponents: components,
            fileSize: 3,
            identity: identity(),
            stage: stage,
            addedDate: base.addingTimeInterval(offset)
        )
    }

    private func folder(_ path: String) -> LocalFolderItem {
        LocalFolderItem(url: URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: Root switch remap

    func testKnownFailuresSeedAfterRootMovesUpToCaution() {
        let oldRootID = UUID()
        let nfdGita = "기타".decomposedStringWithCanonicalMapping
        let files: [(dir: String, name: String)] = [
            ("FAST", "[CATWALK] CWPBD-83. Catwalk Poison 83_0006.mkv"),
            ("FAST", "[JP FHD AV 노모][S Model] SMBD-010. Misa Sato_00010007.avi"),
            ("FAST", "[JP FHD AV 노모][S Model] SMBD-028. Mei Naomi_0005.avi"),
            ("기타", "[MUGEN] MKBD-S84 KIRARI 84_0007.mkv"),
        ]
        var items: [LocalConversionItem] = []
        for (index, file) in files.enumerated() {
            let urlDir = file.dir == "기타" ? nfdGita : file.dir
            items.append(item(
                folderID: oldRootID,
                path: "\(caution)/01-CLIP/\(urlDir)/\(file.name)",
                components: [file.dir, file.name],
                stage: .failed("x"),
                at: Double(index)
            ))
        }
        let caut = folder(caution)
        let targets = LocalConversionCoordinator.retryTargets(
            from: LocalConversionCoordinator.latestHistoryLocations(from: items, folders: [caut])
        )

        XCTAssertEqual(targets.count, 4)
        for (target, file) in zip(targets, files) {
            XCTAssertEqual(target.folderID, caut.id)
            XCTAssertEqual(target.components, ["01-CLIP", file.dir, file.name])
        }
    }

    func testMostSpecificSelectedRootWinsAndStoredFolderIDIsNotTrusted() {
        let outer = folder(caution)
        let inner = folder(caution + "/01-CLIP")
        let name = "a.avi"
        // The stored ID points at the OUTER folder, but the location lies inside the more specific INNER root.
        let record = item(folderID: outer.id, path: "\(caution)/01-CLIP/FAST/\(name)", components: ["FAST", name], stage: .failed("x"), at: 0)
        let target = LocalConversionCoordinator.currentLocation(of: record, in: [outer, inner])
        XCTAssertEqual(target?.folderID, inner.id)
        XCTAssertEqual(target?.components, ["FAST", name])

        // A stored ID of a currently selected folder whose recorded location is elsewhere is not honored.
        let other = folder("/Volumes/other")
        let stray = item(folderID: other.id, path: "\(caution)/01-CLIP/FAST/\(name)", components: ["FAST", name], stage: .failed("x"), at: 0)
        XCTAssertEqual(LocalConversionCoordinator.currentLocation(of: stray, in: [other])?.folderID, nil)
        XCTAssertEqual(LocalConversionCoordinator.currentLocation(of: stray, in: [other, outer])?.folderID, outer.id)
    }

    func testRemapRejectsOutsideSiblingPrefixAndMismatchedOrHiddenComponents() {
        let caut = folder(caution)
        let name = "a.avi"
        func target(_ path: String, _ components: [String]) -> LocalRetryTarget? {
            LocalConversionCoordinator.currentLocation(
                of: item(path: path, components: components, stage: .failed("x"), at: 0), in: [caut]
            )
        }
        XCTAssertNotNil(target("\(caution)/01-CLIP/\(name)", [name]))
        // Sibling sharing a string prefix, unrelated tree, the root itself.
        XCTAssertNil(target("\(caution)2/01-CLIP/\(name)", [name]))
        XCTAssertNil(target("/Volumes/home/temp/\(name)", [name]))
        XCTAssertNil(target(caution, [name]))
        // Recorded file name differs from the recorded components.
        XCTAssertNil(target("\(caution)/01-CLIP/b.avi", [name]))
        // Hidden / traversal / unsupported names never become targets.
        XCTAssertNil(target("\(caution)/.hidden/\(name)", [name]))
        XCTAssertNil(target("\(caution)/01-CLIP/notes.txt", ["notes.txt"]))
        XCTAssertNil(target("\(caution)/../outside/\(name)", [name]))
    }

    func testNewerRecordForSameFileWinsAcrossRootsAndLatestStageIsRespected() {
        let caut = folder(caution)
        let oldID = UUID()
        let name = "a.avi"
        let same = "\(caution)/01-CLIP/FAST/\(name)"
        let failedOld = item(folderID: oldID, path: same, components: ["FAST", name], stage: .failed("x"), at: 0)
        let completedNew = item(folderID: caut.id, path: same, components: ["01-CLIP", "FAST", name], stage: .completed, at: 10)

        var locations = LocalConversionCoordinator.latestHistoryLocations(from: [failedOld, completedNew], folders: [caut])
        XCTAssertEqual(locations.count, 1)
        XCTAssertTrue(LocalConversionCoordinator.retryTargets(from: locations).isEmpty)

        // Newer failure replaces the older one (one target, no duplicate); an older failure never beats a newer skip.
        let failedNew = item(folderID: caut.id, path: same, components: ["01-CLIP", "FAST", name], stage: .failed("y"), at: 10)
        locations = LocalConversionCoordinator.latestHistoryLocations(from: [failedOld, failedNew], folders: [caut])
        XCTAssertEqual(LocalConversionCoordinator.retryTargets(from: locations).count, 1)
        let skippedNew = item(folderID: caut.id, path: same, components: ["01-CLIP", "FAST", name], stage: .skipped("z"), at: 10)
        locations = LocalConversionCoordinator.latestHistoryLocations(from: [failedOld, skippedNew], folders: [caut])
        // A latest SKIPPED record is a known-resume target too (it must not vanish from published-MP4 recovery).
        XCTAssertEqual(LocalConversionCoordinator.retryTargets(from: locations).count, 1)
    }

    func testPriorityRetryTargetsIncludeCancelledNewestFirstCappedAndExcludeCompleted() {
        let caut = folder(caution)
        func it(_ n: String, _ stage: LocalConversionStage, _ t: TimeInterval) -> LocalConversionItem {
            item(path: "\(caution)/01-CLIP/\(n)", components: ["01-CLIP", n], stage: stage, at: t)
        }
        let items = [it("a.avi", .failed("x"), 1), it("b.avi", .cancelled, 2), it("c.avi", .completed, 3), it("d.avi", .skipped("s"), 4)]
        let locations = LocalConversionCoordinator.latestHistoryLocations(from: items, folders: [caut])
        let targets = LocalConversionCoordinator.priorityRetryTargets(from: locations)
        XCTAssertEqual(targets.map { $0.components.last }, ["d.avi", "b.avi", "a.avi"])
        XCTAssertEqual(LocalConversionCoordinator.priorityRetryTargets(from: locations, limit: 2).count, 2)
    }

    func testRecoveryDirectoriesAreUniqueParentsPlusRootsAndExcludeCompleted() {
        let caut = folder(caution)
        func it(_ rel: [String], _ stage: LocalConversionStage, _ t: TimeInterval) -> LocalConversionItem {
            item(path: caution + "/" + rel.joined(separator: "/"), components: rel, stage: stage, at: t)
        }
        let items = [
            it(["A", "x.avi"], .failed("f"), 0),
            it(["A", "y.avi"], .skipped("s"), 1),
            it(["A", "B", "z.avi"], .cancelled, 2),
            it(["C", "done.avi"], .completed, 3),
            it(["top.avi"], .failed("f"), 4),
        ]
        let dirs = LocalConversionCoordinator.recoveryDirectories(
            from: LocalConversionCoordinator.latestHistoryLocations(from: items, folders: [caut]), folders: [caut]
        )
        XCTAssertEqual(dirs[caut.id], [[], ["A"], ["A", "B"]])
    }

    // MARK: Fixtures on disk

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recovery-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func openPin(_ folder: LocalFolderItem) throws -> NASPinnedRoot {
        try NASPinnedRoot.openBlocking(rootPath: root.path, folderID: folder.id, connection: 1)
    }

    /// Relative path -> kind, for every entry below `root` (detects any create/remove/rename).
    private func snapshot() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        var out: [String] = []
        while let path = enumerator?.nextObject() as? String { out.append(path) }
        return out.sorted()
    }

    func testRemappedPublishedFailureResumesUnderMovedRootWithoutTouchingFiles() throws {
        try assertRemappedPublishedResume(stage: .failed("old"))
    }

    /// A latest SKIPPED record (e.g. identity/claim skip of an earlier run) must still reach the published-MP4 resume.
    func testRemappedPublishedSkippedRecordAlsoResumesWithoutTouchingFiles() throws {
        try assertRemappedPublishedResume(stage: .skipped("파일 식별 정보가 목록 조회 시점과 달라 건너뜁니다"))
    }

    private func assertRemappedPublishedResume(stage: LocalConversionStage) throws {
        // Selected root is the parent ("Caution"); the failure was recorded when "01-CLIP" was the root.
        try mkdir("01-CLIP/FAST")
        let dir = root.appendingPathComponent("01-CLIP/FAST", isDirectory: true)
        let dirFD = open(dir.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dirFD, 0)
        defer { close(dirFD) }

        let mp4 = Data("published-mp4-bytes".utf8)
        try Data("original-avi".utf8).write(to: dir.appendingPathComponent("clip.avi"))
        try mp4.write(to: dir.appendingPathComponent("clip.mp4"))
        var st = stat()
        XCTAssertEqual(stat(dir.appendingPathComponent("clip.avi").path, &st), 0)
        let attempt = "f6851a2f-e2a9-4ebf-ae26-9edefafb7916"
        let journal = LocalJournalRecord(
            attemptID: attempt, originalFileName: "clip.avi", backupFileName: "clip_원본.avi", finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(attempt).mp4", sourceDevice: Int64(st.st_dev), sourceInode: UInt64(st.st_ino),
            sourceSize: Int64(st.st_size), sourceMtime: Int64(st.st_mtimespec.tv_sec), outputSize: Int64(mp4.count),
            outputSha256: SHA256.hash(data: mp4).map { String(format: "%02x", $0) }.joined(), state: .outputPublished,
            createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238), thumbnailFileName: nil
        )
        try LocalPublicationManager.writeJournalRecord(journal, fileName: ".clip.journal-\(attempt)-published.json", dirFD: dirFD)
        let before = try snapshot()

        let selected = LocalFolderItem(url: root)
        let record = item(
            folderID: UUID(), path: root.appendingPathComponent("01-CLIP/FAST/clip.avi").path,
            components: ["FAST", "clip.avi"], stage: stage, at: 0
        )
        let locations = LocalConversionCoordinator.latestHistoryLocations(from: [record], folders: [selected])
        let targets = LocalConversionCoordinator.retryTargets(from: locations)
        XCTAssertEqual(targets, [LocalRetryTarget(folderID: selected.id, components: ["01-CLIP", "FAST", "clip.avi"])])

        let pin = try openPin(selected)
        defer { pin.close() }
        let result = LocalConversionRecovery.inspectKnownPublishedResume(targets: targets, folders: [selected], pins: [selected.id: pin])
        XCTAssertEqual(result.candidates.count, 1, "\(result.notes) \(result.errors)")
        XCTAssertEqual(result.candidates.first?.relativeComponents, ["01-CLIP", "FAST", "clip.avi"])
        XCTAssertNotNil(result.candidates.first?.publishedResume)
        XCTAssertEqual(try snapshot(), before)
    }

    /// A remaining priority retry whose MP4 is already published (pending thumbnail) must still reach the real published-resume check.
    func testPriorityRetryTargetWithPublishedMP4ReachesPublishedResumeAndRegularCandidateIsNotDuplicated() throws {
        try mkdir("D")
        let dir = root.appendingPathComponent("D", isDirectory: true)
        let dirFD = open(dir.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(dirFD, 0)
        defer { close(dirFD) }
        let mp4 = Data("published-mp4-bytes".utf8)
        try Data("original-avi".utf8).write(to: dir.appendingPathComponent("clip.avi"))
        try mp4.write(to: dir.appendingPathComponent("clip.mp4"))
        try Data("fresh".utf8).write(to: dir.appendingPathComponent("fresh.avi"))
        var st = stat()
        XCTAssertEqual(stat(dir.appendingPathComponent("clip.avi").path, &st), 0)
        let attempt = "f6851a2f-e2a9-4ebf-ae26-9edefafb7916"
        let journal = LocalJournalRecord(
            attemptID: attempt, originalFileName: "clip.avi", backupFileName: "clip_원본.avi", finalFileName: "clip.mp4",
            stagedFileName: ".clip.stage-\(attempt).mp4", sourceDevice: Int64(st.st_dev), sourceInode: UInt64(st.st_ino),
            sourceSize: Int64(st.st_size), sourceMtime: Int64(st.st_mtimespec.tv_sec), outputSize: Int64(mp4.count),
            outputSha256: SHA256.hash(data: mp4).map { String(format: "%02x", $0) }.joined(), state: .outputPublished,
            createdAt: Date(timeIntervalSinceReferenceDate: 814860439.216238), thumbnailFileName: nil
        )
        try LocalPublicationManager.writeJournalRecord(journal, fileName: ".clip.journal-\(attempt)-published.json", dirFD: dirFD)
        let before = try snapshot()

        let selected = LocalFolderItem(url: root)
        let pin = try openPin(selected)
        defer { pin.close() }
        let pins = [selected.id: pin]
        func target(_ n: String) -> LocalRetryTarget { LocalRetryTarget(folderID: selected.id, components: ["D", n]) }

        // the regular inspection alone skips the existing MP4 (the defect)
        XCTAssertTrue(LocalConversionRetryInspector.inspect(targets: [target("clip.avi")], folders: [selected], pins: pins).candidates.isEmpty)

        // the feed item for the same path (queued as .retry, so not repeated as .publishedResume) now yields the resume candidate
        let items = LocalConversionCoordinator.priorityFeedItems(remainingPriority: [target("clip.avi")], resumeTargets: [target("clip.avi")])
        XCTAssertEqual(items.count, 1)
        let result = LocalConversionCoordinator.inspectFeedItem(items[0], folders: [selected], pins: pins)
        XCTAssertEqual(result.candidates.count, 1, "\(result.notes) \(result.errors)")
        XCTAssertEqual(result.candidates.first?.relativeComponents, ["D", "clip.avi"])
        XCTAssertNotNil(result.candidates.first?.publishedResume)

        // a normal fresh retry target yields exactly one regular candidate (no resume duplicate)
        let fresh = LocalConversionCoordinator.inspectFeedItem(
            LocalConversionCoordinator.PriorityFeedItem(target: target("fresh.avi"), kind: .retry), folders: [selected], pins: pins
        )
        XCTAssertEqual(fresh.candidates.map { $0.relativeComponents.last }, ["fresh.avi"])
        XCTAssertNil(fresh.candidates.first?.publishedResume)
        XCTAssertEqual(try snapshot(), before)
    }

    func testPriorityInspectionStopsAtFirstSafeCandidateAndLeavesTheRestForIncrementalFeed() throws {
        try mkdir("D")
        for name in ["a.avi", "b.avi", "c.avi"] { try Data("x".utf8).write(to: root.appendingPathComponent("D/\(name)")) }
        let selected = LocalFolderItem(url: root)
        func target(_ n: String) -> LocalRetryTarget { LocalRetryTarget(folderID: selected.id, components: ["D", n]) }
        let pin = try openPin(selected)
        defer { pin.close() }
        // gone.avi no longer exists (nothing to encode), a.avi is the first safe candidate, b.avi/c.avi must NOT be inspected yet
        let targets = [target("gone.avi"), target("a.avi"), target("b.avi"), target("c.avi")]
        let first = LocalConversionCoordinator.inspectUntilFirstCandidate(targets: targets, folders: [selected], pins: [selected.id: pin])
        XCTAssertEqual(first.inspection.candidates.map { $0.relativeComponents.last }, ["a.avi"])
        XCTAssertEqual(first.remaining, [target("b.avi"), target("c.avi")])
        // the remainder is not dropped: inspected one by one it yields exactly the rest, in order
        let rest = first.remaining.flatMap {
            LocalConversionRetryInspector.inspect(targets: [$0], folders: [selected], pins: [selected.id: pin]).candidates
        }
        XCTAssertEqual(rest.map { $0.relativeComponents.last }, ["b.avi", "c.avi"])
        // no safe candidate at all: everything inspected, nothing remains
        let none = LocalConversionCoordinator.inspectUntilFirstCandidate(targets: [target("gone.avi")], folders: [selected], pins: [selected.id: pin])
        XCTAssertTrue(none.inspection.candidates.isEmpty)
        XCTAssertTrue(none.remaining.isEmpty)
    }

    func testRunCannotFinishWhileTheFeederStillHasInspectionsEvenAtEarlyEOFWithNothingActive() {
        typealias C = LocalConversionCoordinator
        XCTAssertFalse(C.runHasNothingLeft(activeCount: 0, inFlightPulls: 0, pendingCount: 0, feederPending: true))
        XCTAssertTrue(C.runHasNothingLeft(activeCount: 0, inFlightPulls: 0, pendingCount: 0, feederPending: false))
        XCTAssertFalse(C.runHasNothingLeft(activeCount: 1, inFlightPulls: 0, pendingCount: 0, feederPending: false))
        XCTAssertFalse(C.runHasNothingLeft(activeCount: 0, inFlightPulls: 1, pendingCount: 0, feederPending: false))
        XCTAssertFalse(C.runHasNothingLeft(activeCount: 0, inFlightPulls: 0, pendingCount: 2, feederPending: false))
    }

    func testFeedAdmissionSkipsFailedActiveAndAlreadyQueuedIdentitiesAndPaths() throws {
        try mkdir("D")
        for name in ["a.avi", "b.avi", "c.avi", "d.avi"] { try Data("x".utf8).write(to: root.appendingPathComponent("D/\(name)")) }
        let selected = LocalFolderItem(url: root)
        let pin = try openPin(selected)
        defer { pin.close() }
        func candidate(_ n: String) -> LocalDiscoveredFile {
            LocalConversionRetryInspector.inspect(targets: [LocalRetryTarget(folderID: selected.id, components: ["D", n])], folders: [selected], pins: [selected.id: pin]).candidates[0]
        }
        let a = candidate("a.avi"), b = candidate("b.avi"), c = candidate("c.avi"), d = candidate("d.avi")
        // a failed earlier in this pass (e.g. by the folder scan), b is encoding, c is already queued; d is new (offered twice)
        let admitted = LocalConversionCoordinator.admitFeedCandidates(
            [a, b, c, d, d], active: [b.identity], activePaths: [], failed: [a.identity], pending: [c]
        )
        XCTAssertEqual(admitted.map { $0.relativeComponents.last }, ["d.avi"])
    }

    // MARK: Same-path queue admission (WebDAV changes timestamps of a file that is already being copied)

    private func synthetic(_ folder: UUID, _ components: [String], mtime: time_t = 100, inode: ino_t = 7) -> LocalDiscoveredFile {
        LocalDiscoveredFile(
            folderID: folder,
            url: URL(fileURLWithPath: "/tmp/q/" + components.joined(separator: "/")),
            relativePath: components.joined(separator: "/"),
            relativeComponents: components,
            fileSize: 10,
            identity: LocalFileIdentity(device: 1, inode: inode, size: 10, mtime: mtime, mtime_nsec: 5, ctime: mtime, ctime_nsec: 5)
        )
    }

    private func admit(
        _ candidates: [LocalDiscoveredFile], activePaths: [LocalDiscoveredFile] = [], pending: [LocalDiscoveredFile] = []
    ) -> [LocalDiscoveredFile] {
        LocalConversionCoordinator.admitFeedCandidates(
            candidates,
            active: Set(activePaths.map(\.identity)),
            activePaths: Set(activePaths.map { LocalConversionCoordinator.pathKey(folderID: $0.folderID, components: $0.relativeComponents) }),
            failed: [],
            pending: pending
        )
    }

    func testActivePathIsNotAdmittedAgainWhenOnlyItsTimestampsChanged() {
        let folder = UUID()
        let active = synthetic(folder, ["Caution", "HHH", "episode1.wmv"], mtime: 100)
        let drifted = synthetic(folder, ["Caution", "HHH", "episode1.wmv"], mtime: 200)   // same path, WebDAV-shifted mtime/ctime
        XCTAssertNotEqual(active.identity, drifted.identity)
        XCTAssertTrue(admit([drifted], activePaths: [active]).isEmpty)
    }

    func testActivePathIsNotAdmittedAgainWhenTheInodeAlsoChanged() {
        let folder = UUID()
        let active = synthetic(folder, ["Caution", "episode1.wmv"], inode: 7)
        XCTAssertTrue(admit([synthetic(folder, ["Caution", "episode1.wmv"], mtime: 300, inode: 9)], activePaths: [active]).isEmpty)
    }

    func testPendingPathIsNotQueuedTwiceEvenWithChangedTimestampsOrNFCNFDSpelling() {
        let folder = UUID()
        let nfc = "\u{D55C}\u{AE00}.wmv"                       // precomposed Hangul
        let nfd = nfc.decomposedStringWithCanonicalMapping       // jamo sequence, canonically equivalent
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        let queued = synthetic(folder, ["Caution", nfc], mtime: 100)
        XCTAssertTrue(admit([synthetic(folder, ["Caution", nfc], mtime: 250)], pending: [queued]).isEmpty)
        XCTAssertTrue(admit([synthetic(folder, ["Caution", nfd], mtime: 250)], pending: [queued]).isEmpty)
        XCTAssertTrue(admit([synthetic(folder, ["Caution", nfd], mtime: 250)], activePaths: [queued]).isEmpty)
        // the batch itself is deduplicated as well
        XCTAssertEqual(admit([synthetic(folder, ["Caution", nfc], mtime: 1), synthetic(folder, ["Caution", nfd], mtime: 2)]).count, 1)
    }

    func testDifferentFilesStayAdmittedWhileAnotherPathIsActive() {
        let folder = UUID(), otherFolder = UUID()
        let active = synthetic(folder, ["Caution", "episode1.wmv"])
        let sibling = synthetic(folder, ["Caution", "episode2.wmv"], inode: 8)
        let caseDiffers = synthetic(folder, ["Caution", "Episode1.wmv"], inode: 9)
        let otherDirectory = synthetic(folder, ["Other", "episode1.wmv"], inode: 10)
        let otherSelectedFolder = synthetic(otherFolder, ["Caution", "episode1.wmv"], inode: 11)
        let admitted = admit([sibling, caseDiffers, otherDirectory, otherSelectedFolder], activePaths: [active])
        XCTAssertEqual(admitted.map(\.relativePath), ["Caution/episode2.wmv", "Caution/Episode1.wmv", "Other/episode1.wmv", "Caution/episode1.wmv"])
    }

    func testSamePathIsAdmittedAgainOnTheNextRunWithChangedFile() {
        let folder = UUID()
        let first = synthetic(folder, ["Caution", "episode1.wmv"], mtime: 100)
        XCTAssertTrue(admit([synthetic(folder, ["Caution", "episode1.wmv"], mtime: 200)], activePaths: [first]).isEmpty)
        // run ended: nothing is active or pending any more (no per-path memory survives), so an explicit retry or the changed file is admitted
        let changed = synthetic(folder, ["Caution", "episode1.wmv"], mtime: 900)
        XCTAssertEqual(admit([changed]).map(\.identity), [changed.identity])
    }

    // MARK: Same-path exclusion after a failure in this run

    private func key(_ f: LocalDiscoveredFile) -> String {
        LocalConversionCoordinator.pathKey(folderID: f.folderID, components: f.relativeComponents)
    }

    func testDriftedCopyOfFailedOriginalIsNotAdmittedAgainInThisRun() {
        let folder = UUID()
        let failed = synthetic(folder, ["Caution", "ILOVEASHLYNN#2.avi"], mtime: 100)
        let drifted = synthetic(folder, ["Caution", "ILOVEASHLYNN#2.avi"], mtime: 400, inode: 9)
        XCTAssertNotEqual(failed.identity, drifted.identity)
        let admitted = LocalConversionCoordinator.admitFeedCandidates(
            [drifted], active: [], activePaths: [], failed: [failed.identity], failedPaths: [key(failed)], pending: []
        )
        XCTAssertTrue(admitted.isEmpty)
    }

    func testPendingDuplicateQueuedBeforeTheFailureIsDroppedWithoutTouchingOthers() {
        let folder = UUID()
        let failed = synthetic(folder, ["Caution", "HHH", "episode1.wmv"], mtime: 100)
        let duplicate = synthetic(folder, ["Caution", "HHH", "episode1.wmv"], mtime: 300, inode: 8)
        let sibling = synthetic(folder, ["Caution", "HHH", "episode2.wmv"], inode: 9)
        let otherFolder = synthetic(UUID(), ["Caution", "HHH", "episode1.wmv"], inode: 10)
        let kept = LocalConversionCoordinator.removingPendingPaths([key(failed)], from: [duplicate, sibling, otherFolder])
        XCTAssertEqual(kept.map(\.identity), [sibling.identity, otherFolder.identity])
        // nothing failed: the queue is returned unchanged
        XCTAssertEqual(LocalConversionCoordinator.removingPendingPaths([], from: [duplicate, sibling]).count, 2)
    }

    func testFailedPathIsAdmittedAgainOnTheNextRunAndDistinctPathsAreNeverBlocked() {
        let folder = UUID()
        let failed = synthetic(folder, ["Caution", "episode1.wmv"], mtime: 100)
        let drifted = synthetic(folder, ["Caution", "episode1.wmv"], mtime: 200)
        let sibling = synthetic(folder, ["Caution", "episode2.wmv"], inode: 8)
        let caseDiffers = synthetic(folder, ["Caution", "Episode1.wmv"], inode: 9)
        let otherFolder = synthetic(UUID(), ["Caution", "episode1.wmv"], inode: 11)
        func admitWith(failedPaths: Set<String>) -> [String] {
            LocalConversionCoordinator.admitFeedCandidates(
                [drifted, sibling, caseDiffers, otherFolder], active: [], activePaths: [], failed: [], failedPaths: failedPaths, pending: []
            ).map(\.relativePath)
        }
        XCTAssertEqual(admitWith(failedPaths: [key(failed)]), ["Caution/episode2.wmv", "Caution/Episode1.wmv", "Caution/episode1.wmv"])
        // next run: the per-run set is empty again, so the explicit retry is admitted
        XCTAssertEqual(admitWith(failedPaths: []).count, 4)
    }

    func testFeedOrderPutsPriorityFirstThenResumesWithoutInspectingAFileTwice() {
        let id = UUID()
        func t(_ n: String) -> LocalRetryTarget { LocalRetryTarget(folderID: id, components: ["D", n]) }
        let items = LocalConversionCoordinator.priorityFeedItems(remainingPriority: [t("b"), t("c")], resumeTargets: [t("a"), t("b"), t("c"), t("d")])
        XCTAssertEqual(items.map { $0.target.components.last! }, ["b", "c", "a", "d"])
        XCTAssertEqual(items.map { $0.kind == .retry }, [true, true, false, false])
    }

    func testSymlinkedDirectoryInRemappedTargetIsRejectedByPinnedWalk() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recovery-scope-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("x".utf8).write(to: outside.appendingPathComponent("evil.avi"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let selected = LocalFolderItem(url: root)
        let record = item(path: root.appendingPathComponent("link/evil.avi").path, components: ["link", "evil.avi"], stage: .failed("x"), at: 0)
        let targets = LocalConversionCoordinator.retryTargets(
            from: LocalConversionCoordinator.latestHistoryLocations(from: [record], folders: [selected])
        )
        XCTAssertEqual(targets.count, 1)   // lexical containment passes; the descriptor walk is what refuses

        let pin = try openPin(selected)
        defer { pin.close() }
        let inspection = LocalConversionRetryInspector.inspect(targets: targets, folders: [selected], pins: [selected.id: pin])
        XCTAssertTrue(inspection.candidates.isEmpty)
        XCTAssertFalse(inspection.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil.avi").path))
    }

    // MARK: Targeted recovery

    private let claimName = String(repeating: "ab", count: 32) + ".claim"

    /// An unreadable/foreign claim directory: recovery must report it and leave it exactly as is.
    private func makeForeignClaim(in directory: String) throws {
        try mkdir("\(directory)/\(VideoConversionClaim.containerDirName)/\(claimName)")
    }

    func testTargetedRecoveryVisitsOnlyListedDirectoriesAndNeverQueuesChildren() throws {
        try makeForeignClaim(in: "A")
        try makeForeignClaim(in: "A/deep")
        try makeForeignClaim(in: "B")
        try makeForeignClaim(in: "")
        let before = try snapshot()

        let selected = LocalFolderItem(url: root)
        let pin = try openPin(selected)
        defer { pin.close() }

        var full = LocalConversionRecoveryResult()
        LocalConversionRecovery.scanFolder(folder: selected, pin: pin, result: &full)
        XCTAssertEqual(full.protectedClaimCount, 4, "\(full.detailLines)")

        var targeted = LocalConversionRecoveryResult()
        LocalConversionRecovery.scanDirectories([["A"]], folder: selected, pin: pin, result: &targeted)
        XCTAssertEqual(targeted.protectedClaimCount, 1, "A only: no root, no A/deep, no B. \(targeted.detailLines)")
        XCTAssertEqual(targeted.folderErrorCount, 0)

        var rootAndA = LocalConversionRecoveryResult()
        LocalConversionRecovery.scanDirectories([[], ["A"]], folder: selected, pin: pin, result: &rootAndA)
        XCTAssertEqual(rootAndA.protectedClaimCount, 2)

        // Foreign/unreadable claims are preserved byte-for-byte in every mode.
        XCTAssertEqual(try snapshot(), before)
    }

    func testTargetedRecoveryReportsMissingDirectoryWithoutTraversingElsewhere() throws {
        try makeForeignClaim(in: "A")
        let selected = LocalFolderItem(url: root)
        let pin = try openPin(selected)
        defer { pin.close() }

        var result = LocalConversionRecoveryResult()
        LocalConversionRecovery.scanDirectories([["gone"]], folder: selected, pin: pin, result: &result)
        XCTAssertEqual(result.folderErrorCount, 1)
        XCTAssertEqual(result.protectedClaimCount, 0)
    }
}
