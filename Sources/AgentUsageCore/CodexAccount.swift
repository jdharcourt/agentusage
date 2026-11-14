import Darwin
import Foundation

public struct CodexInstallation: Sendable {
    public let executable: URL

    public static var defaultHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static func detect() throws -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        for root in [".vscode/extensions", ".vscode-insiders/extensions", ".cursor/extensions"] {
            let directory = home.appendingPathComponent(root)
            let extensions = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for entry in extensions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) where entry.lastPathComponent.hasPrefix("openai.chatgpt-") {
                #if arch(arm64)
                paths.append(entry.appendingPathComponent("bin/macos-aarch64/codex").path)
                #else
                paths.append(entry.appendingPathComponent("bin/macos-x86_64/codex").path)
                #endif
            }
        }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AccountError.missingCodex
        }
        return Self(executable: URL(fileURLWithPath: path))
    }
}

public struct CodexAccountSnapshot: Sendable {
    public let home: URL
    public let observedAt: Date
    public let type: String
    public let email: String?
    public let plan: String?
    public let workspace: String?
    public let limits: PlanLimits?
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?

    public var title: String {
        if let email { return email }
        if type == "apiKey" { return "API key account" }
        if type == "amazonBedrock" { return "Amazon Bedrock" }
        return "Codex account"
    }

    static func decode(account: Data, limits: Data?, usage: Data?, home: URL, now: Date) throws -> Self {
        let decoder = JSONDecoder()
        guard let account = try decoder.decode(AccountResponse.self, from: account).account else {
            throw AccountError.notSignedIn
        }
        let rawLimits = limits.flatMap { try? decoder.decode(LimitsResponse.self, from: $0) }
        let bucket = rawLimits?.rateLimitsByLimitId?["codex"] ?? rawLimits?.rateLimits
        let summary = usage.flatMap { try? decoder.decode(UsageResponse.self, from: $0).summary }
        let windows = [("primary", bucket?.primary), ("secondary", bucket?.secondary)].compactMap { key, raw -> LimitWindow? in
            guard let raw, raw.usedPercent.isFinite else { return nil }
            return LimitWindow(id: key, usedPercent: raw.usedPercent, minutes: raw.windowDurationMins ?? 0,
                               resetsAt: raw.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        return Self(
            home: home, observedAt: now, type: account.type,
            email: account.email.map { String($0.prefix(320)) },
            plan: account.planType.map { String($0.prefix(100)) },
            workspace: account.workspaceName.map { String($0.prefix(200)) },
            limits: bucket.map { _ in
                PlanLimits(observedAt: now, plan: bucket?.planType ?? account.planType, windows: windows,
                           creditBalance: bucket?.credits?.balance.map { String($0.prefix(64)) })
            },
            lifetimeTokens: summary?.lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil },
            peakDailyTokens: summary?.peakDailyTokens.flatMap { $0 >= 0 ? $0 : nil },
            currentStreakDays: summary?.currentStreakDays.flatMap { $0 >= 0 ? $0 : nil },
            longestStreakDays: summary?.longestStreakDays.flatMap { $0 >= 0 ? $0 : nil }
        )
    }
}

public actor CodexAccountClient {
    public init() {}

    public func fetch() throws -> CodexAccountSnapshot {
        let installation = try CodexInstallation.detect()
        let connection = try AccountConnection(executable: installation.executable)
        defer { connection.close() }
        let initialization = try connection.request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "agentusage", "title": "AgentUsage", "version": "0.1.0"]
        ])
        try connection.notify(method: "initialized")
        let homePath = (initialization["codexHome"] as? String).flatMap {
            $0.hasPrefix("/") && $0.count <= 4096 ? $0 : nil
        }
        let home = homePath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? CodexInstallation.defaultHome
        let account = try connection.request(id: 2, method: "account/read", params: ["refreshToken": false])
        let type = (account["account"] as? [String: Any])?["type"] as? String
        let limits = type == "chatgpt" ? try? connection.request(id: 3, method: "account/rateLimits/read") : nil
        let usage = type == "chatgpt" ? try? connection.request(id: 4, method: "account/usage/read") : nil
        return try CodexAccountSnapshot.decode(
            account: JSONSerialization.data(withJSONObject: account),
            limits: limits.map { try JSONSerialization.data(withJSONObject: $0) },
            usage: usage.map { try JSONSerialization.data(withJSONObject: $0) }, home: home, now: Date()
        )
    }
}

public enum AccountError: LocalizedError {
    case missingCodex
    case notSignedIn
    case unavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .missingCodex: "Codex was not found. Install the Codex app or CLI; AgentUsage will detect it automatically."
        case .notSignedIn: "Sign in to Codex. AgentUsage will detect your account automatically."
        case .unavailable: "Codex account details are unavailable. Open Codex and check your sign-in; AgentUsage will retry automatically."
        case .timedOut: "Codex took too long to respond. AgentUsage will retry automatically."
        }
    }
}

private final class AccountConnection {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var pending = Data()
    let deadline = Date().addingTimeInterval(20)

    init(executable: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "analytics.enabled=false"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        try process.run()
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }

    func notify(method: String) throws {
        var data = try JSONSerialization.data(withJSONObject: ["method": method])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func request(id: Int, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        while Date() < deadline {
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end])
                pending.removeSubrange(...end)
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      response["id"] as? Int == id else { continue }
                guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
                    throw AccountError.unavailable
                }
                return result
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                throw AccountError.unavailable
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0, pending.count + count <= 4_194_304 else { throw AccountError.unavailable }
            pending.append(contentsOf: bytes.prefix(count))
        }
        throw AccountError.timedOut
    }
}

private struct AccountResponse: Decodable {
    let account: Account?

    struct Account: Decodable {
        let type: String
        let email: String?
        let planType: String?
        let workspaceName: String?
    }
}

private struct LimitsResponse: Decodable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?

    struct Bucket: Decodable {
        let planType: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }

    struct Credits: Decodable {
        let balance: String?
    }
}

private struct UsageResponse: Decodable {
    let summary: Summary

    struct Summary: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }
}
