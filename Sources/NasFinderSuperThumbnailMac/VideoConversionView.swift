import AppKit
import SwiftUI

/// Native video conversion view for SuperThumbnail Mac ("영상 변환").
///
/// Features & Contract Compliance:
/// - Matches SuperThumbnailMacView native macOS layout and style (neutral gray cards, full-width bar header/footer).
/// - Wires long-lived `LocalConversionCoordinator` with on-demand discovery.
/// - Adheres to 5 Byungki-style themes (auto, light, friday, jarvis, ultron) with 0.5s long-press selection; AUTO uses native system semantic colors.
/// - Concurrency controls bounded to 1...4, matching thumbnail +/- reference.
/// - Truthful cumulative counters (discovered, completed, in-progress, failed, skipped); indefinite indicator during traversal.
/// - Selected folder management with multiple-folder NSOpenPanel and local volume eligibility verification.
/// - In-flight conversion rows with live filename, phase, progress bar, and stage.
/// - Explains original deletion after verified MP4 and SuperThumbnail output in the fixed footer.
/// - Gates execution against concurrent NAS helper pools while keeping existing NAS collaboration accessible.
struct VideoConversionView: View {
    @ObservedObject var coordinator: LocalConversionCoordinator
    @ObservedObject var helperCoordinator: NASHelperCoordinator

    @AppStorage("byungki_style_theme") private var savedThemeRaw: String = ByungkiThemeID.auto.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showingThemePicker = false
    @State private var isLongPressActive = false
    @State private var showingVideoSettings = false

    // MARK: - Computed Theme & Palette

    private var currentThemeID: ByungkiThemeID {
        if savedThemeRaw == "medium" {
            return .light
        } else if savedThemeRaw == "dark" {
            return .jarvis
        }
        return ByungkiThemeID(rawValue: savedThemeRaw) ?? .auto
    }

    private var palette: ByungkiPalette {
        ByungkiPalette.palette(for: currentThemeID, colorScheme: systemColorScheme)
    }

    private var isAutoTheme: Bool {
        currentThemeID == .auto
    }

    private var primaryColor: Color {
        isAutoTheme ? .primary : palette.text
    }

    private var secondaryColor: Color {
        isAutoTheme ? .secondary : palette.text2
    }

    private var accentColor: Color {
        isAutoTheme ? .blue : palette.accent
    }

    private var accentSoftColor: Color {
        isAutoTheme ? Color.blue.opacity(0.12) : palette.accentSoft
    }

    private var dangerColor: Color {
        isAutoTheme ? .red : palette.danger
    }

    private var dangerSoftColor: Color {
        isAutoTheme ? Color.red.opacity(0.12) : palette.dangerSoft
    }

    private var warnColor: Color {
        isAutoTheme ? .orange : palette.warn
    }

    private var warnSoftColor: Color {
        isAutoTheme ? Color.orange.opacity(0.12) : palette.warnSoft
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isAutoTheme {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(palette.card)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.border, lineWidth: 1))
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isAutoTheme {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border2, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private var headerFooterBackground: some View {
        if isAutoTheme {
            Rectangle().fill(.bar)
        } else {
            Rectangle().fill(palette.card)
                .overlay(Rectangle().stroke(palette.border, lineWidth: 1))
        }
    }

    private var isGatedByNASHelper: Bool {
        helperCoordinator.hasActiveWork
    }

    private var directFolders: [LocalFolderItem] {
        coordinator.folders.filter { $0.status.isReady }
    }

    private var nasRoutedFolders: [LocalFolderItem] {
        coordinator.folders.filter { !$0.status.isReady }
    }

    private var targetedHelperFolderIDs: Set<UUID> {
        let selectedURLs = Set(nasRoutedFolders.map { $0.url.standardizedFileURL })
        return Set(helperCoordinator.selectedFolders.filter { selectedURLs.contains($0.url.standardizedFileURL) }.map(\.id))
    }

    private var isAnyRunning: Bool {
        coordinator.isRunning || helperCoordinator.runState.isRunning
    }

    private var isAnyPaused: Bool {
        coordinator.isPaused || helperCoordinator.runState == .paused
    }

    private var showsNASProgress: Bool {
        helperCoordinator.hasActiveWork || (directFolders.isEmpty && !nasRoutedFolders.isEmpty)
    }

    private var displayedConcurrency: Int {
        showsNASProgress ? helperCoordinator.parallelVideoCount : coordinator.maxConcurrentConversions
    }

    private func changeConcurrency(by delta: Int) {
        let value = min(4, max(1, displayedConcurrency + delta))
        if showsNASProgress {
            helperCoordinator.parallelVideoCount = value
        } else {
            coordinator.maxConcurrentConversions = value
        }
    }

    private var canStartAny: Bool {
        if isGatedByNASHelper && !coordinator.isRunning && !coordinator.isPaused {
            return false
        }
        if !directFolders.isEmpty {
            return true
        }
        if !targetedHelperFolderIDs.isEmpty && helperCoordinator.canStartHelper {
            return true
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: 18) {
                    gatingAndNoticeBanners
                    folderManagementCard
                    if showsNASProgress {
                        nasProgressCard
                    } else {
                        progressCard
                    }
                    if !showsNASProgress {
                        recentActivityCard
                    }
                }
                .padding(28)
            }

            footer
        }
        .background(isAutoTheme ? Color(nsColor: .windowBackgroundColor) : palette.bg)
        .preferredColorScheme(isAutoTheme ? nil : (currentThemeID == .light || currentThemeID == .friday ? .light : .dark))
        .sheet(isPresented: $showingVideoSettings) {
            NASHelperDetailsSheet(coordinator: helperCoordinator, palette: palette, isPresented: $showingVideoSettings)
        }
        .onAppear {
            coordinator.onRouteToNAS = { [weak helperCoordinator] url in
                helperCoordinator?.addFolderURLs([url])
            }
            helperCoordinator.isLocalWorkActive = { [weak coordinator] in
                coordinator?.hasActiveWork ?? false
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("NasFinder")
                    .font(.title2.bold())
                    .foregroundStyle(primaryColor)

                Text("Super Thumbnail for Mac · 영상 변환")
                    .font(.subheadline)
                    .foregroundStyle(secondaryColor)
            }

            Spacer()

            themeToggleButton

            Button {
                showingVideoSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(secondaryColor)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("영상 변환 설정")
            .help("자동 시작 및 변환 도구 정보")

            Image(systemName: "cpu")
                .foregroundStyle(secondaryColor)
                .accessibilityHidden(true)

            concurrencyControls
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(headerFooterBackground)
    }

    // MARK: - Theme Toggle (Tap = cycle, 0.5s long-press = menu)

    private var themeToggleButton: some View {
        Button {
            if !isLongPressActive {
                savedThemeRaw = currentThemeID.next.rawValue
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: currentThemeID.iconName)
                    .font(.caption)
                Text(currentThemeID.displayName)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(secondaryColor)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    isLongPressActive = true
                    showingThemePicker = true
                }
        )
        .popover(isPresented: $showingThemePicker, arrowEdge: .bottom) {
            themePickerPopover
        }
        .help("테마 변경 (클릭: 순환, 길게 누르기: 메뉴)")
    }

    private var themePickerPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("병기스타일 테마")
                .font(.caption2.bold())
                .foregroundStyle(secondaryColor)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)

            Divider()

            ForEach(ByungkiThemeID.allCases) { theme in
                Button {
                    savedThemeRaw = theme.rawValue
                    showingThemePicker = false
                    isLongPressActive = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: theme.iconName)
                            .font(.caption)
                            .frame(width: 16)
                            .foregroundStyle(theme == currentThemeID ? accentColor : secondaryColor)

                        Text(theme.displayName)
                            .font(.caption)
                            .foregroundStyle(primaryColor)

                        Spacer()

                        if theme == currentThemeID {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme == currentThemeID ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 160)
        .background(isAutoTheme ? Color(nsColor: .windowBackgroundColor) : palette.card)
    }

    // MARK: - Concurrency Controls (1...4)

    private var concurrencyControls: some View {
        HStack(spacing: 10) {
            Text("인코딩")
                .font(.caption)
                .foregroundStyle(secondaryColor)
            HStack(spacing: 4) {
                Button {
                    changeConcurrency(by: -1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 14, height: 14)
                }
                .disabled(displayedConcurrency <= 1)
                .accessibilityLabel("동시 인코딩 줄이기")

                Text("\(displayedConcurrency)개")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 34)
                    .accessibilityLabel("동시 인코딩 \(displayedConcurrency)개")

                Button {
                    changeConcurrency(by: 1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 14, height: 14)
                }
                .disabled(displayedConcurrency >= 4)
                .accessibilityLabel("동시 인코딩 늘리기")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if coordinator.isRunning {
                Text("처리 \(coordinator.counters.inProgressCount)개")
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
        .help("동시에 인코딩할 영상 개수 (1~4개)")
    }

    // MARK: - Gating & Recovery Notices

    @ViewBuilder
    private var gatingAndNoticeBanners: some View {
        if let notice = coordinator.recoveryNotice {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(accentColor)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(primaryColor)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(accentSoftColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                isAutoTheme
                    ? nil
                    : RoundedRectangle(cornerRadius: 8).stroke(palette.accent.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Folder Management Card (작업 폴더)

    private var folderManagementCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("작업 폴더" + (coordinator.folders.isEmpty ? "" : " (\(coordinator.folders.count))"), systemImage: "folder.fill")
                    .font(.headline)
                    .foregroundStyle(primaryColor)

                Spacer()

                if !coordinator.folders.isEmpty {
                    Button("새로고침") {
                        coordinator.refreshFolders()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(isAnyRunning)
                }

                Button("폴더 선택") {
                    chooseFolders()
                }
                .disabled(isAnyRunning)
                .accessibilityLabel("작업 폴더 선택")
            }

            if coordinator.folders.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("선택된 폴더 없음")
                        .lineLimit(2)
                        .foregroundStyle(secondaryColor)
                    Text("Finder에 마운트된 NAS 폴더나 Mac의 미디어 폴더를 선택할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(coordinator.folders) { folder in
                        folderRow(folder)
                    }
                }
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    private func folderRow(_ folder: LocalFolderItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundStyle(accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)

                Text(folder.path)
                    .font(.caption2)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            statusPill(for: folder.status)

            Button {
                coordinator.removeFolder(id: folder.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(secondaryColor)
            }
            .buttonStyle(.plain)
            .disabled(isAnyRunning)
            .help("목록에서 제거")
            .accessibilityLabel("\(folder.displayName) 제거")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
    }

    private func statusPill(for status: LocalVolumeStatus) -> some View {
        Group {
            switch status {
            case .localReady:
                Text("준비 완료")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentSoftColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(accentColor)
            case .requiresSharedCoordination:
                Text("준비 완료")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentSoftColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(accentColor)
            case .notLocalVolume:
                Text("폴더 연결 확인")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(warnSoftColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(warnColor)
            case .volumeMetadataUnavailable:
                Text("확인 불가")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(dangerSoftColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(dangerColor)
            }
        }
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        // 이전 NAS 경로의 응답이 늦어도 폴더를 고를 수 있도록 로컬에서 시작한다.
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.title = "영상 변환 폴더 선택"
        panel.message = "MP4로 변환할 영상이 포함된 폴더를 선택하세요. 여러 폴더를 선택할 수 있습니다."
        panel.prompt = "선택"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            coordinator.addFolder(url: url)
        }
    }

    // MARK: - Progress Card (변환 진행)

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("변환 진행", systemImage: "film.stack.fill")
                    .font(.headline)
                    .foregroundStyle(primaryColor)

                Spacer()

                if coordinator.isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("새 변환 대상 한 개씩 찾는 중…")
                            .font(.caption)
                            .foregroundStyle(secondaryColor)
                    }
                }
            }

            HStack(spacing: 24) {
                counterMetric("발견", coordinator.counters.discoveredCount, subtext: coordinator.isSearching ? "탐색 중" : "변환 대상", valueColor: primaryColor)
                counterMetric("완료", coordinator.counters.completedCount, subtext: "MP4 완료", valueColor: accentColor)
                counterMetric("진행 중", coordinator.counters.inProgressCount, subtext: "준비·변환·저장", valueColor: primaryColor)
                counterMetric("실패", coordinator.counters.failedCount, subtext: "오류 발생", valueColor: coordinator.counters.failedCount > 0 ? dangerColor : primaryColor)
                counterMetric("건너뜀", coordinator.counters.skippedCount, subtext: "기존 완료/제외", valueColor: secondaryColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("전체 작업 진행").font(.subheadline.bold())
                    Spacer()
                    if let total = coordinator.knownTotalCount {
                        Text("\(coordinator.counters.handledCount) / \(total)개 처리")
                            .font(.body.monospacedDigit().bold())
                    } else {
                        Text("\(coordinator.counters.handledCount)개 처리 · \(coordinator.counters.discoveredCount)개 확인")
                            .font(.body.monospacedDigit().bold())
                    }
                }
                if let total = coordinator.knownTotalCount {
                    ProgressView(value: total > 0 ? min(1, Double(coordinator.counters.handledCount) / Double(total)) : 0)
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                        .scaleEffect(y: 1.6)
                } else if coordinator.isRunning && !coordinator.isPaused {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                        .scaleEffect(y: 1.6)
                } else {
                    ProgressView(value: 0).progressViewStyle(.linear)
                }
                if coordinator.knownTotalCount == nil {
                    Text(coordinator.folders.isEmpty ? "폴더를 선택하면 전체 처리 현황이 표시됩니다." : "전체 대상 확인 중 · 영상을 한 개씩 찾으며 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                }
            }

            if coordinator.activeItems.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(secondaryColor)
                        Text(coordinator.isRunning ? "다음 변환 대상 파일을 확인하고 있습니다." : "대기 중인 변환 작업이 없습니다.")
                            .font(.caption)
                            .foregroundStyle(secondaryColor)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(coordinator.activeItems) { item in
                        activeItemRow(item)
                    }
                }
            }

            if !coordinator.statusMessage.isEmpty {
                Text(coordinator.statusMessage)
                    .font(.callout)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    private func counterMetric(_ label: String, _ value: Int, subtext: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted())
                .font(.title2.monospacedDigit().bold())
                .foregroundStyle(valueColor)
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(primaryColor)
            Text(subtext)
                .font(.caption2)
                .foregroundStyle(secondaryColor)
        }
    }

    private func activeItemRow(_ item: LocalConversionItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "video.fill")
                    .font(.caption)
                    .foregroundStyle(accentColor)

                Text(item.fileName)
                    .font(.caption.bold())
                    .foregroundStyle(primaryColor)
                    .lineLimit(1)

                Spacer()

                Text(item.stage.displayName)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(accentSoftColor, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(accentColor)
            }

            phaseProgress(item.phaseLabel ?? item.stage.displayName,
                          fraction: item.fraction,
                          active: item.stage.isRunning)

            HStack {
                Text(item.relativePath)
                    .font(.caption2)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)

                Spacer()

                if let label = item.phaseLabel {
                    Text(label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(secondaryColor)
                }
            }
        }
        .padding(10)
        .background(rowBackground)
    }

    private func percentageText(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "진행률 확인 중" }
        return "\(Int(min(1, max(0, fraction)) * 100))%"
    }

    private func phaseProgress(_ title: String, fraction: Double?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(fraction?.isFinite == true ? percentageText(fraction) : (active ? "진행률 확인 중" : "대기"))
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(accentColor)
            }
            if let fraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .scaleEffect(y: 1.6)
            } else {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .accessibilityValue(active ? "진행률 확인 중" : "대기")
            }
        }
        .foregroundStyle(primaryColor)
    }

    private var nasProgressCard: some View {
        let counts = helperCoordinator.nasAuthoritativeCounts
        return VStack(alignment: .leading, spacing: 18) {
            Label("전체 작업 진행", systemImage: "film.stack.fill")
                .font(.headline)
            HStack {
                Text("완료 \(counts.completedText) / 확인한 대상 \(counts.totalText)")
                    .font(.title2.monospacedDigit().bold())
                Spacer()
            }
            if let total = counts.totalItems, total > 0, let completed = counts.completedCount {
                ProgressView(value: min(1, max(0, Double(completed) / Double(total))))
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .scaleEffect(y: 1.6)
            } else if helperCoordinator.runState.isRunning {
                ProgressView().progressViewStyle(.linear).tint(accentColor)
            } else {
                ProgressView(value: 0).progressViewStyle(.linear)
            }
            HStack(spacing: 20) {
                Text("남은 작업 \(counts.queuedText)")
                Text("실패 \(counts.failedText)")
                Text("이 기기에서 처리 중 \(helperCoordinator.activeAttemptDetails.count)개")
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(secondaryColor)
            Text("이 기기에서 완료 \(helperCoordinator.localProgress.processedCount)개")
                .font(.caption)
                .foregroundStyle(secondaryColor)
            ForEach(helperCoordinator.activeAttemptDetails) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.fileName)
                        .font(.body.bold())
                        .lineLimit(2)
                        .truncationMode(.middle)
                    switch item.stage {
                    case .downloading:
                        phaseProgress("다운로드", fraction: item.downloadFraction, active: true)
                    case .converting:
                        phaseProgress(item.phaseLabel ?? "인코딩", fraction: item.encodingFraction, active: true)
                    case .uploading:
                        phaseProgress("업로드", fraction: item.uploadFraction, active: true)
                    case .generatingThumbnail:
                        phaseProgress("수퍼썸네일", fraction: nil, active: true)
                    case .waitingVerification:
                        phaseProgress("영상 확인 및 저장", fraction: item.verificationFraction, active: true)
                    case .completed:
                        phaseProgress("완료", fraction: 1, active: false)
                    case .idle, .failed:
                        phaseProgress(item.stage.displayName, fraction: nil, active: false)
                    }
                }
                .padding(12)
                .background(rowBackground)
            }
            if helperCoordinator.runState == .paused {
                Text(helperCoordinator.activeAttemptDetails.isEmpty ? "일시정지됨" : "현재 영상은 계속 처리하고, 다음 영상은 기다립니다.")
                    .font(.callout)
                    .foregroundStyle(secondaryColor)
            } else if helperCoordinator.runState.isRunning && helperCoordinator.activeAttemptDetails.isEmpty {
                Text("다음 영상을 준비하고 있습니다.")
                    .font(.callout)
                    .foregroundStyle(secondaryColor)
            }
            if let error = helperCoordinator.localProgress.lastError {
                DisclosureGroup("처리하지 못한 영상이 있습니다") {
                    Text(error).font(.caption).textSelection(.enabled)
                }
                .foregroundStyle(dangerColor)
            } else if helperCoordinator.runState == .stopped && helperCoordinator.needsManualRestart {
                Text("작업이 중단되었습니다. 폴더 연결을 확인한 뒤 다시 시작해 주세요.")
                    .font(.callout)
                    .foregroundStyle(dangerColor)
            } else if helperCoordinator.runState == .stopped && !helperCoordinator.userStopped && helperCoordinator.connectionStatusText == "도움 정지됨" && counts.jobState != "completed" {
                Text("폴더에 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시작해 주세요.")
                    .font(.callout)
                    .foregroundStyle(dangerColor)
                DisclosureGroup("문제 내용") {
                    Text(helperCoordinator.statusMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(primaryColor)
        .padding(20)
        .background(cardBackground)
    }

    // MARK: - Recent Activity Card (Bounded History)

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("최근 변환 기록" + (coordinator.recentItems.isEmpty ? "" : " (\(coordinator.recentItems.count))"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(primaryColor)

                Spacer()

                if !coordinator.recentItems.isEmpty {
                    Button("기록 지우기") {
                        coordinator.clearHistory()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            if coordinator.recentItems.isEmpty {
                HStack {
                    Spacer()
                    Text("완료된 작업 기록이 여기에 표시됩니다.")
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(coordinator.recentItems.prefix(10)) { item in
                        recentItemRow(item)
                    }
                }
            }
        }
        .padding(20)
        .background(cardBackground)
    }

    private func recentItemRow(_ item: LocalConversionItem) -> some View {
        HStack {
            Image(systemName: item.stage == .completed ? "checkmark.circle.fill" : (item.stage.displayName.hasPrefix("실패") ? "xmark.circle.fill" : "info.circle"))
                .font(.caption2)
                .foregroundStyle(item.stage == .completed ? Color.green : (item.stage.displayName.hasPrefix("실패") ? dangerColor : secondaryColor))

            Text(item.fileName)
                .font(.caption2.bold())
                .foregroundStyle(primaryColor)
                .lineLimit(1)

            Spacer()

            Text(item.statusMessage)
                .font(.caption2)
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(rowBackground)
    }

    // MARK: - Fixed Bottom Bar (Footer)

    private var footer: some View {
        VStack(spacing: 12) {
            Text("변환된 MP4와 수퍼썸네일을 정상 확인한 뒤 원본을 삭제합니다. 확인하지 못한 원본은 남겨 둡니다.")
                .font(.caption)
                .foregroundStyle(secondaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Text("SuperThumbnail v2.7.3 • macOS 네이티브 영상 변환")
                    .font(.caption2)
                    .foregroundStyle(secondaryColor)

                Spacer()

                if isAnyRunning {
                    Button("일시정지") {
                        if coordinator.isRunning {
                            coordinator.pause()
                        }
                        if helperCoordinator.runState.isRunning {
                            helperCoordinator.pauseHelper()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("일시정지")

                    Button("변환 중지", role: .destructive) {
                        if coordinator.isRunning || coordinator.isPaused {
                            coordinator.stop()
                        }
                        if helperCoordinator.runState != .stopped {
                            helperCoordinator.stopHelper()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("변환 중지")
                } else if isAnyPaused {
                    Button("변환 재개") {
                        if coordinator.isPaused {
                            coordinator.resume()
                        }
                        if helperCoordinator.runState == .paused {
                            helperCoordinator.resumeHelper()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("변환 재개")

                    Button("변환 중지", role: .destructive) {
                        if coordinator.isRunning || coordinator.isPaused {
                            coordinator.stop()
                        }
                        if helperCoordinator.runState != .stopped {
                            helperCoordinator.stopHelper()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel("변환 중지")
                } else {
                    Button("변환 시작") {
                        startUnifiedConversion()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canStartAny)
                    .help(startHelpText)
                    .accessibilityLabel("변환 시작")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(headerFooterBackground)
    }

    private var startHelpText: String {
        if isGatedByNASHelper {
            return "현재 영상 처리가 끝나면 새 작업을 시작할 수 있습니다."
        }
        if coordinator.folders.isEmpty {
            return "변환할 폴더를 추가해 주세요."
        }
        if directFolders.isEmpty && targetedHelperFolderIDs.isEmpty {
            return "선택한 폴더에 연결할 수 있는지 확인해 주세요."
        }
        return "선택한 폴더의 영상 변환을 시작합니다."
    }

    private func startUnifiedConversion() {
        let targets = targetedHelperFolderIDs
        if !directFolders.isEmpty {
            if !targets.isEmpty {
                coordinator.onDirectWorkCompleted = { [weak helperCoordinator] in
                    guard let helperCoordinator else { return }
                    if helperCoordinator.canStartHelper {
                        helperCoordinator.startHelper(targetFolderIDs: targets)
                    }
                }
            }
            coordinator.start()
        } else if !targets.isEmpty {
            helperCoordinator.startHelper(targetFolderIDs: targets)
        }
    }
}
