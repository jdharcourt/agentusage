import Foundation

public struct Tokens: Codable, Equatable, Sendable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0

    public var total: Int64 { input + output }

    public init(input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0) {
        self.input = max(0, input)
        self.cached = min(max(0, cached), self.input)
        self.cacheWrite = min(max(0, cacheWrite), self.input - self.cached)
        self.output = max(0, output)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Tokens(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached,
               cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output)
    }

    func delta(from previous: Self) -> Self {
        Tokens(input: input - previous.input, cached: cached - previous.cached,
               cacheWrite: cacheWrite - previous.cacheWrite, output: output - previous.output)
    }
}

public struct UsageSample: Sendable {
    let fingerprint: String
    public let date: Date
    public let model: String
    public let tokens: Tokens
}

public struct UsageTotal: Sendable {
    public var tokens = Tokens()
    public var estimatedCost = 0.0
    public var unpricedTokens: Int64 = 0
    public var models: [String: Tokens] = [:]

    public init() {}

    mutating func add(_ sample: UsageSample, prices: PriceBook) {
        tokens = tokens + sample.tokens
        models[sample.model, default: Tokens()] = models[sample.model, default: Tokens()] + sample.tokens
        if let cost = prices.cost(for: sample.tokens, model: sample.model) {
            estimatedCost += cost
        } else {
            unpricedTokens += sample.tokens.total
        }
    }
}

public struct AgentSession: Identifiable, Sendable {
    public let id: String
    public let project: String
    public let name: String?
    public let model: String
    public let lastActivity: Date
    public let taskOpen: Bool
    public let tokens: Tokens

    public func isRunning(at now: Date) -> Bool {
        taskOpen && now.timeIntervalSince(lastActivity) < 600 && lastActivity <= now
    }

    public func status(at now: Date) -> String {
        if isRunning(at: now) { return "Running" }
        return taskOpen ? "Unconfirmed" : "Idle"
    }
}

public struct LimitWindow: Identifiable, Sendable {
    public let id: String
    public let usedPercent: Double
    public let minutes: Int
    public let resetsAt: Date?

    public var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    public var title: String {
        if minutes == 10080 { return "Weekly" }
        if minutes > 0 && minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes > 0 && minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return minutes > 0 ? "\(minutes)-minute" : "Usage window"
    }

    public func hasExpired(at now: Date) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }
}

public struct PlanLimits: Sendable {
    public let observedAt: Date
    public let plan: String?
    public let windows: [LimitWindow]
    public let creditBalance: String?
}

public struct UsageSnapshot: Sendable {
    public let updatedAt: Date
    public let today: UsageTotal
    public let lifetime: UsageTotal
    public let sessions: [AgentSession]
    public let limits: PlanLimits?
    public let fileCount: Int
    public let unreadableFiles: Int
    public let malformedLines: Int
    public let oldestRecord: Date?

    public var running: [AgentSession] { sessions.filter { $0.isRunning(at: updatedAt) } }
}
