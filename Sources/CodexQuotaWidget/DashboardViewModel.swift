import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var history: [DailyUsageBucket] = []
    @Published private(set) var todayLocalTokens: Int64?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var archiveVerificationStatus: ArchiveVerificationStatus = .idle
    @Published private(set) var latestArchivedDate: String?

    private let client = CodexAppServerClient()
    private let usageStore: UsageStore?
    private var refreshLoop: Task<Void, Never>?

    init() {
        do {
            usageStore = try UsageStore()
        } catch {
            usageStore = nil
            errorMessage = error.localizedDescription
        }
    }

    deinit {
        refreshLoop?.cancel()
    }

    var primaryRemainingPercent: Int? {
        snapshot?.rateLimits.rateLimits.primary?.remainingPercent
    }

    var statusTitle: String {
        guard let remaining = primaryRemainingPercent else { return "Codex --" }
        return "Codex \(remaining)%"
    }

    func start() {
        guard refreshLoop == nil else { return }
        refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.load()
            }
        }
    }

    func refresh() {
        Task { [weak self] in
            await self?.load()
        }
    }

    func verifyArchive() {
        Task { [weak self] in
            await self?.load(verifyArchive: true)
        }
    }

    private func load(verifyArchive: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if verifyArchive {
            archiveVerificationStatus = .verifying
        }
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await client.fetchSnapshot()
            let remoteHistory = newSnapshot.usage.dailyUsageBuckets ?? []
            var mergedHistory = remoteHistory
            let currentDay = DailyUsageBucket.utcDayKey(for: newSnapshot.fetchedAt)
            let localTokens = await LocalTodayUsageReader.usage(for: currentDay)

            if let usageStore {
                var archivedHistory = try await usageStore.loadAll()

                if verifyArchive {
                    let repairs = UsageArchivePolicy.repairBuckets(
                        archive: archivedHistory,
                        codexHistory: remoteHistory,
                        currentDay: currentDay
                    )
                    if !repairs.isEmpty {
                        try await usageStore.merge(repairs)
                        archivedHistory = try await usageStore.loadAll()
                    }
                    archiveVerificationStatus = .completed(
                        checkedDays: UsageArchivePolicy.completedBuckets(
                            from: remoteHistory,
                            currentDay: currentDay
                        ).count,
                        repairedDays: repairs.count
                    )
                }

                latestArchivedDate = archivedHistory
                    .filter { $0.startDate < currentDay }
                    .map(\.startDate)
                    .max()
                mergedHistory = UsageArchivePolicy.displayedHistory(
                    archive: archivedHistory,
                    codexHistory: remoteHistory,
                    currentDay: currentDay
                )
            } else if verifyArchive {
                archiveVerificationStatus = .failed("本地归档不可用")
            }

            // Today's server bucket can lag. Never archive or display it as final history;
            // use this machine's session-log delta while the UTC day is still in progress.
            mergedHistory.removeAll { $0.startDate == currentDay }
            if let localTokens {
                mergedHistory.append(DailyUsageBucket(startDate: currentDay, tokens: localTokens))
                mergedHistory.sort { $0.startDate < $1.startDate }
            }

            snapshot = newSnapshot
            history = mergedHistory
            todayLocalTokens = localTokens
            lastUpdated = newSnapshot.fetchedAt
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if verifyArchive {
                archiveVerificationStatus = .failed(error.localizedDescription)
            }
        }
    }
}
