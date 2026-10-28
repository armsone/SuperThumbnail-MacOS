import XCTest
@testable import NasFinderSuperThumbnailMac

final class LocalIdentityDiagnosticsTests: XCTestCase {
    func testDifferencesNameExactFieldsAndEqualIsEmpty() {
        let a = LocalFileIdentity(device: 1, inode: 2, size: 3, mtime: 100, mtime_nsec: 0, ctime: 100, ctime_nsec: 0)
        let b = LocalFileIdentity(device: 1, inode: 2, size: 3, mtime: 200, mtime_nsec: 0, ctime: 200, ctime_nsec: 0)
        XCTAssertTrue(a.differences(from: a).isEmpty)
        XCTAssertEqual(b.differences(from: a), ["mtime(100.0→200.0)", "ctime(100.0→200.0)"])
        XCTAssertTrue(b.isTimestampOnlyDrift(from: a))
    }

    func testCleanupSummaryReportsClaimNoticeAndWorkspace() {
        let state = LocalAttemptCleanupState()
        XCTAssertTrue(state.isFullyCleaned)
        XCTAssertEqual(state.pendingSummary, "")
        state.setClaimPending(true)
        state.setClaimNotice("클레임 디렉터리 정리 미완료 (errno=66): 디렉터리 보존됨")
        state.setWorkspacePending(true)
        XCTAssertFalse(state.isFullyCleaned)
        XCTAssertTrue(state.pendingSummary.contains("errno=66"))
        XCTAssertTrue(state.pendingSummary.contains("작업공간"))
    }
}
