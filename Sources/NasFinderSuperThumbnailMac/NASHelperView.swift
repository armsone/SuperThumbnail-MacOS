import SwiftUI

// MARK: - Byungki-Style Theme Definitions & Palette Tokens

/// Supported Byungki-style 5 themes.
/// Order: auto -> light -> friday -> jarvis -> ultron -> auto.
enum ByungkiThemeID: String, CaseIterable, Identifiable {
    case auto = "auto"
    case light = "light"
    case friday = "friday"
    case jarvis = "jarvis"
    case ultron = "ultron"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "자동"
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    var iconName: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .friday: return "shield.lefthalf.filled"
        case .jarvis: return "waveform.circle"
        case .ultron: return "bolt.shield.fill"
        }
    }

    var next: ByungkiThemeID {
        switch self {
        case .auto: return .light
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        case .ultron: return .auto
        }
    }
}

/// Tokenized palette adhering to the Byungki-style theme contract.
struct ByungkiPalette {
    let bg: Color
    let card: Color
    let surface: Color
    let surface2: Color
    let text: Color
    let text2: Color
    let muted: Color
    let border: Color
    let border2: Color
    let accent: Color
    let accentStrong: Color
    let accentSoft: Color
    let onAccent: Color
    let warn: Color
    let warnSoft: Color
    let warnInk: Color
    let danger: Color
    let dangerSoft: Color

    static func palette(for id: ByungkiThemeID, colorScheme: ColorScheme) -> ByungkiPalette {
        let activeID: ByungkiThemeID
        if id == .auto {
            activeID = (colorScheme == .dark) ? .jarvis : .light
        } else {
            activeID = id
        }

        switch activeID {
        case .auto, .light:
            return lightPalette
        case .friday:
            return fridayPalette
        case .jarvis:
            return jarvisPalette
        case .ultron:
            return ultronPalette
        }
    }

    static let lightPalette = ByungkiPalette(
        bg: Color(hex: 0xf5f4f0),
        card: Color(hex: 0xfbfaf7),
        surface: Color(hex: 0xffffff),
        surface2: Color(hex: 0xecebe4),
        text: Color(hex: 0x1f211c),
        text2: Color(hex: 0x4a4c44),
        muted: Color(hex: 0x666860),
        border: Color(hex: 0xe2dfd5),
        border2: Color(hex: 0xd0cdc0),
        accent: Color(hex: 0x5c6b3c),
        accentStrong: Color(hex: 0x46532c),
        accentSoft: Color(hex: 0xe8ebdb),
        onAccent: Color(hex: 0xffffff),
        warn: Color(hex: 0x9c5415),
        warnSoft: Color(hex: 0xf7e9d8),
        warnInk: Color(hex: 0x6d3c10),
        danger: Color(hex: 0x9c3b2a),
        dangerSoft: Color(hex: 0xf6e3de)
    )

    static let fridayPalette = ByungkiPalette(
        bg: Color(hex: 0xf7efe3),
        card: Color(hex: 0xfffaf1),
        surface: Color(hex: 0xfffdf8),
        surface2: Color(hex: 0xf0e2cc),
        text: Color(hex: 0x2a1f16),
        text2: Color(hex: 0x55422f),
        muted: Color(hex: 0x725b45),
        border: Color(hex: 0xe8d8c0),
        border2: Color(hex: 0xd3bb98),
        accent: Color(hex: 0x9a4a12),
        accentStrong: Color(hex: 0x743508),
        accentSoft: Color(hex: 0xf6dfc0),
        onAccent: Color(hex: 0xffffff),
        warn: Color(hex: 0x8a5a00),
        warnSoft: Color(hex: 0xf8e6b8),
        warnInk: Color(hex: 0x6d3c10),
        danger: Color(hex: 0xa3204a),
        dangerSoft: Color(hex: 0xf8dce4)
    )

    static let jarvisPalette = ByungkiPalette(
        bg: Color(hex: 0x0c1420),
        card: Color(hex: 0x121c2b),
        surface: Color(hex: 0x162337),
        surface2: Color(hex: 0x1c2d44),
        text: Color(hex: 0xe3edf7),
        text2: Color(hex: 0xb3c4d6),
        muted: Color(hex: 0x8da2b8),
        border: Color(hex: 0x20324a),
        border2: Color(hex: 0x2d4663),
        accent: Color(hex: 0x4cc2e6),
        accentStrong: Color(hex: 0x8fdcf3),
        accentSoft: Color(hex: 0x12324a),
        onAccent: Color(hex: 0x04202b),
        warn: Color(hex: 0xf0b45c),
        warnSoft: Color(hex: 0x3a2d16),
        warnInk: Color(hex: 0xf4cf94),
        danger: Color(hex: 0xf28b82),
        dangerSoft: Color(hex: 0x3d2126)
    )

    static let ultronPalette = ByungkiPalette(
        bg: Color(hex: 0x121316),
        card: Color(hex: 0x1a1c20),
        surface: Color(hex: 0x202328),
        surface2: Color(hex: 0x272a30),
        text: Color(hex: 0xe6e7ea),
        text2: Color(hex: 0xb8bbc2),
        muted: Color(hex: 0x8e929b),
        border: Color(hex: 0x2b2e34),
        border2: Color(hex: 0x3b3f47),
        accent: Color(hex: 0xf2566a),
        accentStrong: Color(hex: 0xff8a95),
        accentSoft: Color(hex: 0x3a1a20),
        onAccent: Color(hex: 0x1a0508),
        warn: Color(hex: 0xe8a24f),
        warnSoft: Color(hex: 0x36291a),
        warnInk: Color(hex: 0xf2c27f),
        danger: Color(hex: 0xff9a9a),
        dangerSoft: Color(hex: 0x3e1f22)
    )
}

private extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

// MARK: - Visual State Classification (3-Second Glance Support)

private enum HelperVisualState {
    case circuitBreaker(message: String)
    case error(message: String)
    case warning(message: String)
    case running(stage: String)
    case paused
    case idle
}

// MARK: - Main NASHelperView

/// Simplified macOS view for "NAS 영상 변환 돕기" (NAS Video Conversion Helper) mode.
///
/// Features & Contract Compliance:
/// - Fits standard 800x600 viewport without outer page scrolling.
/// - Prominent, concise '협업 시작' (and pause/stop) controls.
/// - Live current filename, file stage icon/name, progress percentage/bar.
/// - Clear authoritative NAS overall counts vs. local Mac current session counts (previous runs strictly separated).
/// - Visible error banner with clear next action; circuit breaker failure requires explicit manual restart.
/// - Multiple folder add, remove, and refresh retained in a bounded list with mount/recovery hints.
/// - Real compact parallel-file count stepper bound to `coordinator.parallelVideoCount` (1...4).
/// - Honest parallelStatus.active/effective and note/diskNote reporting without claiming 4 active on single root.
/// - Auto-participation toggle and clean settings in details sheet; no wall of text or internal UUIDs.
/// - Native accessible Byungki-style theme support with 500ms long-press menu without tap advance.
struct NASHelperView: View {
    @ObservedObject var coordinator: NASHelperCoordinator
    var localCoordinator: LocalConversionCoordinator? = nil

    @AppStorage("byungki_style_theme") private var savedThemeRaw: String = ByungkiThemeID.auto.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showingDetailsSheet = false
    @State private var showingThemePicker = false
    @State private var isLongPressActive = false

    // MARK: - Computed Theme & Visual State

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

    private var currentVisualState: HelperVisualState {
        if coordinator.needsManualRestart {
            let message = coordinator.localProgress.lastError ?? coordinator.statusMessage
            return .circuitBreaker(message: message)
        }
        if !coordinator.toolEnvironment.isReadyToExecute {
            return .error(message: coordinator.toolEnvironment.diagnosticMessage)
        }
        if coordinator.runState.isRunning {
            return .running(stage: runningStageDisplayName)
        }
        if coordinator.runState == .paused {
            return .paused
        }
        let registeredCount = coordinator.selectedFolders.filter { $0.isRegisteredRoot }.count
        if !coordinator.selectedFolders.isEmpty && registeredCount == 0 && coordinator.pendingResolveIDs.isEmpty {
            return .warning(message: "선택한 폴더 중 NAS 앱에 등록된 폴더가 없습니다.")
        }
        if let error = coordinator.localProgress.lastError, !error.isEmpty {
            return .error(message: error)
        }
        return .idle
    }

    /// True while at least one attempt is really running and nothing blocks new work (no disk hold).
    /// Root blocked / manual restart while attempts still run: no NEW work is taken, the running ones are finishing.
    private var isFinishingActiveWork: Bool {
        coordinator.needsManualRestart && !coordinator.activeAttemptDetails.isEmpty
    }

    private var shouldShowHistoricalError: Bool {
        (coordinator.runState.isRunning || coordinator.runState == .paused) && !coordinator.needsManualRestart
    }

    private var runningStageDisplayName: String {
        if let first = coordinator.activeAttemptDetails.first {
            return first.stage.displayName
        }
        if coordinator.localProgress.stage == .completed {
            return "변환 완료"
        }
        return "작업 확인"
    }

    private var stagePillText: String {
        if coordinator.localProgress.stage == .completed {
            return "변환 완료"
        }
        if coordinator.runState.isRunning {
            return runningStageDisplayName
        }
        return coordinator.localProgress.stage.displayName
    }

    // MARK: - Body (Scroll-Free Default Layout)

    var body: some View {
        VStack(spacing: 10) {
            headerView
            statusAlertBanner
            liveProgressCard
            countsSummaryCard
            folderListCard
            bottomStatusBar
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg)
        .sheet(isPresented: $showingDetailsSheet) {
            NASHelperDetailsSheet(coordinator: coordinator, palette: palette, isPresented: $showingDetailsSheet)
        }
    }

    // MARK: - Header & Controls

    private var headerView: some View {
        HStack(spacing: 10) {
            // Title & Status Badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("NAS 영상 변환 돕기")
                        .font(.title3.bold())
                        .foregroundStyle(palette.text)

                    headerStatusBadge
                }

                Text("Mac에서 영상을 MP4로 변환하여 NAS 작업을 분담합니다.")
                    .font(.caption)
                    .foregroundStyle(palette.text2)
            }

            Spacer()

            // Theme Cycle / Long-Press Selection
            themeButton

            // Concurrency Stepper (Real Core Integration: 1...4)
            concurrencyStepper

            // Primary Action Button ("협업 시작" / 일시정지 / 협업 중지)
            primaryActionButtons

            // Collapsed Details / Diagnostics Button
            Button {
                showingDetailsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("세부 정보")
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.text2)
            .help("변환 도구 환경 진단, 자동 협업 및 규격 설정 보기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
    }

    private var headerStatusBadge: some View {
        HStack(spacing: 6) {
            switch currentVisualState {
            case .circuitBreaker:
                Circle()
                    .fill(palette.danger)
                    .frame(width: 8, height: 8)
                Text(isFinishingActiveWork ? "새 작업 받기 중지" : "반복 실패로 중지됨")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.danger)
            case .error:
                Circle()
                    .fill(palette.danger)
                    .frame(width: 8, height: 8)
                Text("오류 확인 필요")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.danger)
            case .warning:
                Circle()
                    .fill(palette.warn)
                    .frame(width: 8, height: 8)
                Text("설정 확인 필요")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.warn)
            case .running(let stage):
                Circle()
                    .fill(palette.accent)
                    .frame(width: 8, height: 8)
                Text((stage == "변환 완료" || stage.hasSuffix("완료")) ? stage : "\(stage) 진행 중")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.accentStrong)
            case .paused:
                Circle()
                    .fill(palette.warn)
                    .frame(width: 8, height: 8)
                Text("일시정지됨")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.warn)
            case .idle:
                Circle()
                    .fill(palette.muted)
                    .frame(width: 8, height: 8)
                Text(coordinator.connectionStatusText)
                    .font(.caption2.bold())
                    .foregroundStyle(palette.text2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Byungki-Style Theme Button (500ms Long-Press Contract)

    private var themeButton: some View {
        Button {
            if isLongPressActive {
                isLongPressActive = false
                return
            }
            cycleTheme()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: currentThemeID.iconName)
                    .font(.caption.bold())
                    .foregroundStyle(palette.accent)
                Text(currentThemeID.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    isLongPressActive = true
                    showingThemePicker = true
                }
        )
        .accessibilityLabel("병기스타일 테마: \(currentThemeID.displayName) (누르면 \(currentThemeID.next.displayName), 길게 누르면 목록)")
        .accessibilityValue(currentThemeID.displayName)
        .help("테마 변경: 현재 \(currentThemeID.displayName) (클릭: 순환 변경, 500ms 길게 누르기 또는 우클릭: 목록 선택)")
        .contextMenu {
            themeMenuItems
        }
        .popover(isPresented: $showingThemePicker, arrowEdge: .bottom) {
            themePickerPopover
        }
    }

    private func cycleTheme() {
        savedThemeRaw = currentThemeID.next.rawValue
    }

    @ViewBuilder
    private var themeMenuItems: some View {
        ForEach(ByungkiThemeID.allCases) { theme in
            Button {
                savedThemeRaw = theme.rawValue
            } label: {
                HStack {
                    Text(theme.displayName)
                    if currentThemeID == theme {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private var themePickerPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("병기스타일 테마")
                .font(.caption2.bold())
                .foregroundStyle(palette.muted)
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
                            .foregroundStyle(theme == currentThemeID ? palette.accent : palette.text2)

                        Text(theme.displayName)
                            .font(.caption)
                            .foregroundStyle(palette.text)

                        Spacer()

                        if theme == currentThemeID {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme == currentThemeID ? palette.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 160)
        .background(palette.card)
    }

    // MARK: - Parallel Video Stepper (Read/Write coordinator.parallelVideoCount)

    private var concurrencyStepper: some View {
        HStack(spacing: 6) {
            Text("동시 변환:")
                .font(.caption)
                .foregroundStyle(palette.text2)

            Stepper(
                value: Binding<Int>(
                    get: { coordinator.parallelVideoCount },
                    set: { coordinator.parallelVideoCount = $0 }
                ),
                in: NASHelperPipelineConfiguration.minParallelVideoCount...NASHelperPipelineConfiguration.maxParallelVideoCount
            ) {
                HStack(spacing: 4) {
                    Text("\(coordinator.parallelVideoCount)개")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(palette.text)

                    if coordinator.runState.isRunning {
                        Text("(실제 \(coordinator.parallelStatus.active)/\(coordinator.parallelStatus.effective))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.muted)
                    }
                }
            }
            .help(stepperHelpText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
    }

    private var stepperHelpText: String {
        if let note = coordinator.parallelStatus.note {
            return note
        }
        if let disk = coordinator.parallelStatus.diskNote {
            return disk
        }
        return "동시에 변환할 영상 개수 (1~\(NASHelperPipelineConfiguration.maxParallelVideoCount)개, 실행 중 변경 가능)"
    }

    // MARK: - Primary Action Controls ("협업 시작" / 일시정지 / 협업 중지)

    @ViewBuilder
    private var primaryActionButtons: some View {
        if coordinator.runState.isRunning {
            HStack(spacing: 6) {
                Button("일시정지") {
                    coordinator.pauseHelper()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("협업 중지", role: .destructive) {
                    coordinator.stopHelper()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.danger)
                .controlSize(.regular)
            }
        } else if coordinator.runState == .paused {
            HStack(spacing: 6) {
                Button("협업 재개") {
                    coordinator.resumeHelper()
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.regular)

                Button("협업 중지", role: .destructive) {
                    coordinator.stopHelper()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } else {
            let isLocalActive = (localCoordinator?.hasActiveWork ?? false) || (coordinator.isLocalWorkActive?() ?? false)
            let canStart = coordinator.canStartHelper && !isLocalActive
            Button {
                coordinator.startHelper()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.caption)
                    Text("협업 시작")
                        .font(.subheadline.bold())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canStart ? palette.onAccent : palette.muted)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(canStart ? palette.accent : palette.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(canStart ? palette.accentStrong : palette.border, lineWidth: 1)
            )
            .disabled(!canStart)
            .help(isLocalActive ? "로컬 영상 변환이 실행 중입니다. 동시 실행 방지를 위해 대기합니다." : startHelperHelpText)
        }
    }

    private var startHelperHelpText: String {
        if coordinator.needsManualRestart {
            return "반복 실패가 발생했습니다. '협업 시작'을 눌러 수동으로 다시 시도하세요."
        }
        if coordinator.canStartHelper {
            return "NAS 영상 변환 협업 작업을 시작합니다."
        }
        if !coordinator.toolEnvironment.isReadyToExecute {
            return "변환 도구(ffmpeg/python3) 준비가 필요합니다."
        }
        if coordinator.selectedFolders.isEmpty {
            return "변환할 NAS 폴더를 먼저 추가해 주세요."
        }
        if !coordinator.selectedFolders.contains(where: { $0.isRegisteredRoot }) {
            return "NAS 앱에 등록된 폴더가 필요합니다."
        }
        if !coordinator.pendingResolveIDs.isEmpty {
            return "폴더 등록 정보를 확인 중입니다…"
        }
        return "협업을 시작할 수 없는 상태입니다."
    }

    // MARK: - Status Alert Banner (Errors / Warnings / Circuit Breaker)

    @ViewBuilder
    private var statusAlertBanner: some View {
        if let local = localCoordinator, local.hasActiveWork {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(palette.warn)
                Text("로컬 영상 변환이 실행 중입니다. 동시 실행 방지를 위해 NAS 협업 시작이 대기됩니다.")
                    .font(.caption)
                    .foregroundStyle(palette.warnInk)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.warnSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.warn.opacity(0.3), lineWidth: 1))
        }

        switch currentVisualState {
        case .circuitBreaker(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isFinishingActiveWork ? "새 작업 받기 중지 · 기존 작업 마무리 중" : "반복 실패로 협업이 자동 정지되었습니다.")
                            .font(.caption.bold())
                            .foregroundStyle(palette.danger)
                        Text("(수동 재시작 필요)")
                            .font(.caption2)
                            .foregroundStyle(palette.text2)
                    }
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(palette.text2)
                        .lineLimit(2)
                }
                Spacer()
                Button("협업 다시 시작") {
                    coordinator.startHelper()
                }
                .disabled(isFinishingActiveWork || !coordinator.canStartHelper || (coordinator.isLocalWorkActive?() ?? false) || (localCoordinator?.hasActiveWork ?? false))
                .font(.caption.bold())
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.dangerSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.danger.opacity(0.4), lineWidth: 1))

        case .error(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(palette.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg)
                        .font(.caption.bold())
                        .foregroundStyle(palette.danger)
                    Text("네트워크 연결 또는 로컬 변환 도구 상태를 확인하세요. [세부 정보]에서 진단을 확인할 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(palette.text2)
                }
                Spacer()
                Button("도구 점검") {
                    showingDetailsSheet = true
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.dangerSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.danger.opacity(0.4), lineWidth: 1))

        case .warning(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(msg)
                        .font(.caption.bold())
                        .foregroundStyle(palette.warnInk)
                    Text("NAS 앱에서 이 폴더의 협업 작업을 등록한 후 새로고침해 주세요.")
                        .font(.caption2)
                        .foregroundStyle(palette.text2)
                }
                Spacer()
                Button("새로고침", action: coordinator.refreshFolders)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.warnSoft, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.warn.opacity(0.4), lineWidth: 1))

        default:
            if let autoNote = coordinator.autoResumeNote, !autoNote.isEmpty, coordinator.runState == .stopped {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(palette.muted)
                    Text(autoNote)
                        .font(.caption2)
                        .foregroundStyle(palette.text2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Live Progress Card (3-Second Glance: File / Stage / Progress)

    private var liveProgressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("내 Mac 변환 상태", systemImage: "macbook.and.iphone")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.text)

                Spacer()

                HStack(spacing: 5) {
                    Image(systemName: coordinator.localProgress.stage.systemImage)
                        .font(.caption.bold())
                    Text(stagePillText)
                        .font(.caption.bold())
                }
                .foregroundStyle(coordinator.runState.isRunning ? palette.accentStrong : palette.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(coordinator.runState.isRunning ? palette.accentSoft : palette.surface2, in: Capsule())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(coordinator.localProgress.currentFileName ?? (coordinator.runState.isRunning ? "NAS 작업 배정 대기 중…" : "변환 대기 중"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(coordinator.localProgress.progressText)
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(palette.text2)
                }

                if let fraction = coordinator.localProgress.stageFraction {
                    ProgressView(value: fraction)
                        .tint(palette.accent)
                } else if coordinator.runState.isRunning {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                } else {
                    ProgressView(value: 0)
                        .tint(palette.muted)
                }
            }

            // Session Counters & Parallel Notes
            HStack(spacing: 8) {
                Text("이번 세션 완료: \(coordinator.localProgress.processedCount)개")
                    .font(.caption)
                    .foregroundStyle(palette.text2)

                Text("•")
                    .font(.caption)
                    .foregroundStyle(palette.muted)

                Text("이번 세션 실패: \(coordinator.localProgress.failedCount)개")
                    .font(.caption)
                    .foregroundStyle(coordinator.localProgress.failedCount > 0 ? palette.danger : palette.text2)

                if coordinator.runState.isRunning {
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(palette.muted)

                    Text("실제 활성: \(coordinator.parallelStatus.active)/\(coordinator.parallelStatus.effective)개")
                        .font(.caption)
                        .foregroundStyle(palette.text2)
                }

                Spacer()

                if let phase = coordinator.localProgress.phaseLabel, !phase.isEmpty {
                    Text(phase)
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }

            // An earlier failure stays visible (not red) while other work is healthy; the counter above keeps counting it.
            if shouldShowHistoricalError, let lastError = coordinator.localProgress.lastError, !lastError.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(palette.warn)
                    Text("이전 실패(진행 중 작업과 별개): \(lastError)")
                        .font(.caption2)
                        .foregroundStyle(palette.warnInk)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            // Compact Parallel / Disk Notes (Only when present)
            if let note = coordinator.parallelStatus.note, !note.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(palette.warn)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(palette.warnInk)
                        .lineLimit(1)
                }
            }

            if let diskNote = coordinator.parallelStatus.diskNote, !diskNote.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(palette.warn)
                    Text(diskNote)
                        .font(.caption2)
                        .foregroundStyle(palette.warnInk)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Authoritative vs Session Counts Grid

    private var countsSummaryCard: some View {
        HStack(spacing: 8) {
            summaryTile(
                title: "전체 대상",
                mainValue: coordinator.nasAuthoritativeCounts.totalText,
                subtext: "NAS 총 작업",
                valueColor: palette.text
            )
            summaryTile(
                title: "완료",
                mainValue: coordinator.nasAuthoritativeCounts.completedText,
                subtext: "내 Mac: \(coordinator.localProgress.processedCount)개",
                valueColor: palette.text
            )
            summaryTile(
                title: "남은 작업",
                mainValue: coordinator.nasAuthoritativeCounts.queuedText,
                subtext: "대기 중",
                valueColor: palette.text
            )
            summaryTile(
                title: "실패",
                mainValue: coordinator.nasAuthoritativeCounts.failedText,
                subtext: "내 Mac: \(coordinator.localProgress.failedCount)개",
                valueColor: (coordinator.nasAuthoritativeCounts.failedCount ?? 0) > 0 || coordinator.localProgress.failedCount > 0 ? palette.danger : palette.text
            )
        }
    }

    private func summaryTile(title: String, mainValue: String, subtext: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(palette.text2)
            Text(mainValue)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(subtext)
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Bounded Folder Management Card

    private var folderListCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("변환 대상 폴더 (\(coordinator.selectedFolders.count))", systemImage: "folder.badge.gearshape")
                    .font(.subheadline.bold())
                    .foregroundStyle(palette.text)

                Spacer()

                Button("새로고침") {
                    coordinator.refreshFolders()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(palette.text2)

                Button("폴더 추가…") {
                    coordinator.addFolders()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(coordinator.runState.isRunning)

                if !coordinator.selectedFolders.isEmpty && !coordinator.runState.isRunning {
                    Button("목록 비우기") {
                        coordinator.clearAllFolders()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.danger)
                }
            }

            if coordinator.selectedFolders.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.body)
                        .foregroundStyle(palette.muted)
                    Text("Finder에 연결된 NAS 폴더를 추가해 주세요. (NAS 앱에 등록된 폴더)")
                        .font(.caption)
                        .foregroundStyle(palette.text2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 5) {
                        ForEach(coordinator.selectedFolders) { folder in
                            HStack(spacing: 8) {
                                Image(systemName: folder.isRegisteredRoot ? "folder.fill" : (folder.mountIssue != nil ? "externaldrive.badge.xmark" : "folder.badge.questionmark"))
                                    .foregroundStyle(folder.isRegisteredRoot ? palette.accent : (folder.mountIssue != nil ? palette.danger : palette.warn))
                                    .font(.body)

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(folder.displayName)
                                            .font(.caption.bold())
                                            .foregroundStyle(palette.text)

                                        if folder.isRemembered {
                                            Text("자동 복원")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(palette.muted)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(palette.surface2, in: RoundedRectangle(cornerRadius: 3))
                                        }
                                    }

                                    if let recovery = folder.recoveryText {
                                        Text(recovery)
                                            .font(.caption2)
                                            .foregroundStyle(palette.danger)
                                            .lineLimit(1)
                                    } else if let error = folder.registrationError {
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(palette.warnInk)
                                            .lineLimit(1)
                                    } else {
                                        Text(folder.path)
                                            .font(.caption2)
                                            .foregroundStyle(palette.muted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }

                                Spacer()

                                if folder.isRegisteredRoot {
                                    Text("협업 등록됨")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color.green)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                } else if folder.mountIssue != nil {
                                    Text("연결 확인 필요")
                                        .font(.caption2.bold())
                                        .foregroundStyle(palette.danger)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.dangerSoft, in: RoundedRectangle(cornerRadius: 4))
                                } else {
                                    Text("NAS 등록 필요")
                                        .font(.caption2.bold())
                                        .foregroundStyle(palette.warnInk)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(palette.warnSoft, in: RoundedRectangle(cornerRadius: 4))
                                }

                                Button {
                                    coordinator.removeFolder(id: folder.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(palette.muted)
                                }
                                .buttonStyle(.plain)
                                .disabled(coordinator.runState.isRunning)
                                .help("목록에서 제거")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border2, lineWidth: 0.5))
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
        }
        .padding(10)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Bottom Status Bar

    private var bottomStatusBar: some View {
        HStack {
            Text(coordinator.statusMessage)
                .font(.caption2)
                .foregroundStyle(palette.muted)
                .lineLimit(1)

            Spacer()

            Text("SuperThumbnail v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") • macOS 네이티브 협업 엔진")
                .font(.caption2)
                .foregroundStyle(palette.muted)
        }
    }
}

// MARK: - Details & Diagnostics Sheet (Collapsed from Main View)

struct NASHelperDetailsSheet: View {
    @ObservedObject var coordinator: NASHelperCoordinator
    let palette: ByungkiPalette
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                Text("영상 변환 설정")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Spacer()
                Button("닫기") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(palette.card)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    autoParticipationSection
                    DisclosureGroup("변환 도구 정보") {
                        toolEnvironmentSection
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 500, minHeight: 460)
        .background(palette.bg)
    }

    // MARK: - Auto Participation Setting

    private var autoParticipationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("자동 시작", systemImage: "bolt.badge.automatic")
                .font(.subheadline.bold())
                .foregroundStyle(palette.text)

            Toggle(isOn: $coordinator.autoParticipationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("앱을 열면 NAS 폴더 작업 이어서 처리")
                        .font(.caption.bold())
                        .foregroundStyle(palette.text)
                    Text("이전에 선택한 NAS 폴더에 남은 영상이 있으면 처리를 이어갑니다.")
                        .font(.caption2)
                        .foregroundStyle(palette.text2)
                }
            }
            .toggleStyle(.checkbox)

            if coordinator.userStopped {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(palette.muted)
                    Text("직접 중지한 작업은 시작 버튼을 눌러 다시 진행할 수 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(palette.muted)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Tool Environment Section

    private var toolEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("변환 도구 환경 진단", systemImage: "wrench.and.screwdriver.fill")
                .font(.subheadline.bold())
                .foregroundStyle(palette.text)

            VStack(spacing: 6) {
                diagnosticRow(name: "python3", url: coordinator.toolEnvironment.python3URL)
                diagnosticRow(name: "ffmpeg", url: coordinator.toolEnvironment.ffmpegURL)
                diagnosticRow(name: "ffprobe", url: coordinator.toolEnvironment.ffprobeURL)
                diagnosticRow(
                    name: "변환 엔진",
                    url: coordinator.toolEnvironment.engineScriptURL,
                    customStatus: coordinator.toolEnvironment.hasBundledEngine ? "준비 완료" : "업데이트 필요"
                )
            }

            if !coordinator.toolEnvironment.isReadyToExecute {
                Text(coordinator.toolEnvironment.diagnosticMessage)
                    .font(.caption)
                    .foregroundStyle(palette.danger)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    private func diagnosticRow(name: String, url: URL?, customStatus: String? = nil) -> some View {
        HStack(spacing: 8) {
            let isOk = (url != nil || customStatus == "준비 완료")
            Image(systemName: isOk ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isOk ? Color.green : palette.danger)
            Text(name)
                .font(.caption.monospaced().bold())
                .foregroundStyle(palette.text)
            Spacer()
            if let customStatus {
                Text(customStatus)
                    .font(.caption2)
                    .foregroundStyle(customStatus == "준비 완료" ? Color.green : palette.danger)
            } else if let path = url?.path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("설치 필요")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.danger)
            }
        }
    }

    /// The slots the NAS really granted right now (sum over the joined folders); empty while not connected.
    private var nasAssignedSlotsText: String {
        coordinator.parallelStatus.serverCap.map { " (현재 NAS 배정 \($0)개)" } ?? ""
    }

    // MARK: - Pipeline Specification Section

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("작업 파이프라인 규격", systemImage: "slider.horizontal.3")
                .font(.subheadline.bold())
                .foregroundStyle(palette.text)

            VStack(alignment: .leading, spacing: 4) {
                Text("• 동시 변환 설정: \(coordinator.parallelVideoCount)개 (실제 적용: \(coordinator.parallelStatus.effective)개)")
                    .font(.caption)
                    .foregroundStyle(palette.text2)
                Text("• 기기 권장 한도: 최대 \(coordinator.parallelStatus.deviceCap)개 / NAS 공유 한도: 폴더당 최대 \(NASHelperWire.maxSlotsPerRoot)개를 여러 Mac이 나눠 사용\(nasAssignedSlotsText)")
                    .font(.caption)
                    .foregroundStyle(palette.text2)
                Text("• 다운로드 및 업로드: 각각 1개 작업 독립 실행")
                    .font(.caption)
                    .foregroundStyle(palette.text2)
                Text("• 로컬 임시 캐시: 최대 \(NASHelperPipelineConfiguration.localCacheSlots)개 슬롯 (안전 범위)")
                    .font(.caption)
                    .foregroundStyle(palette.text2)
                Text("• NAS 영상의 원본은 NAS가 MP4와 수퍼썸네일을 확인한 뒤 삭제합니다. 확인하지 못하면 원본을 남깁니다.")
                    .font(.caption)
                    .foregroundStyle(palette.muted)

                if let previous = coordinator.previousRun {
                    Text("• 직전 실행 기록 (메모리 전용): 완료 \(previous.processedCount)개, 실패 \(previous.failedCount)개")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    // MARK: - Usage Guide Section

    private var usageGuideSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("간단 사용 안내", systemImage: "lightbulb.fill")
                .font(.subheadline.bold())
                .foregroundStyle(palette.warn)

            VStack(alignment: .leading, spacing: 8) {
                guideItem(number: "1", title: "NAS 폴더 등록", text: "NAS 앱에서 변환할 폴더를 등록한 후, Mac 앱에서 '폴더 추가…'로 해당 폴더를 선택합니다.")
                guideItem(number: "2", title: "협업 시작", text: "'협업 시작'을 누르면 Mac이 변환 작업을 분담하여 백그라운드에서 안전하게 실행합니다.")
                guideItem(number: "3", title: "자동 확인 및 원본 정리", text: "변환된 MP4와 수퍼썸네일이 정상인지 확인한 뒤 원본을 삭제합니다. 확인에 실패하면 원본을 남깁니다.")
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
    }

    private func guideItem(number: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.caption2.bold())
                .frame(width: 18, height: 18)
                .background(palette.warnSoft, in: Circle())
                .foregroundStyle(palette.warnInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(palette.text)
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(palette.text2)
            }
        }
    }
}
