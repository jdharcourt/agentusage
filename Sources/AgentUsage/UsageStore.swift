import AgentUsageCore
import AppKit
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var account: CodexAccountSnapshot?
    @Published private(set) var accountError: String?
    @Published private(set) var checkingAccount = false
    private var reader: SessionReader?
    private let accountClient = CodexAccountClient()
    private var home = CodexInstallation.defaultHome

    nonisolated static var defaultHome: URL {
        CodexInstallation.defaultHome
    }

    init() {
        do {
            reader = SessionReader(prices: try PriceBook.bundled())
        } catch {
            self.error = "Bundled prices could not be loaded. Rebuild or reinstall AgentUsage."
        }
        Task { [weak self] in
            while let self {
                await self.refresh()
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
        }
        Task { [weak self] in
            while let self {
                await self.refreshAccount()
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
            }
        }
    }

    var limits: PlanLimits? {
        if let account { return account.limits }
        return snapshot?.limits
    }

    func refreshAccount() async {
        guard !checkingAccount else { return }
        checkingAccount = true
        defer { checkingAccount = false }
        do {
            account = try await accountClient.fetch()
            if let account { home = account.home }
            accountError = nil
        } catch {
            accountError = error.localizedDescription
            if let error = error as? AccountError, case .notSignedIn = error { account = nil }
        }
    }

    func refresh() async {
        guard !refreshing, let reader else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            snapshot = try await reader.scan(home: home)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
