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
                    if geometry.size.width >= 680 {
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
                                summary: snapshot.usage.summary,
                                chartHeight: max(120, geometry.size.height - 120)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(snapshot.rateLimits.primaryDisplayBuckets) { bucket in
                                    QuotaCard(bucket: bucket)
                                        .frame(minHeight: 150)
                                }
                                ResetCreditsCard(summary: snapshot.rateLimits.rateLimitResetCredits)
                                    .frame(minHeight: 170)
                                UsageHistoryCard(
                                    history: viewModel.history,
                                    summary: snapshot.usage.summary,
                                    chartHeight: 220
                                )
                                .frame(minHeight: 360)
                            }
                        }
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
                .padding(.bottom, 10)
        }
        .frame(
            minWidth: 460,
            idealWidth: 820,
            maxWidth: .infinity,
            minHeight: 360,
            idealHeight: 420,
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
        .frame(height: 54)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bucket.displayName)
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
                HStack(spacing: 18) {
                    Text("已用 \(window.usedPercent)%")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("剩余 \(window.remainingPercent)%")
                        .foregroundStyle(UsagePalette.blue)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.title3.weight(.semibold))
                .monospacedDigit()

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
        VStack(alignment: .leading, spacing: 10) {
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
                    .font(.caption)
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
    let summary: AccountTokenUsageSummary
    let chartHeight: CGFloat

    @State private var range: HistoryRange = .month
    @State private var selectedDate: Date?

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("每日 Token", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Picker("范围", selection: $range) {
                    ForEach(HistoryRange.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 172)
            }

            if let selectedBucket {
                HStack {
                    Text(selectedBucket.startDate)
                        .font(.caption)
                    Spacer()
                    Text("\(selectedBucket.tokens.millionTokenCount) tokens")
                        .font(.title2.weight(.semibold))
                }
                .monospacedDigit()
            } else if let latest = visibleHistory.last {
                HStack {
                    Text("最新：\(latest.startDate)")
                        .font(.caption)
                    Spacer()
                    Text("\(latest.tokens.millionTokenCount) tokens")
                        .font(.title2.weight(.semibold))
                }
                .monospacedDigit()
            }

            if visibleHistory.isEmpty {
                Text("服务端暂未返回每日 Token 数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(visibleHistory) { bucket in
                    if let date = bucket.date {
                        BarMark(
                            x: .value("日期", date, unit: .day),
                            y: .value("Token", bucket.tokens)
                        )
                        .foregroundStyle(
                            selectedBucket?.id == bucket.id
                                ? UsagePalette.blue
                                : UsagePalette.blue.opacity(0.78)
                        )
                        .cornerRadius(2)
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
                                case .ended:
                                    selectedDate = nil
                                }
                            }
                    }
                }
                .frame(height: chartHeight)
            }

            HStack {
                if let lifetime = summary.lifetimeTokens {
                    Label("累计 \(lifetime.millionTokenCount)", systemImage: "sum")
                }
                Spacer()
                if let streak = summary.currentStreakDays {
                    Label("连续 \(streak) 天", systemImage: "flame.fill")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
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
