import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var history: [DailyUsageBucket] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?

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

    private func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await client.fetchSnapshot()
            let remoteHistory = newSnapshot.usage.dailyUsageBuckets ?? []
            var mergedHistory = remoteHistory

            if let usageStore {
                let currentDay = DailyUsageBucket.utcDayKey(for: newSnapshot.fetchedAt)
                let completedRemoteHistory = remoteHistory.filter { $0.startDate < currentDay }
                let liveCurrentDayHistory = remoteHistory.filter { $0.startDate == currentDay }

                // The current UTC day is always shown directly from Codex. Only dates
                // that have ended are retained as the local archive.
                try await usageStore.merge(completedRemoteHistory)
                let archivedHistory = try await usageStore.loadAll().filter {
                    $0.startDate < currentDay
                }
                mergedHistory = (archivedHistory + liveCurrentDayHistory).sorted {
                    $0.startDate < $1.startDate
                }
            }

            snapshot = newSnapshot
            history = mergedHistory
            lastUpdated = newSnapshot.fetchedAt
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
