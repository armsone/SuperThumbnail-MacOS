import XCTest
@testable import NasFinderSuperThumbnailMac

final class UpdatePreferenceLogicTests: XCTestCase {
    func testAutomaticDownloadStatusIsExplicit() {
        XCTAssertEqual(UpdatePreferenceLogic.statusText(automaticDownloadEnabled: true), "자동 다운로드 상태: 켬")
        XCTAssertEqual(UpdatePreferenceLogic.statusText(automaticDownloadEnabled: false), "자동 다운로드 상태: 끔")
    }
}

final class UpdateInstallPolicyTests: XCTestCase {
    func testIdleActivityIsNotBusy() {
        XCTAssertFalse(UpdateWorkActivity().isBusy)
        XCTAssertTrue(UpdateWorkActivity().busyReasons.isEmpty)
    }

    func testEveryWorkKindDefersInstall() {
        XCTAssertTrue(UpdateWorkActivity(thumbnailRunning: true).isBusy)
        XCTAssertTrue(UpdateWorkActivity(thumbnailPreparing: true).isBusy)
        XCTAssertTrue(UpdateWorkActivity(localConversionRunning: true).isBusy)
        XCTAssertTrue(UpdateWorkActivity(localConversionPreparing: true).isBusy)
        XCTAssertTrue(UpdateWorkActivity(nasHelperActive: true).isBusy)
    }

    func testNoStatusWithoutDownloadedUpdate() {
        XCTAssertNil(UpdateInstallPolicy.waitingStatusText(pendingVersion: nil, activity: UpdateWorkActivity(nasHelperActive: true)))
    }

    func testWaitingStatusNamesVersionAndReasons() {
        let text = UpdateInstallPolicy.waitingStatusText(
            pendingVersion: "2.7.15",
            activity: UpdateWorkActivity(localConversionRunning: true, nasHelperActive: true)
        )
        XCTAssertEqual(text, "업데이트 2.7.15 설치 대기 중 — 작업이 끝나면 자동 설치 (영상 변환, NAS 영상 변환 돕기)")
    }

    func testIdleStatusAnnouncesInstallStart() {
        XCTAssertEqual(
            UpdateInstallPolicy.waitingStatusText(pendingVersion: "2.7.15", activity: UpdateWorkActivity()),
            "업데이트 2.7.15 설치를 시작합니다"
        )
    }
}
