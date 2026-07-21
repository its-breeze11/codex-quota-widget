import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var presentation: PanelPresentation
    let togglePresentation: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            if let snapshot = viewModel.snapshot {
                GeometryReader { geometry in
                    let leftWidth = presentation.isExpanded
                        ? min(max(geometry.size.width * 0.4, 280), 350)
                        : geometry.size.width

                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 14) {
                            quotaColumn(snapshot: snapshot)
                                .frame(width: leftWidth)
                                .frame(maxHeight: .infinity)

                            if presentation.isExpanded {
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
                                x: presentation.isExpanded ? leftWidth + 7 : geometry.size.width - 13,
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
            minWidth: presentation.isExpanded ? 720 : 360,
            idealWidth: presentation.isExpanded ? 720 : 360,
            maxWidth: .infinity,
            minHeight: 350,
            idealHeight: 350,
            maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        }
        .alert("未检测到 Codex CLI", isPresented: $viewModel.isCLIInstallPromptVisible) {
            Button("暂不安装", role: .cancel) {}
            Button("安装 CLI") {
                viewModel.installCLI()
            }
        } message: {
            Text("此工具需要本机 Codex CLI 才能读取用量。确认后会通过 npm 安装到 ~/.local，不需要管理员权限。安装完成后仍需由你在终端运行 codex login 登录账户。")
        }
        // Keep the panel visually identical whether it currently has keyboard focus or not.
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
        Button(action: togglePresentation) {
            Text(presentation.isExpanded ? "<<" : ">>")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(UsagePalette.blue.opacity(0.82))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(presentation.isExpanded ? "收起图表" : "展开图表")
    }

    private var header: some View {
        HStack(spacing: 10) {
            WindowTrafficLights()
            Image(systemName: "terminal.fill")
                .foregroundStyle(.tint)
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
                viewModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("立即刷新")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 12) {
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

private struct WindowTrafficLights: View {
    var body: some View {
        HStack(spacing: 7) {
            trafficLight(color: .red, symbol: "xmark", help: "关闭窗口") {
                widgetPanel?.orderOut(nil)
            }
            trafficLight(color: .yellow, symbol: "minus", help: "最小化到 Dock") {
                widgetPanel?.miniaturize(nil)
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
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Label {
                            Text(resetDate, style: .relative)
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("重置时间：\(resetDate.formatted(date: .abbreviated, time: .shortened))")
                    }
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
                    usedPercent: window.usedPercent,
                    color: progressColor(for: window.remainingPercent)
                )
            }
        }
        .cardStyle()
    }

    private func progressColor(for remaining: Int) -> Color {
        if remaining <= 10 { return .red }
        if remaining <= 30 { return .orange }
        return Color(nsColor: .systemGray)
    }
}

private struct QuotaProgressBar: View {
    let usedPercent: Int
    let color: Color

    private var progress: CGFloat {
        min(max(CGFloat(usedPercent) / 100, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.32))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 7)
        .accessibilityLabel("额度已使用 \(usedPercent)%")
        .accessibilityValue("\(usedPercent)%")
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
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text(credit.title ?? "完整重置")
                            .lineLimit(1)
                        Spacer()
                        if let expiration = credit.expirationDate {
                            TimelineView(.periodic(from: .now, by: 60)) { _ in
                                Text(expiration, style: .relative)
                                    .monospacedDigit()
                                    .help("到期：\(expiration.formatted(date: .abbreviated, time: .shortened))")
                            }
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

                                    // Hover events arrive for every pointer pixel. Changing state
                                    // only when the closest day changes keeps the chart responsive.
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
            Color(nsColor: .windowBackgroundColor).opacity(0.96),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
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
    static let blue = Color(red: 0.36, green: 0.62, blue: 0.92)
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}
