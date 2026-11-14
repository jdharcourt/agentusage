import Foundation
import Testing
@testable import AgentUsageCore

struct SessionReaderTests {
    @Test func cumulativeUsageIsNotCountedTwice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.meta(), fixture.context("gpt-6.1-sol"),
            fixture.usage(input: 1000, cached: 400, output: 100),
            fixture.usage(input: 1000, cached: 400, output: 100, second: 2),
            fixture.usage(input: 1600, cached: 800, output: 200, second: 3)
        ])
        let reader = try SessionReader(prices: PriceBook.bundled())
        let first = try await reader.scan(home: fixture.home, now: fixture.now)
        let second = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(first.lifetime.tokens == Tokens(input: 1600, cached: 800, output: 200))
        #expect(second.lifetime.tokens == first.lifetime.tokens)
        #expect(first.today.tokens == first.lifetime.tokens)
        #expect(abs(first.lifetime.estimatedCost - 0.00368) < 0.0000001)
    }

    @Test func appendedPartialRecordIsReadOnceComplete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), fixture.context("gpt-6.1-sol")])
        let line = fixture.usage(input: 1000, output: 100)
        let middle = line.index(line.startIndex, offsetBy: line.count / 2)
        try fixture.append(String(line[..<middle]))
        let reader = try SessionReader(prices: PriceBook.bundled())
        let partial = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(partial.lifetime.tokens.total == 0)
        try fixture.append(String(line[middle...]) + "\n")
        let complete = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(complete.lifetime.tokens.total == 1100)
        let repeated = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(repeated.lifetime.tokens.total == 1100)
    }

    @Test func inheritedHistoryAndArchiveCopiesAreDeduplicated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inherited = [fixture.context("gpt-6.1-sol"), fixture.usage(input: 1000, output: 100)]
        try fixture.write([fixture.meta(id: "parent")] + inherited)
        try fixture.write([fixture.meta(id: "child")] + inherited + [
            fixture.usage(input: 1500, output: 200, second: 2)
        ], file: "sessions/child.jsonl")
        try fixture.write([fixture.meta(id: "parent")] + inherited, file: "archived_sessions/copy.jsonl")
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.lifetime.tokens.total == 1700)
        #expect(snapshot.sessions.count == 2)
    }

    @Test func modelChangesAndUnknownModelsKeepCorrectTokenTotals() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.meta(), fixture.context("gpt-6.1-sol"),
            fixture.usage(input: 1000, output: 100),
            fixture.context("unpublished-model"),
            fixture.usage(input: 2000, output: 300, second: 2)
        ])
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.lifetime.tokens.total == 2300)
        #expect(snapshot.lifetime.unpricedTokens == 1200)
        #expect(snapshot.lifetime.models["gpt-6.1-sol"]?.total == 1100)
        #expect(abs(snapshot.lifetime.estimatedCost - 0.003) < 0.0000001)
    }

    @Test func counterResetDoesNotErasePreviousUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.meta(), fixture.context("gpt-6.1-sol"),
            fixture.usage(input: 1000, output: 100),
            fixture.usage(input: 200, output: 20, second: 2)
        ])
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.lifetime.tokens.total == 1320)
    }

    @Test func taskLifecycleAndStaleTasksAreDistinguished() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), fixture.event("task_started")])
        let reader = try SessionReader(prices: PriceBook.bundled())
        let running = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(running.running.count == 1)
        let stale = try await reader.scan(home: fixture.home, now: fixture.now.addingTimeInterval(601))
        #expect(stale.running.isEmpty)
        #expect(stale.sessions.first?.status(at: stale.updatedAt) == "Unconfirmed")
        try fixture.append(fixture.event("task_complete", second: 2) + "\n")
        let complete = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(complete.running.isEmpty)
        #expect(complete.sessions.first?.status(at: complete.updatedAt) == "Idle")
    }

    @Test func newestPlanLimitWinsAndExpiredLimitsRemainUnconfirmed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.meta(),
            fixture.line(type: "event_msg", payload: [
                "type": "token_count", "rate_limits": [
                    "limit_id": "codex", "plan_type": "pro",
                    "primary": ["used_percent": 71, "window_minutes": 10080, "resets_at": fixture.now.timeIntervalSince1970 + 60],
                    "credits": ["balance": "123.45"]
                ]
            ], second: 3)
        ])
        try fixture.write([fixture.meta(id: "older"), fixture.line(type: "event_msg", payload: [
            "type": "token_count", "rate_limits": ["primary": ["used_percent": 20, "window_minutes": 300]]
        ])], file: "sessions/older.jsonl")
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        let limit = try #require(snapshot.limits?.windows.first)
        #expect(limit.title == "Weekly")
        #expect(limit.remainingPercent == 29)
        #expect(!limit.hasExpired(at: fixture.now))
        #expect(limit.hasExpired(at: fixture.now.addingTimeInterval(61)))
        #expect(snapshot.limits?.creditBalance == "123.45")
    }

    @Test func truncatedFilesAreRebuiltAndDeletedHistoryIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), fixture.context("gpt-6.1-sol"), fixture.usage(input: 1000, output: 100)])
        let reader = try SessionReader(prices: PriceBook.bundled())
        _ = try await reader.scan(home: fixture.home, now: fixture.now)
        try fixture.write([fixture.meta(), fixture.usage(input: 10, output: 1)])
        let truncated = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(truncated.lifetime.tokens.total == 11)
        try FileManager.default.removeItem(at: fixture.home.appendingPathComponent("sessions/test.jsonl"))
        let deleted = try await reader.scan(home: fixture.home, now: fixture.now)
        #expect(deleted.lifetime.tokens.total == 0)
        #expect(deleted.sessions.isEmpty)
    }

    @Test func malformedAndOversizedRecordsDoNotBlockLaterUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), "{\"type\":\"token_count\",broken", String(repeating: "x", count: 1_048_577),
                           fixture.usage(input: 1000, output: 100)])
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.lifetime.tokens.total == 1100)
        #expect(snapshot.malformedLines == 2)
    }

    @Test func credentialsAndSymlinkedLogsAreIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), fixture.usage(input: 100, output: 10)])
        try Data("not a session or credential to parse".utf8).write(to: fixture.home.appendingPathComponent("auth.json"))
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appendingPathComponent("sessions/link.jsonl"),
            withDestinationURL: fixture.home.appendingPathComponent("auth.json")
        )
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.malformedLines == 0)
    }

    @Test func oversizedConversationContentDoesNotImplyMissingUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.meta(),
            "{\"type\":\"response_item\",\"payload\":{\"content\":\"" + String(repeating: "x", count: 1_048_577) + "\"}}",
            fixture.usage(input: 1000, output: 100)
        ])
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: fixture.home, now: fixture.now)
        #expect(snapshot.lifetime.tokens.total == 1100)
        #expect(snapshot.malformedLines == 0)
    }

    @Test func todayUsesTheSelectedCalendarDay() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([fixture.meta(), fixture.usage(input: 100, output: 10)])
        let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(
            home: fixture.home, now: fixture.now.addingTimeInterval(86400)
        )
        #expect(snapshot.today.tokens.total == 0)
        #expect(snapshot.lifetime.tokens.total == 110)
    }

    @Test func missingHomeHasAnActionableError() async throws {
        let reader = try SessionReader(prices: PriceBook.bundled())
        await #expect(throws: ReaderError.self) {
            try await reader.scan(home: URL(fileURLWithPath: "/private/tmp/agentusage-missing-\(UUID())"))
        }
    }

    @Test func cachePricingAndDatedModelsAreSupported() throws {
        let prices = try PriceBook.bundled()
        let cost = try #require(prices.cost(
            for: Tokens(input: 1_000_000, cached: 400_000, cacheWrite: 100_000, output: 100_000),
            model: "gpt-6.1-sol-2026-11-01"
        ))
        #expect(abs(cost - 2.29) < 0.0000001)
        #expect(prices.cost(for: Tokens(input: 100), model: "gpt-6.1-sol-unknown") == nil)
        #expect(prices.cost(for: Tokens(input: 100), model: "codex-auto-review") == nil)
        #expect(Tokens(input: 100, cached: 200, cacheWrite: 100, output: -10) == Tokens(input: 100, cached: 100))
    }
}

private struct Fixture {
    let home: URL
    let now = Date(timeIntervalSince1970: 1_794_700_810)

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("AgentUsage-tests-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    func write(_ lines: [String], file: String = "sessions/test.jsonl") throws {
        let url = home.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    func append(_ string: String) throws {
        let handle = try FileHandle(forWritingTo: home.appendingPathComponent("sessions/test.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
    }

    func line(type: String, payload: [String: Any], second: Int = 1) -> String {
        let timestamp = now.addingTimeInterval(Double(second - 10)).formatted(.iso8601)
        let data = try! JSONSerialization.data(withJSONObject: ["timestamp": timestamp, "type": type, "payload": payload], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func meta(id: String = "test") -> String {
        line(type: "session_meta", payload: ["id": id, "cwd": "/tmp/project", "agent_nickname": "Test agent"])
    }

    func context(_ model: String) -> String {
        line(type: "turn_context", payload: ["model": model])
    }

    func event(_ type: String, second: Int = 1) -> String {
        line(type: "event_msg", payload: ["type": type], second: second)
    }

    func usage(input: Int, cached: Int = 0, output: Int, second: Int = 1) -> String {
        line(type: "event_msg", payload: [
            "type": "token_count", "info": [
                "total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output],
                "last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]
            ]
        ], second: second)
    }
}
