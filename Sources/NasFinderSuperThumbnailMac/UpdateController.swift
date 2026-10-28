import Combine
import Foundation
import Sparkle

enum UpdatePreferenceLogic {
    static func statusText(automaticDownloadEnabled: Bool) -> String {
        automaticDownloadEnabled ? "자동 다운로드 상태: 켬" : "자동 다운로드 상태: 끔"
    }
}

/// 업데이트 설치(종료 후 재실행)를 미뤄야 하는 실제 작업 상태. 창이 보이는지와 무관하게 코디네이터 상태에서 만든다.
struct UpdateWorkActivity: Equatable {
    var thumbnailRunning = false
    var thumbnailPreparing = false
    var localConversionRunning = false
    var localConversionPreparing = false
    var nasHelperActive = false

    var busyReasons: [String] {
        var reasons: [String] = []
        if thumbnailRunning { reasons.append("수퍼썸네일 생성") }
        if thumbnailPreparing { reasons.append("파일 검색·보관함 정리") }
        if localConversionRunning { reasons.append("영상 변환") }
        if localConversionPreparing { reasons.append("영상 준비·복구") }
        if nasHelperActive { reasons.append("NAS 영상 변환 돕기") }
        return reasons
    }

    var isBusy: Bool { !busyReasons.isEmpty }
}

extension UpdateWorkActivity {
    @MainActor
    init(
        model: SuperThumbnailMacModel,
        helper: NASHelperCoordinator,
        local: LocalConversionCoordinator
    ) {
        self.init(
            thumbnailRunning: model.isRunning,
            thumbnailPreparing: model.discoveryPhase.isActive || model.cleanupPhase.isActive,
            localConversionRunning: local.isRunning || local.activeAttemptCount > 0,
            localConversionPreparing: local.isSearching || local.isRecovering,
            nasHelperActive: helper.runState != .stopped || !helper.activeAttemptDetails.isEmpty
        )
    }
}

enum UpdateInstallPolicy {
    /// 내려받은 업데이트가 있을 때만 메뉴 상태 문구를 돌려준다. 없으면 nil(메뉴에 표시하지 않음).
    static func waitingStatusText(pendingVersion: String?, activity: UpdateWorkActivity) -> String? {
        guard let pendingVersion else { return nil }
        guard activity.isBusy else {
            return "업데이트 \(pendingVersion) 설치를 시작합니다"
        }
        return "업데이트 \(pendingVersion) 설치 대기 중 — 작업이 끝나면 자동 설치 (\(activity.busyReasons.joined(separator: ", ")))"
    }
}

/// Sparkle 기반 자동/수동 업데이트 진입점. Info.plist의 SUFeedURL/SUPublicEDKey 등을 그대로 사용한다.
///
/// 확인·다운로드는 항상 허용하고, 설치(종료 후 재실행)만 실제 작업이 없을 때로 미룬다.
/// 대기 중에는 Sparkle 델리게이트가 넘겨준 핸들러를 보관했다가, 작업 상태가 바뀔 때만 다시 평가해 유휴가 되면 호출한다(폴링 없음).
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticDownloadEnabled = true
    /// 내려받았지만 아직 설치되지 않은 업데이트의 표시 버전. 설치 핸들러가 있을 때만 값이 있다.
    @Published private(set) var pendingInstallVersion: String?
    @Published private(set) var activity = UpdateWorkActivity()

    private var updaterController: SPUStandardUpdaterController!
    private var cancellable: AnyCancellable?
    private var activityCancellables: [AnyCancellable] = []
    private var activitySnapshot: (@MainActor () -> UpdateWorkActivity)?

    /// 종료 시 자동 설치 예약(`willInstallUpdateOnQuit`)에서 받은 즉시 설치 핸들러. 여러 번 호출 가능.
    private var installOnQuitHandler: (() -> Void)?
    /// 사용자가 설치를 선택한 뒤 재실행 지연(`shouldPostpone`)에서 받은 핸들러. 한 번만 호출한다.
    private var postponedRelaunchHandler: (() -> Void)?
    private var installTriggered = false

    var installStatusText: String? {
        UpdateInstallPolicy.waitingStatusText(pendingVersion: pendingInstallVersion, activity: activity)
    }

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        automaticDownloadEnabled = updaterController.updater.automaticallyDownloadsUpdates
        cancellable = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.canCheckForUpdates = value
            }
    }

    /// 작업 상태를 관찰한다. 앱 생명주기에서 한 번 연결하며 창 표시 여부와 무관하다.
    func observeActivity(
        changes: [AnyPublisher<Void, Never>],
        snapshot: @escaping @MainActor () -> UpdateWorkActivity
    ) {
        activitySnapshot = snapshot
        activityCancellables = changes.map { publisher in
            publisher
                // objectWillChange는 값이 바뀌기 직전에 발행되므로 다음 메인 루프에서 새 값을 읽는다.
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.reevaluate() }
        }
        activity = snapshot()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticDownloadEnabled(_ enabled: Bool) {
        updaterController.updater.automaticallyDownloadsUpdates = enabled
        automaticDownloadEnabled = updaterController.updater.automaticallyDownloadsUpdates
    }

    // MARK: - 설치 보류/재개

    private func currentActivity() -> UpdateWorkActivity {
        activitySnapshot?() ?? UpdateWorkActivity()
    }

    private func reevaluate() {
        let latest = currentActivity()
        if latest != activity { activity = latest }
        guard installOnQuitHandler != nil || postponedRelaunchHandler != nil else { return }
        if latest.isBusy {
            installTriggered = false
            return
        }
        resumeInstallIfIdle()
    }

    private func resumeInstallIfIdle() {
        guard !currentActivity().isBusy else { return }
        if let handler = postponedRelaunchHandler {
            postponedRelaunchHandler = nil
            pendingInstallVersion = nil
            handler()
            return
        }
        if let handler = installOnQuitHandler, !installTriggered {
            installTriggered = true
            handler()
        }
    }

    private func clearPendingInstall() {
        installOnQuitHandler = nil
        postponedRelaunchHandler = nil
        installTriggered = false
        pendingInstallVersion = nil
    }

    // MARK: - SPUUpdaterDelegate

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // 직접 설치 시점을 맡는다. 작업 중이면 보관만 하고, 유휴가 되면 호출한다.
        installOnQuitHandler = immediateInstallHandler
        installTriggered = false
        pendingInstallVersion = item.displayVersionString
        activity = currentActivity()
        DispatchQueue.main.async { [weak self] in self?.reevaluate() }
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        activity = currentActivity()
        guard activity.isBusy else { return false }
        postponedRelaunchHandler = installHandler
        pendingInstallVersion = item.displayVersionString
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        clearPendingInstall()
    }
}
