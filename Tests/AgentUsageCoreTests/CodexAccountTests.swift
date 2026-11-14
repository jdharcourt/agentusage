import Foundation
import Testing
@testable import AgentUsageCore

struct CodexAccountTests {
    @Test func signedInAccountIncludesLiveLimitsAndServerLifetimeTokens() throws {
        let snapshot = try CodexAccountSnapshot.decode(
            account: Data(#"{"account":{"type":"chatgpt","email":"test@example.com","planType":"pro","workspaceName":"Personal"}}"#.utf8),
            limits: Data(#"{"rateLimits":{"primary":{"usedPercent":90}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":71,"windowDurationMins":10080,"resetsAt":1795000308},"credits":{"balance":"123.45"}}}}"#.utf8),
            usage: Data(#"{"summary":{"lifetimeTokens":38000000000,"peakDailyTokens":4000000000,"currentStreakDays":87,"longestStreakDays":90}}"#.utf8),
            home: URL(fileURLWithPath: "/tmp/codex"), now: Date()
        )
        #expect(snapshot.title == "test@example.com")
        #expect(snapshot.plan == "pro")
        #expect(snapshot.workspace == "Personal")
        #expect(snapshot.limits?.windows.first?.remainingPercent == 29)
        #expect(snapshot.limits?.windows.first?.title == "Weekly")
        #expect(snapshot.limits?.creditBalance == "123.45")
        #expect(snapshot.lifetimeTokens == 38_000_000_000)
        #expect(snapshot.currentStreakDays == 87)
    }

    @Test func unavailableMetricsAreNotTreatedAsZero() throws {
        let snapshot = try CodexAccountSnapshot.decode(
            account: Data(#"{"account":{"type":"chatgpt","email":null,"planType":"plus"}}"#.utf8),
            limits: nil, usage: Data(#"{"summary":{"lifetimeTokens":null,"peakDailyTokens":-1}}"#.utf8),
            home: URL(fileURLWithPath: "/tmp/codex"), now: Date()
        )
        #expect(snapshot.title == "Codex account")
        #expect(snapshot.lifetimeTokens == nil)
        #expect(snapshot.peakDailyTokens == nil)
        #expect(snapshot.limits == nil)
    }

    @Test func apiKeyAccountsNeedNoEmailAndDoNotInventPlanLimits() throws {
        let snapshot = try CodexAccountSnapshot.decode(
            account: Data(#"{"account":{"type":"apiKey"}}"#.utf8), limits: nil, usage: nil,
            home: URL(fileURLWithPath: "/tmp/codex"), now: Date()
        )
        #expect(snapshot.title == "API key account")
        #expect(snapshot.plan == nil)
        #expect(snapshot.lifetimeTokens == nil)
    }

    @Test func signedOutAccountsHaveAnActionableError() {
        #expect(throws: AccountError.self) {
            try CodexAccountSnapshot.decode(
                account: Data(#"{"account":null}"#.utf8), limits: nil, usage: nil,
                home: URL(fileURLWithPath: "/tmp/codex"), now: Date()
            )
        }
    }
}
