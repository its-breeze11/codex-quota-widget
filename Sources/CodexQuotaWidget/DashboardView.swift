import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var presentation: PanelPresentation
    let togglePresentation: () -> Void
    let toggleChart: () -> Void

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let hash = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String
        if let hash, !hash.isEmpty, hash != "?" {
            return "\(version) (\(build)) \(hash)"
        }
        return "\(version) (\(build))"
    }

    var body: some View {
        if presentation.isExpanded {
            expandedContent
        } else {
            FloatingQuotaBall(
                viewModel: viewModel,
                expand: togglePresentation
            )
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            if let snapshot = viewModel.snapshot {
                GeometryReader { geometry in
                    let leftWidth = presentation.isChartVisible
                        ? min(max(geometry.size.width * 0.4, 280), 350)
                        : geometry.size.width

                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 14) {
                            quotaColumn(snapshot: snapshot)
                                .frame(width: leftWidth)
                                .frame(maxHeight: .infinity)

                            if presentation.isChartVisible {
                                UsageHistoryCard(
                                    history: viewModel.history,
                                    todayLocalTokens: viewModel.todayLocalTokens,
                                    summary: snapshot.usage.summary,
                                    chartHeight: max(80, geometry.size.height - 205),
                                    detailsSheetHeight: presentation.panelHeight,
                                    archiveStatus: viewModel.archiveVerificationStatus,
                                    verifyArchive: viewModel.verifyArchive
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }

                        presentationToggle
                            .position(
                                x: presentation.isChartVisible ? leftWidth + 7 : geometry.size.width - 13,
                                y: geometry.size.height / 2
                            )
                    }
                }
                .padding(14)
            } else if viewModel.isInstallingCLI {
                ProgressView("正在安装 Codex CLI…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isRefreshing {
                ProgressView("正在读取 Codex 数据…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("尚无额度数据")
                        .font(.headline)
                    Text("请确认 Codex 已登录，然后重试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
                    .padding(.horizontal, 14)
            }

            footer
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .frame(
            minWidth: presentation.isChartVisible ? 720 : 320,
            idealWidth: presentation.isChartVisible ? 720 : 360,
            maxWidth: .infinity,
            minHeight: 350,
            idealHeight: 350,
            maxHeight: .infinity
        )
        .background(UsagePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(UsagePalette.border, lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .tint(UsagePalette.blue)
        .alert("未检测到 Codex CLI", isPresented: $viewModel.isCLIInstallPromptVisible) {
            Button("暂不安装", role: .cancel) {}
            Button("安装 CLI") {
                viewModel.installCLI()
            }
        } message: {
            Text("此工具需要本机 Codex CLI 才能读取用量。确认后会通过 npm 安装到 ~/.local，不需要管理员权限。随后会请你在浏览器登录自己的 Codex 账户；应用不会读取或保存登录凭据。")
        }
        .alert("需要登录 Codex", isPresented: $viewModel.isCLILoginPromptVisible) {
            Button("稍后登录", role: .cancel) {}
            Button("打开登录") {
                viewModel.beginCLILogin()
            }
        } message: {
            Text("Codex CLI 已安装。为了读取你的额度，需要由你本人完成一次 ChatGPT/Codex 网页授权。确认后会打开终端并执行 codex login；授权完成后本应用会自动检测并启用。")
        }
        .alert("需要先安装 Node.js", isPresented: $viewModel.isNodeInstallPromptVisible) {
            Button("暂不安装", role: .cancel) {}
            Button("获取 Node.js") {
                viewModel.openNodeDownload()
            }
        } message: {
            Text("安装 Codex CLI 依赖 Node.js/npm。本机未检测到该运行环境，因此无法安全地继续。确认后会打开 Node.js 官方下载页；安装完成后回到本应用点击刷新即可继续。")
        }
        // 无论面板是否获得键盘焦点，都保持一致的视觉效果。
        .environment(\.controlActiveState, .inactive)
    }

    private func quotaColumn(snapshot: DashboardSnapshot) -> some View {
        VStack(spacing: 14) {
            ForEach(snapshot.rateLimits.primaryDisplayBuckets) { bucket in
                QuotaCard(bucket: bucket)
                    .frame(maxHeight: .infinity)
            }
            ResetCreditsCard(summary: snapshot.rateLimits.rateLimitResetCredits)
                .frame(maxHeight: .infinity)
        }
    }

    private var presentationToggle: some View {
        Button(action: toggleChart) {
            Text(presentation.isChartVisible ? "<<" : ">>")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(UsagePalette.blue.opacity(0.82))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(presentation.isChartVisible ? "收起图表" : "展开图表")
    }

    private var header: some View {
        HStack(spacing: 10) {
            WindowTrafficLights(collapse: togglePresentation)
            Image(systemName: "terminal.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UsagePalette.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 用量")
                    .font(.headline)
                Text("本机只读")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                togglePresentation()
            } label: {
                Image(systemName: "circle.circle.fill")
            }
            .buttonStyle(.plain)
            .help("切换为悬浮球")
            Button {
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("立即刷新")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(UsagePalette.header)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(versionString)
                .monospacedDigit()
            Spacer(minLength: 0)
            if let date = viewModel.lastUpdated {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("每 60 秒自动刷新")
            }
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
    }
}

private struct FloatingQuotaBall: View {
    @ObservedObject var viewModel: DashboardViewModel
    let expand: () -> Void
    @State private var dragOrigin: NSPoint?
    @State private var dragMouseOrigin: NSPoint?
    @State private var hasMoved = false

    var body: some View {
        ZStack {
            if let remaining = viewModel.primaryRemainingPercent {
                LiquidGlassSphere(
                    level: CGFloat(remaining) / 100,
                    label: "\(remaining)%",
                    baseColor: QuotaProgressColors.color(for: remaining)
                )
            } else if viewModel.isRefreshing || viewModel.isInstallingCLI {
                LiquidGlassSphere(level: 0.18, label: nil, baseColor: UsagePalette.blue)
                    .overlay { ProgressView().controlSize(.small).tint(.white) }
            } else {
                LiquidGlassSphere(level: 0.12, label: nil, baseColor: UsagePalette.blue)
                    .overlay {
                        Image(systemName: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 60, height: 60)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard let panel = floatingPanel else { return }
                    if dragOrigin == nil {
                        dragOrigin = panel.frame.origin
                        dragMouseOrigin = NSEvent.mouseLocation
                    }
                    guard let dragOrigin, let dragMouseOrigin else { return }
                    // 使用屏幕坐标而不是 value.translation。悬浮球会随窗口移动，
                    // 局部 SwiftUI 坐标会在指针下方变化，从而造成明显跳动。
                    let mouseLocation = NSEvent.mouseLocation
                    let translation = CGSize(
                        width: mouseLocation.x - dragMouseOrigin.x,
                        height: mouseLocation.y - dragMouseOrigin.y
                    )
                    if abs(translation.width) > 3 || abs(translation.height) > 3 {
                        hasMoved = true
                    }
                    guard hasMoved else { return }
                    panel.setFrameOrigin(
                        NSPoint(
                            x: dragOrigin.x + translation.width,
                            y: dragOrigin.y + translation.height
                        )
                    )
                }
                .onEnded { _ in
                    if !hasMoved {
                        expand()
                    }
                    dragOrigin = nil
                    dragMouseOrigin = nil
                    hasMoved = false
                }
        )
        .accessibilityAddTraits(.isButton)
        .help("点击展开，拖动移动悬浮球")
        .preferredColorScheme(.dark)
    }

    private var floatingPanel: NSWindow? {
        NSApp.windows.first { $0 is FloatingPanel }
    }
}

private struct LiquidGlassSphere: View {
    let level: CGFloat
    let label: String?
    let baseColor: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [baseColor.opacity(0.96), baseColor.opacity(0.62)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 38
                    )
                )
                .shadow(color: Color.blue.opacity(0.28), radius: 7, y: 3)

            WaterFillShape(level: level)
                .fill(
                    LinearGradient(
                        colors: [baseColor.opacity(0.92), baseColor.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    WaterFillShape(level: level)
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.7)
                }
                .clipShape(Circle())

            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .clear, .black.opacity(0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.66), Color.blue.opacity(0.55), .white.opacity(0.18)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            if let label {
                Text(label)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
            }
        }
    }
}

private struct WaterFillShape: Shape {
    let level: CGFloat

    func path(in rect: CGRect) -> Path {
        let clampedLevel = min(max(level, 0), 1)
        let waterline = rect.maxY - rect.height * clampedLevel
        let waveHeight = max(1.5, rect.height * 0.035)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: waterline))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: waterline),
            control1: CGPoint(x: rect.width * 0.3, y: waterline - waveHeight),
            control2: CGPoint(x: rect.width * 0.7, y: waterline + waveHeight)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct WindowTrafficLights: View {
    let collapse: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            trafficLight(color: .red, symbol: "xmark", help: "关闭窗口") {
                widgetPanel?.orderOut(nil)
            }
            trafficLight(color: .yellow, symbol: "minus", help: "收起为悬浮球") {
                collapse()
            }
            trafficLight(color: .green, symbol: "plus", help: "缩放窗口") {
                widgetPanel?.zoom(nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("窗口控制")
    }

    private var widgetPanel: NSWindow? {
        NSApp.windows.first { $0 is FloatingPanel }
    }

    private func trafficLight(
        color: Color,
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.black.opacity(0.58))
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct QuotaCard: View {
    let bucket: RateLimitSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前可用额度")
                        .font(.headline)
                    if let plan = bucket.planType {
                        Text(plan)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let resetDate = bucket.primary?.resetDate {
                    Label {
                        Text(resetDate.yyyyMMddDashed)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("重置时间：\(resetDate.formatted(date: .abbreviated, time: .shortened))")
                }
            }

            if let window = bucket.primary {
                Text("剩余 \(window.remainingPercent)%")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(UsagePalette.blue)
                .monospacedDigit()

                Text("已用 \(window.usedPercent)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                QuotaProgressBar(
                    remainingPercent: window.remainingPercent,
                    color: progressColor(for: window.remainingPercent)
                )
            }
        }
        .cardStyle()
    }

    private func progressColor(for remaining: Int) -> Color {
        QuotaProgressColors.color(for: remaining)
    }
}

private enum QuotaProgressColors {
    static func color(for remaining: Int) -> Color {
        switch remaining {
        case 90...:
            return UsagePalette.quotaBrightGreen
        case 80...89:
            return UsagePalette.quotaGreen
        case 70...79:
            return UsagePalette.quotaLimeGreen
        case 60...69:
            return UsagePalette.quotaYellowGreen
        case 50...59:
            return UsagePalette.quotaLimeYellow
        case 40...49:
            return UsagePalette.quotaYellow
        case 30...39:
            return UsagePalette.quotaOrangeYellow
        case 20...29:
            return UsagePalette.quotaCoralOrange
        case 10...19:
            return UsagePalette.quotaCoralRed
        case 5...9:
            return UsagePalette.quotaRed
        default:
            return UsagePalette.quotaDeepRed
        }
    }
}

private struct QuotaProgressBar: View {
    let remainingPercent: Int
    let color: Color

    private var clampedRemaining: Int {
        min(max(remainingPercent, 0), 100)
    }

    private var showsRemaining: Bool {
        clampedRemaining >= 50
    }

    private var progress: CGFloat {
        let displayedPercent = showsRemaining
            ? clampedRemaining
            : 100 - clampedRemaining
        return CGFloat(displayedPercent) / 100
    }

    private var accessibilityDescription: String {
        showsRemaining
            ? "额度剩余 \(clampedRemaining)%"
            : "额度已使用 \(100 - clampedRemaining)%"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(UsagePalette.progressTrack)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 7)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

private struct ResetCreditsCard: View {
    let summary: ResetCreditsSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("额度重置", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.headline)
                Text("（仅展示近 3 次）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("可用 \(summary?.availableCount ?? 0) 次")
                    .font(.subheadline.weight(.semibold))
            }

            if let credits = summary?.credits, !credits.isEmpty {
                let visibleCredits = Array(credits.sorted(by: expiresSooner).prefix(3))
                ForEach(visibleCredits) { credit in
                    HStack {
                            Circle()
                            .fill(UsagePalette.success)
                            .frame(width: 6, height: 6)
                        Text(credit.title ?? "完整重置")
                            .lineLimit(1)
                        Spacer()
                        if let expiration = credit.expirationDate {
                            Text(expiration.yyyyMMddDashed)
                                .monospacedDigit()
                                .help("到期：\(expiration.formatted(date: .abbreviated, time: .shortened))")
                        } else {
                            Text("未提供到期时间")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(summary == nil ? "服务端未提供重置券信息" : "当前没有可用重置券")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func expiresSooner(_ lhs: ResetCredit, _ rhs: ResetCredit) -> Bool {
        (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case week = "7 天"
    case month = "30 天"
    case all = "全部"

    var id: String { rawValue }
    var dayCount: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .all: return nil
        }
    }
}

private struct UsageHistoryCard: View {
    let history: [DailyUsageBucket]
    let todayLocalTokens: Int64?
    let summary: AccountTokenUsageSummary
    let chartHeight: CGFloat
    let detailsSheetHeight: CGFloat
    let archiveStatus: ArchiveVerificationStatus
    let verifyArchive: () -> Void

    @State private var range: HistoryRange = .week
    @State private var visibleHistory: [DailyUsageBucket] = []
    @State private var selectedBucketID: String?
    @State private var showsUsageDetails = false

    private var sevenDayCalculation: UsageWindowCalculation {
        UsageRollingWindow.calculate(days: 7, from: history)
    }

    private var thirtyDayCalculation: UsageWindowCalculation {
        UsageRollingWindow.calculate(days: 30, from: history)
    }

    private var sevenDayTotal: Int64? {
        sevenDayCalculation.endDate == nil ? nil : sevenDayCalculation.totalTokens
    }

    private var thirtyDayTotal: Int64? {
        thirtyDayCalculation.endDate == nil ? nil : thirtyDayCalculation.totalTokens
    }

    private func updateVisibleHistory() {
        guard
            let dayCount = range.dayCount,
            let latestDate = history.compactMap(\.date).max(),
            let lowerBound = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: latestDate
            )
        else {
            visibleHistory = history
            selectedBucketID = nil
            return
        }
        visibleHistory = history.filter { bucket in
            guard let date = bucket.date else { return false }
            return date >= lowerBound && date <= latestDate
        }
        selectedBucketID = nil
    }

    private var selectedBucket: DailyUsageBucket? {
        guard let selectedBucketID else { return nil }
        return visibleHistory.first { $0.id == selectedBucketID }
    }

    private func nearestBucket(to date: Date) -> DailyUsageBucket? {
        visibleHistory.min {
            abs(($0.date ?? .distantPast).timeIntervalSince(date)) <
                abs(($1.date ?? .distantPast).timeIntervalSince(date))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                UsageSummaryMetric(label: "1d 消耗", value: todayLocalTokens, accent: true)
                UsageSummaryMetric(label: "7d 消耗", value: sevenDayTotal)
                UsageSummaryMetric(label: "30d 消耗", value: thirtyDayTotal)
            }

            Divider().opacity(0.35)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                rangePicker
                Spacer(minLength: 8)
                detailsButton
                verifyButton
            }
            .padding(.bottom, 16)

            if visibleHistory.isEmpty {
                Text("服务端暂未返回每日 Token 数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 85)
            } else {
                Chart(visibleHistory) { bucket in
                    if let date = bucket.date {
                        LineMark(
                            x: .value("日期", date, unit: .day),
                            y: .value("Token", bucket.tokens)
                        )
                        .foregroundStyle(UsagePalette.blue.opacity(0.78))
                        .lineStyle(.init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                        if selectedBucket?.id == bucket.id {
                            PointMark(
                                x: .value("日期", date, unit: .day),
                                y: .value("Token", bucket.tokens)
                            )
                            .symbolSize(72)
                            .foregroundStyle(UsagePalette.blue)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let count = value.as(Int64.self) {
                                Text(count.millionTokenCount)
                                    .foregroundStyle(UsagePalette.muted)
                            }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let plotOrigin = geometry[proxy.plotAreaFrame].origin
                                    guard let date = proxy.value(
                                        atX: location.x - plotOrigin.x,
                                        as: Date.self
                                    ), let bucket = nearestBucket(to: date) else { return }

                                    // 指针每移动一个像素都会触发悬停事件；只有最近日期变化时才更新状态，
                                    // 可以保持图表响应流畅。
                                    if selectedBucketID != bucket.id {
                                        var transaction = Transaction()
                                        transaction.animation = nil
                                        withTransaction(transaction) {
                                            selectedBucketID = bucket.id
                                        }
                                    }
                                case .ended:
                                    selectedBucketID = nil
                                }
                            }

                        if let selectedBucket,
                           let date = selectedBucket.date,
                           let xPosition = proxy.position(forX: date),
                           let yPosition = proxy.position(forY: selectedBucket.tokens) {
                            let plotOrigin = geometry[proxy.plotAreaFrame].origin
                            ChartHoverTooltip(bucket: selectedBucket)
                                .position(
                                    x: min(
                                        max(plotOrigin.x + xPosition + 78, 78),
                                        geometry.size.width - 78
                                    ),
                                    y: max(26, plotOrigin.y + yPosition - 34)
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
                .transaction { $0.animation = nil }
                .frame(height: chartHeight)
            }

        }
        .cardStyle()
        .sheet(isPresented: $showsUsageDetails) {
            UsageCalculationDetailSheet(
                sevenDayCalculation: sevenDayCalculation,
                thirtyDayCalculation: thirtyDayCalculation,
                todayLocalTokens: todayLocalTokens,
                preferredHeight: detailsSheetHeight
            )
        }
        .onAppear {
            updateVisibleHistory()
        }
        .onChange(of: history) { _ in
            updateVisibleHistory()
        }
        .onChange(of: range) { _ in updateVisibleHistory() }
    }

    private var verifyButton: some View {
        Button(action: verifyArchive) {
            Label("核验", systemImage: "checkmark.shield")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(archiveStatus == .verifying)
        .help("核验本地历史与 Codex 已结束日期")
    }

    private var detailsButton: some View {
        Button {
            showsUsageDetails = true
        } label: {
            Label("详情", systemImage: "list.bullet")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("查看 7d 和 30d 消耗计算明细")
    }

    private var rangePicker: some View {
        Picker("范围", selection: $range) {
            ForEach(HistoryRange.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 160)
    }
}

private struct UsageSummaryMetric: View {
    let label: String
    let value: Int64?
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value?.millionTokenCount ?? "--")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ? UsagePalette.blue : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(accent ? "1d 为这台电脑的实时统计；历史日期使用 Codex 最终数据。" : "按最近完整日数据滚动汇总。")
    }
}

private struct ChartHoverTooltip: View {
    let bucket: DailyUsageBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bucket.startDate)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(bucket.tokens.millionTokenCount) Token")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            UsagePalette.overlay,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(UsagePalette.border, lineWidth: 1)
        }
        .fixedSize()
    }
}

private struct UsageCalculationDetailSheet: View {
    let sevenDayCalculation: UsageWindowCalculation
    let thirtyDayCalculation: UsageWindowCalculation
    let todayLocalTokens: Int64?
    let preferredHeight: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDays = 7

    private var calculation: UsageWindowCalculation {
        selectedDays == 7 ? sevenDayCalculation : thirtyDayCalculation
    }

    private var displayedBuckets: [DailyUsageBucket] {
        Array(calculation.buckets.reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("消耗计算明细", systemImage: "list.bullet.rectangle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }

            Picker("范围", selection: $selectedDays) {
                Text("7d 消耗").tag(7)
                Text("30d 消耗").tag(30)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 3) {
                Text("计算范围")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(rangeDescription)
                    .font(.subheadline.weight(.medium))
                Text("仅汇总来源有记录的日期，共 \(calculation.buckets.count) 天。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedBuckets) { bucket in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bucket.startDate)
                                    .font(.subheadline.monospacedDigit())
                                Text(sourceDescription(for: bucket))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bucket.tokens.millionTokenCount)
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .padding(.vertical, 7)

                        if bucket.id != displayedBuckets.last?.id {
                            Divider().opacity(0.45)
                        }
                    }

                    if displayedBuckets.isEmpty {
                        Text("暂无可用于计算的每日 Token 数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }

            Divider()
            HStack {
                Text("\(selectedDays)d 消耗合计")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(calculation.totalTokens.millionTokenCount)
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(UsagePalette.blue)
            }
        }
        .padding(20)
        .frame(width: 460, height: preferredHeight)
        .background(UsagePalette.background)
        .preferredColorScheme(.dark)
    }

    private var rangeDescription: String {
        guard let startDate = calculation.startDate, let endDate = calculation.endDate else {
            return "暂无日期范围"
        }
        return "\(startDate) 至 \(endDate)（含首尾）"
    }

    private func sourceDescription(for bucket: DailyUsageBucket) -> String {
        if bucket.startDate == DailyUsageBucket.utcDayKey(), todayLocalTokens != nil {
            return "今日 · 本机实时统计"
        }
        return "已结束日 · Codex 最终数据"
    }
}

private enum UsagePalette {
    static let background = Color(red: 0.047, green: 0.071, blue: 0.102)
    static let header = Color(red: 0.065, green: 0.094, blue: 0.133)
    static let card = Color(red: 0.102, green: 0.145, blue: 0.200)
    static let overlay = Color(red: 0.075, green: 0.106, blue: 0.149).opacity(0.98)
    static let blue = Color(red: 0.30, green: 0.68, blue: 1.0)
    static let muted = Color(red: 0.61, green: 0.68, blue: 0.77)
    static let border = Color.white.opacity(0.12)
    static let progressTrack = Color.white.opacity(0.10)
    static let quotaBrightGreen = Color(red: 0.482, green: 0.843, blue: 0.478)
    static let quotaGreen = Color(red: 0.408, green: 0.804, blue: 0.431)
    static let quotaLimeGreen = Color(red: 0.467, green: 0.761, blue: 0.392)
    static let quotaYellowGreen = Color(red: 0.565, green: 0.725, blue: 0.357)
    static let quotaLimeYellow = Color(red: 0.663, green: 0.686, blue: 0.318)
    static let quotaYellow = Color(red: 0.761, green: 0.643, blue: 0.278)
    static let quotaOrangeYellow = Color(red: 0.855, green: 0.580, blue: 0.243)
    static let quotaCoralOrange = Color(red: 0.910, green: 0.506, blue: 0.267)
    static let quotaCoralRed = Color(red: 0.886, green: 0.416, blue: 0.306)
    static let quotaRed = Color(red: 0.827, green: 0.294, blue: 0.290)
    static let quotaDeepRed = Color(red: 0.725, green: 0.176, blue: 0.259)
    static let warning = Color(red: 1.0, green: 0.66, blue: 0.20)
    static let danger = Color(red: 0.96, green: 0.31, blue: 0.31)
    static let success = Color(red: 0.20, green: 0.85, blue: 0.46)
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(UsagePalette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(UsagePalette.danger.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(UsagePalette.card)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.055), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(UsagePalette.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
    }
}
