import Combine
import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    private enum ArchiveRefreshScope {
        case recent(days: Int)
        case all

        var recentDays: Int? {
            switch self {
            case .recent(let days): return days
            case .all: return nil
            }
        }

        var reportsStatus: Bool {
            if case .all = self { return true }
            return false
        }
    }

    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var history: [DailyUsageBucket] = []
    @Published private(set) var todayLocalTokens: Int64?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var archiveVerificationStatus: ArchiveVerificationStatus = .idle
    @Published private(set) var latestArchivedDate: String?
    @Published var isCLIInstallPromptVisible = false
    @Published var isCLILoginPromptVisible = false
    @Published var isNodeInstallPromptVisible = false
    @Published private(set) var isInstallingCLI = false

    private let client = CodexAppServerClient()
    private let usageStore: UsageStore?
    private var refreshLoop: Task<Void, Never>?
    private var loginWatchTask: Task<Void, Never>?
    private var hasPromptedForCLIInstallation = false
    private var hasPromptedForCLILogin = false

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
        loginWatchTask?.cancel()
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
                await self?.load(archiveRefresh: .recent(days: 7))
            }
        }
    }

    func refresh() {
        Task { [weak self] in
            await self?.load(archiveRefresh: .recent(days: 7))
        }
    }

    func verifyArchive() {
        Task { [weak self] in
            await self?.load(archiveRefresh: .all)
        }
    }

    func installCLI() {
        guard !isInstallingCLI else { return }
        Task { [weak self] in
            guard let self else { return }
            self.isInstallingCLI = true
            self.errorMessage = nil
            defer { self.isInstallingCLI = false }

            do {
                try await self.client.installCLI()
                self.isCLILoginPromptVisible = true
            } catch {
                if case CodexClientError.npmNotFound = error {
                    self.isNodeInstallPromptVisible = true
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func beginCLILogin() {
        guard !isInstallingCLI else { return }
        do {
            try client.openLoginInTerminal()
            errorMessage = "已打开 Codex 登录。完成网页授权后，组件会自动启用。"
            watchForLogin()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openNodeDownload() {
        CodexAppServerClient.openNodeDownloadPage()
        errorMessage = "已打开 Node.js 下载页。安装完成后回到这里点击刷新，组件会继续安装 Codex CLI。"
    }

    private func watchForLogin() {
        loginWatchTask?.cancel()
        loginWatchTask = Task { [weak self] in
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if await self?.client.isLoggedIn() == true {
                    await self?.load(archiveRefresh: .recent(days: 7))
                    return
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func load(archiveRefresh: ArchiveRefreshScope = .recent(days: 7)) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        if archiveRefresh.reportsStatus {
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

                let repairs = UsageArchivePolicy.repairBuckets(
                    archive: archivedHistory,
                    codexHistory: remoteHistory,
                    currentDay: currentDay,
                    recentDays: archiveRefresh.recentDays
                )
                if !repairs.isEmpty {
                    try await usageStore.merge(repairs)
                    archivedHistory = try await usageStore.loadAll()
                }

                if archiveRefresh.reportsStatus {
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
            } else if archiveRefresh.reportsStatus {
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
            if case CodexClientError.executableNotFound = error, snapshot == nil {
                errorMessage = nil
                if !hasPromptedForCLIInstallation {
                    hasPromptedForCLIInstallation = true
                    isCLIInstallPromptVisible = true
                }
            } else if snapshot == nil, !hasPromptedForCLILogin, !(await client.isLoggedIn()) {
                // The executable may already be present but have no valid
                // ChatGPT/Codex session (for example, after the user logged
                // out in the CLI). Route this through the same explicit
                // authorization flow instead of showing a generic server error.
                errorMessage = nil
                hasPromptedForCLILogin = true
                isCLILoginPromptVisible = true
            } else {
                errorMessage = snapshot == nil
                    ? error.localizedDescription
                    : "暂时无法刷新，仍展示上次成功数据。"
            }
            if archiveRefresh.reportsStatus {
                archiveVerificationStatus = .failed(error.localizedDescription)
            }
        }
    }
}
