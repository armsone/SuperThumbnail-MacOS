import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import NasFinderSuperThumbnailMac

final class MediaDiscoveryProgressTests: XCTestCase {
    func testDiscoveryPhasePresentationValues() {
        XCTAssertEqual(MediaDiscoveryPhase.titleText, "사진과 영상을 찾는 중")

        XCTAssertFalse(MediaDiscoveryPhase.idle.isActive)
        XCTAssertEqual(MediaDiscoveryPhase.idle.activityText, "")
        XCTAssertEqual(MediaDiscoveryPhase.idle.accessibilityValueText, "")

        let files = MediaDiscoveryPhase.discoveringFiles
        XCTAssertTrue(files.isActive)
        XCTAssertEqual(files.activityText, "사진과 영상 파일을 찾는 중…")
        XCTAssertEqual(files.accessibilityLabelText, "사진과 영상을 찾는 중")
        XCTAssertEqual(files.accessibilityValueText, "사진과 영상 파일을 찾는 중")

        let folders = MediaDiscoveryPhase.discoveringFolders
        XCTAssertTrue(folders.isActive)
        XCTAssertEqual(folders.activityText, "하위 폴더를 찾는 중…")
        XCTAssertEqual(folders.accessibilityLabelText, "사진과 영상을 찾는 중")
        XCTAssertEqual(folders.accessibilityValueText, "하위 폴더를 찾는 중")

        XCTAssertNotEqual(files.activityText, folders.activityText)
        XCTAssertNotEqual(files.accessibilityValueText, folders.accessibilityValueText)
    }

    func testDiscoveryCountsPresentationValues() {
        XCTAssertEqual(MediaDiscoveryCounts.zero.countText, "폴더 0개 · 파일 0개")
        XCTAssertEqual(MediaDiscoveryCounts.zero.accessibilityText, "폴더 0개, 파일 0개 발견")

        let counts = MediaDiscoveryCounts(folderCount: 12, fileCount: 340)
        XCTAssertEqual(counts.countText, "폴더 12개 · 파일 340개")
        XCTAssertEqual(counts.accessibilityText, "폴더 12개, 파일 340개 발견")

        // Large values use the locale grouping separator like the other counters.
        let large = MediaDiscoveryCounts(folderCount: 1_234, fileCount: 56_789)
        XCTAssertEqual(large.countText, "폴더 \(1_234.formatted())개 · 파일 \(56_789.formatted())개")

        XCTAssertEqual(MediaDiscoveryPhase.idle.accessibilityValueText(with: counts), "")
        XCTAssertEqual(
            MediaDiscoveryPhase.discoveringFiles.accessibilityValueText(with: counts),
            "사진과 영상 파일을 찾는 중, 폴더 12개, 파일 340개 발견"
        )
        XCTAssertEqual(
            MediaDiscoveryPhase.discoveringFolders.accessibilityValueText(with: counts),
            "하위 폴더를 찾는 중, 폴더 12개, 파일 340개 발견"
        )
    }

    func testDiscoveryCountsMergeNeverMoveBackwards() {
        let filePass = MediaDiscoveryCounts(folderCount: 7, fileCount: 40)
        // The folder pass reports fileCount == 0; the file total must survive.
        XCTAssertEqual(
            filePass.merging(MediaDiscoveryCounts(folderCount: 3, fileCount: 0)),
            MediaDiscoveryCounts(folderCount: 7, fileCount: 40)
        )
        XCTAssertEqual(
            filePass.merging(MediaDiscoveryCounts(folderCount: 9, fileCount: 0)),
            MediaDiscoveryCounts(folderCount: 9, fileCount: 40)
        )
        // An out-of-order (older) file-pass report cannot lower either field.
        XCTAssertEqual(
            filePass.merging(MediaDiscoveryCounts(folderCount: 6, fileCount: 39)),
            filePass
        )
    }

    func testProgressThrottleDeliversFirstChangeThenCoalesces() {
        var throttle = MediaDiscoveryProgressThrottle(minimumInterval: 0.1)
        let one = MediaDiscoveryCounts(folderCount: 0, fileCount: 1)
        let two = MediaDiscoveryCounts(folderCount: 0, fileCount: 2)
        let three = MediaDiscoveryCounts(folderCount: 1, fileCount: 3)

        XCTAssertTrue(throttle.shouldReport(one, at: 10.00), "첫 변경은 즉시 보고해야 합니다.")
        XCTAssertFalse(throttle.shouldReport(one, at: 10.00), "같은 값은 다시 보고하지 않습니다.")
        XCTAssertFalse(throttle.shouldReport(two, at: 10.05), "간격 안의 변경은 합쳐집니다.")
        // Stay just beyond the decimal boundary so binary floating-point representation
        // cannot turn an exact 0.1-second interval into 0.099999… on some builds.
        XCTAssertTrue(throttle.shouldReport(three, at: 10.101), "간격이 지나면 최신 값을 보고합니다.")
        XCTAssertFalse(throttle.shouldReport(three, at: 10.50))

        let final = MediaDiscoveryCounts(folderCount: 1, fileCount: 4)
        XCTAssertTrue(throttle.shouldReport(final, at: 10.11, force: true), "강제 보고는 간격을 무시합니다.")
        XCTAssertFalse(throttle.shouldReport(final, at: 20.00, force: true), "강제 보고도 중복은 건너뜁니다.")
    }

    func testDiscoverMediaReportsLiveFolderAndFileCounts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try makePNG().write(to: root.appendingPathComponent("a.png"))
        try makePNG().write(to: outer.appendingPathComponent("b.png"))
        try makePNG().write(to: inner.appendingPathComponent("c.png"))
        try makePNG().write(to: vault.appendingPathComponent("ignored.png"))
        try Data("not media".utf8).write(to: inner.appendingPathComponent("notes.txt"))

        let reports = ProgressSink()
        let files = try VaultProcessor.discoverMedia(in: root) { reports.append($0) }

        XCTAssertEqual(files.count, 3)
        XCTAssertFalse(reports.values.isEmpty, "탐색 중 진행 보고가 최소 한 번은 도착해야 합니다.")
        XCTAssertEqual(reports.values.last, MediaDiscoveryCounts(folderCount: 2, fileCount: 3))
        XCTAssertTrue(reports.isMonotonic, "진행 카운트는 감소하지 않아야 합니다.")
    }

    func testDiscoverFoldersReportsLiveFolderCounts() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer", isDirectory: true)
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let vault = inner.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let reports = ProgressSink()
        let folders = try VaultProcessor.discoverFolders(in: root) { reports.append($0) }

        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(reports.values.last, MediaDiscoveryCounts(folderCount: 2, fileCount: 0))
        XCTAssertTrue(reports.isMonotonic)
    }

    func testDiscoveryWithoutProgressHandlerStillReturnsResults() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makePNG().write(to: sub.appendingPathComponent("photo.png"))

        XCTAssertEqual(try VaultProcessor.discoverMedia(in: root).count, 1)
        XCTAssertEqual(try VaultProcessor.discoverFolders(in: root).count, 1)
    }

    @MainActor
    func testResumeRunMovesFilesThenFoldersThenIdle() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makePNG().write(to: sub.appendingPathComponent("nested.png"))

        let model = try makeIsolatedModel(pinning: root)
        model.selectedFolder = root
        XCTAssertEqual(model.discoveryCounts, .zero)
        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(
            recorder.discoveryTransitions,
            [.idle, .discoveringFiles, .discoveringFolders, .idle, .idle]
        )
        XCTAssertFalse(recorder.sawCleanupAndDiscoveryTogether)
        XCTAssertTrue(model.status.hasPrefix("완료:"))

        XCTAssertEqual(model.discoveryCounts, MediaDiscoveryCounts(folderCount: 1, fileCount: 2))
        XCTAssertEqual(model.totalCount, 3)
        XCTAssertTrue(
            recorder.countsWhileDiscovering.contains { $0.fileCount > 0 || $0.folderCount > 0 },
            "탐색 단계가 활성인 동안 0이 아닌 카운트가 게시되어야 합니다."
        )
        XCTAssertTrue(recorder.countsAreMonotonic, "한 번의 실행 안에서 카운트는 감소하지 않아야 합니다.")
    }

    @MainActor
    func testFreshRunShowsCleanupBeforeDiscoveryAndNeverBoth() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))
        let vault = root.appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let model = try makeIsolatedModel(pinning: root)
        model.selectedFolder = root
        let recorder = PhaseRecorder(model)
        model.startFresh()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.cleanupPhase, .idle)
        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertFalse(recorder.sawCleanupAndDiscoveryTogether)
        let cleanupStart = try XCTUnwrap(recorder.events.firstIndex { $0 == .cleanup(.discovering) })
        let discoveryStart = try XCTUnwrap(recorder.events.firstIndex { $0 == .discovery(.discoveringFiles) })
        XCTAssertLessThan(cleanupStart, discoveryStart)
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFolders))
    }

    @MainActor
    func testNoMediaEarlyReturnResetsDiscoveryPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = try makeIsolatedModel(pinning: root)
        model.selectedFolder = root
        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertFalse(model.hasPendingResume)
        XCTAssertEqual(model.status, "이 폴더에서 지원되는 사진이나 영상을 찾지 못했습니다.")
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFiles))
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFolders))
        XCTAssertEqual(recorder.discoveryTransitions.last, .idle)
    }

    @MainActor
    func testCancelDuringRunResetsDiscoveryPhase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try makeIsolatedModel(pinning: root)
        model.selectedFolder = root
        model.start()
        model.cancel()
        try await waitUntilFinished(model)

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(model.cleanupPhase, .idle)
    }

    @MainActor
    func testSubsequentRunStartsFromIdleDiscoveryAgain() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makePNG().write(to: root.appendingPathComponent("photo.png"))

        let model = try makeIsolatedModel(pinning: root)
        model.selectedFolder = root
        model.start()
        try await waitUntilFinished(model)
        XCTAssertEqual(model.discoveryPhase, .idle)

        let recorder = PhaseRecorder(model)
        model.start()
        try await waitUntilFinished(model)

        XCTAssertEqual(model.discoveryPhase, .idle)
        XCTAssertEqual(recorder.discoveryTransitions.first, .idle)
        XCTAssertTrue(recorder.discoveryTransitions.contains(.discoveringFiles))
        XCTAssertEqual(recorder.discoveryTransitions.last, .idle)
    }

    // MARK: - Helpers

    enum PhaseEvent: Equatable {
        case cleanup(VaultCleanupPhase)
        case discovery(MediaDiscoveryPhase)
    }

    /// Thread-safe collector for progress callbacks that arrive on the
    /// enumeration thread.
    final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MediaDiscoveryCounts] = []

        func append(_ counts: MediaDiscoveryCounts) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(counts)
        }

        var values: [MediaDiscoveryCounts] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var isMonotonic: Bool {
            let values = values
            return zip(values, values.dropFirst()).allSatisfy { earlier, later in
                later.folderCount >= earlier.folderCount && later.fileCount >= earlier.fileCount
            }
        }
    }

    /// Records every published phase change on the main actor so tests can
    /// assert ordering without polling a fast-moving model.
    @MainActor
    final class PhaseRecorder {
        private(set) var events: [PhaseEvent] = []
        private(set) var sawCleanupAndDiscoveryTogether = false
        /// Every `discoveryCounts` value published after the recorder was attached.
        private(set) var counts: [MediaDiscoveryCounts] = []
        /// Subset of `counts` published while a discovery phase was active.
        private(set) var countsWhileDiscovering: [MediaDiscoveryCounts] = []
        private var cancellables: Set<AnyCancellable> = []

        init(_ model: SuperThumbnailMacModel) {
            model.$discoveryPhase
                .dropFirst()
                .sink { [weak self, weak model] phase in
                    self?.events.append(.discovery(phase))
                    if phase.isActive, model?.cleanupPhase.isActive == true {
                        self?.sawCleanupAndDiscoveryTogether = true
                    }
                }
                .store(in: &cancellables)
            model.$discoveryCounts
                .dropFirst()
                .sink { [weak self, weak model] counts in
                    self?.counts.append(counts)
                    if model?.discoveryPhase.isActive == true {
                        self?.countsWhileDiscovering.append(counts)
                    }
                }
                .store(in: &cancellables)
            model.$cleanupPhase
                .dropFirst()
                .sink { [weak self, weak model] phase in
                    self?.events.append(.cleanup(phase))
                    if phase.isActive, model?.discoveryPhase.isActive == true {
                        self?.sawCleanupAndDiscoveryTogether = true
                    }
                }
                .store(in: &cancellables)
        }

        var discoveryTransitions: [MediaDiscoveryPhase] {
            events.compactMap {
                if case let .discovery(phase) = $0 { return phase }
                return nil
            }
        }

        /// True when, after the run's initial reset to zero, no published
        /// count ever decreased.
        var countsAreMonotonic: Bool {
            let afterReset = counts.drop(while: { $0 == .zero })
            return zip(afterReset, afterReset.dropFirst()).allSatisfy { earlier, later in
                later.folderCount >= earlier.folderCount && later.fileCount >= earlier.fileCount
            }
        }
    }

    @MainActor
    private func makeIsolatedModel(pinning root: URL) throws -> SuperThumbnailMacModel {
        let suite = "MediaDiscoveryProgressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(root.path, forKey: "lastSelectedFolder")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
        }
        return SuperThumbnailMacModel(defaults: defaults)
    }

    @MainActor
    private func waitUntilFinished(
        _ model: SuperThumbnailMacModel,
        timeout: TimeInterval = 30
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(model.isRunning, "작업이 \(Int(timeout))초 안에 끝나지 않았습니다.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNG() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw VaultProcessorError.cannotEncode }
        context.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw VaultProcessorError.cannotEncode }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw VaultProcessorError.cannotEncode }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VaultProcessorError.cannotEncode }
        return data as Data
    }
}
