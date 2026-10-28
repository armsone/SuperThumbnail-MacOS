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
