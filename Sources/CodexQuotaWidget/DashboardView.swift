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
                                    archiveStatus: viewModel.archiveVerificationStatus,
                                    latestArchivedDate: viewModel.latestArchivedDate,
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

                ProgressView(value: Double(window.usedPercent), total: 100)
                    .tint(progressColor(for: window.remainingPercent))
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
    let archiveStatus: ArchiveVerificationStatus
    let latestArchivedDate: String?
    let verifyArchive: () -> Void

    @State private var range: HistoryRange = .week
    @State private var visibleHistory: [DailyUsageBucket] = []
    @State private var sevenDayTokens: Int64?
    @State private var thirtyDayTokens: Int64?
    @State private var selectedBucketID: String?
    @State private var showsArchiveDetails = false

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

    private func updateRollingTotals() {
        guard let latestDate = history.compactMap(\.date).max() else {
            sevenDayTokens = nil
            thirtyDayTokens = nil
            return
        }

        sevenDayTokens = rollingTotal(days: 7, endingAt: latestDate)
        thirtyDayTokens = rollingTotal(days: 30, endingAt: latestDate)
    }

    private func rollingTotal(days: Int, endingAt latestDate: Date) -> Int64 {
        guard let lowerBound = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -(days - 1),
            to: latestDate
        ) else {
            return 0
        }

        return history.reduce(into: Int64.zero) { total, bucket in
            guard let date = bucket.date, date >= lowerBound, date <= latestDate else { return }
            total += bucket.tokens
        }
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
                UsageSummaryMetric(label: "7d 消耗", value: sevenDayTokens)
                UsageSummaryMetric(label: "30d 消耗", value: thirtyDayTokens)
            }

            Divider().opacity(0.35)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                rangePicker
                Spacer(minLength: 8)
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
        .sheet(isPresented: $showsArchiveDetails) {
            ArchiveVerificationDetailSheet(
                status: archiveStatus,
                latestArchivedDate: latestArchivedDate
            )
        }
        .onAppear {
            updateVisibleHistory()
            updateRollingTotals()
        }
        .onChange(of: history) { _ in
            updateVisibleHistory()
            updateRollingTotals()
        }
        .onChange(of: range) { _ in updateVisibleHistory() }
    }

    private var verifyButton: some View {
        Button(action: verifyArchive) {
            Label("核验归档", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(archiveStatus == .verifying)
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

private struct ArchiveVerificationBanner: View {
    let status: ArchiveVerificationStatus
    let latestArchivedDate: String?
    let showDetails: () -> Void

    var body: some View {
        Button(action: showDetails) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    statusIcon
                    Text(statusTitle)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Label("查看详情", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))

                Text("当天仅读取 Codex 实时数据，不参与归档")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func completedTitle(checkedDays: Int, repairedDays: Int) -> String {
        let latest = latestArchivedDate ?? "无"
        if repairedDays == 0 {
            return "已核验完成 · 最新归档：\(latest)"
        }
        return "已修复 \(repairedDays) 天 · 最新归档：\(latest)"
    }

    private var statusTitle: String {
        switch status {
        case .idle:
            return latestArchivedDate.map { "最新归档：\($0)" } ?? "尚无历史归档"
        case .verifying:
            return "正在核验 Codex 可查历史…"
        case .completed(let checkedDays, let repairedDays):
            return completedTitle(checkedDays: checkedDays, repairedDays: repairedDays)
        case .failed(let message):
            return "核验失败：\(message)"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case .idle:
            Image(systemName: "archivebox")
        case .verifying:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var statusColor: Color {
        switch status {
        case .completed: return .green
        case .failed: return .orange
        case .idle, .verifying: return .secondary
        }
    }
}

private struct ArchiveVerificationDetailSheet: View {
    let status: ArchiveVerificationStatus
    let latestArchivedDate: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("归档核验详情", systemImage: "checkmark.shield")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }

            DetailRow(title: "核验范围", value: "Codex 当前可查询的全部已结束日期")
            DetailRow(title: "最新归档", value: latestArchivedDate ?? "尚无")
            DetailRow(title: "当日数据", value: "仅实时读取，不写入归档")

            switch status {
            case .idle:
                Text("点击“核验归档”后会全量比较本地归档和 Codex 历史，仅补齐或改正不一致的日期；不会删除本地已有记录。")
            case .verifying:
                Text("正在读取并比对 Codex 可查历史，请稍候。")
            case .completed(let checkedDays, let repairedDays):
                DetailRow(title: "本次核验", value: "已检查 \(checkedDays) 天，修复 \(repairedDays) 天")
            case .failed(let message):
                DetailRow(title: "本次结果", value: "失败：\(message)")
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 390, height: 300)
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
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
