import Charts
import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            if let snapshot = viewModel.snapshot {
                GeometryReader { geometry in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {
                            ForEach(snapshot.rateLimits.primaryDisplayBuckets) { bucket in
                                QuotaCard(bucket: bucket)
                                    .frame(maxHeight: .infinity)
                            }
                            ResetCreditsCard(summary: snapshot.rateLimits.rateLimitResetCredits)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(width: min(max(geometry.size.width * 0.4, 280), 350))
                        .frame(maxHeight: .infinity)

                        UsageHistoryCard(
                            history: viewModel.history,
                            todayLocalTokens: viewModel.todayLocalTokens,
                            summary: snapshot.usage.summary,
                            chartHeight: max(82, geometry.size.height - 205),
                            archiveStatus: viewModel.archiveVerificationStatus,
                            latestArchivedDate: viewModel.latestArchivedDate,
                            verifyArchive: viewModel.verifyArchive
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            minWidth: 720,
            idealWidth: 760,
            maxWidth: .infinity,
            minHeight: 380,
            idealHeight: 400,
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

    private var header: some View {
        HStack(spacing: 10) {
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
        HStack {
            if let date = viewModel.lastUpdated {
                Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("每 60 秒自动刷新")
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 2)
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
                Spacer()
                Text("可用 \(summary?.availableCount ?? 0) 次")
                    .font(.subheadline.weight(.semibold))
            }

            if let credits = summary?.credits, !credits.isEmpty {
                ForEach(credits.sorted(by: expiresSooner)) { credit in
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
                if let summary, summary.availableCount > credits.count {
                    Text("另有 \(summary.availableCount - credits.count) 次重置未返回到期明细")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
    @State private var selectedDate: Date?
    @State private var hoverLocation: CGPoint?
    @State private var showsArchiveDetails = false

    private var visibleHistory: [DailyUsageBucket] {
        guard
            let dayCount = range.dayCount,
            let latestDate = history.compactMap(\.date).max(),
            let lowerBound = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: latestDate
            )
        else {
            return history
        }
        return history.filter { bucket in
            guard let date = bucket.date else { return false }
            return date >= lowerBound && date <= latestDate
        }
    }

    private var selectedBucket: DailyUsageBucket? {
        guard let selectedDate else { return nil }
        return visibleHistory.min {
            abs(($0.date ?? .distantPast).timeIntervalSince(selectedDate)) <
                abs(($1.date ?? .distantPast).timeIntervalSince(selectedDate))
        }
    }

    private var visibleTokenTotal: Int64 {
        visibleHistory.reduce(into: Int64.zero) { total, bucket in
            total += bucket.tokens
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("今天用了多少 Token")
                    .font(.headline)
                if let todayLocalTokens {
                    Text(todayLocalTokens.millionTokenCount)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text("本机实时统计不可用")
                        .font(.title3.weight(.semibold))
                }
                Text("实时统计（这台电脑）")
                    .font(.caption)
                    .foregroundStyle(UsagePalette.blue)
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                rangePicker
                Spacer(minLength: 8)
                verifyButton
            }

            if visibleHistory.isEmpty {
                Text("服务端暂未返回每日 Token 数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(visibleHistory) { bucket in
                    if let date = bucket.date {
                        LineMark(
                            x: .value("日期", date, unit: .day),
                            y: .value("Token", bucket.tokens)
                        )
                        .foregroundStyle(
                            selectedBucket?.id == bucket.id
                                ? UsagePalette.blue
                                : UsagePalette.blue.opacity(0.78)
                        )
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
                                    selectedDate = proxy.value(
                                        atX: location.x - plotOrigin.x,
                                        as: Date.self
                                    )
                                    hoverLocation = location
                                case .ended:
                                    selectedDate = nil
                                    hoverLocation = nil
                                }
                            }

                        if let selectedBucket, let hoverLocation {
                            ChartHoverTooltip(bucket: selectedBucket)
                                .position(
                                    x: min(max(hoverLocation.x + 88, 80), geometry.size.width - 80),
                                    y: max(30, hoverLocation.y - 42)
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: chartHeight)
            }

            HStack(spacing: 16) {
                Label("今天：实时统计", systemImage: "circle.fill")
                    .foregroundStyle(UsagePalette.blue)
                Label("之前：Codex 最终数据", systemImage: "circle.fill")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Button(action: { showsArchiveDetails = true }) {
                Text("今天结束后，会用 Codex 的最终数据替换实时统计")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
        .sheet(isPresented: $showsArchiveDetails) {
            ArchiveVerificationDetailSheet(
                status: archiveStatus,
                latestArchivedDate: latestArchivedDate
            )
        }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
    }
}
