import Foundation
import Darwin

public actor SessionReader {
    private var files: [String: SessionFile] = [:]
    private let prices: PriceBook
    private var home: URL?

    public init(prices: PriceBook) {
        self.prices = prices
    }

    public func scan(home: URL, now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        if self.home != home {
            files.removeAll()
            self.home = home
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReaderError.missingHome
        }
        var paths = Set<String>()
        var unreadable = 0
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable += 1; return true }
            ) else {
                unreadable += 1
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    paths.insert(url.path)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                    let modified = attributes[.modificationDate] as? Date ?? .distantPast
                    var file = files[url.path] ?? SessionFile()
                    if file.inode != inode || size < file.offset || (size == file.offset && modified != file.modified) {
                        file = SessionFile()
                    }
                    file.inode = inode
                    if size > file.offset { try autoreleasepool { try file.read(url: url, through: size) } }
                    file.modified = modified
                    files[url.path] = file
                } catch {
                    unreadable += 1
                }
            }
        }
        files = files.filter { paths.contains($0.key) }
        var lifetime = UsageTotal()
        var today = UsageTotal()
        var seen = Set<String>()
        var sessions: [String: AgentSession] = [:]
        var limits: PlanLimits?
        var oldest: Date?
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            for sample in file.samples {
                guard seen.insert(sample.fingerprint).inserted else { continue }
                lifetime.add(sample, prices: prices)
                if calendar.isDate(sample.date, inSameDayAs: now) { today.add(sample, prices: prices) }
                oldest = min(oldest ?? sample.date, sample.date)
            }
            let session = AgentSession(
                id: file.id ?? path, project: file.project, name: file.name,
                model: file.model, lastActivity: file.lastActivity, taskOpen: file.taskOpen,
                tokens: file.samples.reduce(Tokens()) { $0 + $1.tokens }
            )
            if session.lastActivity > (sessions[session.id]?.lastActivity ?? .distantPast) {
                sessions[session.id] = session
            }
            if let candidate = file.limits, candidate.observedAt > (limits?.observedAt ?? .distantPast) {
                limits = candidate
            }
        }
        return UsageSnapshot(
            updatedAt: now, today: today, lifetime: lifetime,
            sessions: sessions.values.sorted { $0.lastActivity > $1.lastActivity },
            limits: limits, fileCount: files.count, unreadableFiles: unreadable,
            malformedLines: files.values.reduce(0) { $0 + $1.malformedLines }, oldestRecord: oldest
        )
    }
}

public enum ReaderError: LocalizedError {
    case missingHome

    public var errorDescription: String? {
        "No local Codex history yet. Use Codex and your sessions will appear automatically."
    }
}

private struct SessionFile {
    var inode: UInt64 = 0
    var offset: UInt64 = 0
    var modified = Date.distantPast
    var pending = Data()
    var discardingLine = false
    var id: String?
    var project = "Codex"
    var name: String?
    var model = "Unknown model"
    var lastActivity = Date.distantPast
    var taskOpen = false
    var previous = Tokens()
    var samples: [UsageSample] = []
    var limits: PlanLimits?
    var malformedLines = 0

    mutating func read(url: URL, through size: UInt64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        while offset < size {
            guard let chunk = try handle.read(upToCount: Int(min(65_536, size - offset))), !chunk.isEmpty else { break }
            offset += UInt64(chunk.count)
            chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                guard let base = bytes.baseAddress else { return }
                var start = 0
                while start < bytes.count {
                    let newline = memchr(base.advanced(by: start), 10, bytes.count - start)
                    let end = newline.map { base.distance(to: $0) } ?? bytes.count
                    append(UnsafeRawBufferPointer(start: base.advanced(by: start), count: end - start))
                    guard newline != nil else { break }
                    if !discardingLine { consume(pending) }
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = false
                    start = end + 1
                }
            }
        }
    }

    mutating func append(_ data: UnsafeRawBufferPointer) {
        guard !discardingLine else { return }
        guard pending.count + data.count <= 1_048_576 else {
            let header = String(decoding: pending.prefix(256), as: UTF8.self)
            if header.range(of: #""type"\s*:\s*"(response_item|compacted|item_completed)""#, options: .regularExpression) == nil {
                malformedLines += 1
            }
            pending.removeAll(keepingCapacity: true)
            discardingLine = true
            return
        }
        pending.append(contentsOf: data)
    }

    mutating func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        let header = String(decoding: data.prefix(160), as: UTF8.self)
        if header.contains("\"type\":\"response_item\"") || header.contains("\"type\": \"response_item\"") { return }
        guard Self.markers.contains(where: { data.range(of: $0) != nil }) else { return }
        guard let event = try? JSONDecoder().decode(LogEvent.self, from: data),
              let date = Self.date(event.timestamp) else {
            malformedLines += 1
            return
        }
        let payload = event.payload
        if event.type == "session_meta" {
            id = payload.id
            if let cwd = payload.cwd { project = String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100)) }
            name = payload.agent_nickname.map { String($0.prefix(100)) }
            lastActivity = max(lastActivity, date)
            return
        }
        if event.type == "turn_context" {
            if let value = payload.model { model = String(value.prefix(100)) }
            return
        }
        guard event.type == "event_msg" else { return }
        lastActivity = max(lastActivity, date)
        switch payload.type {
        case "task_started": taskOpen = true
        case "task_complete", "turn_aborted": taskOpen = false
        case "token_count":
            if let raw = payload.rate_limits, raw.limit_id == nil || raw.limit_id == "codex" {
                let windows = [("primary", raw.primary), ("secondary", raw.secondary)].compactMap { key, raw -> LimitWindow? in
                    guard let raw, let used = raw.used_percent, used.isFinite else { return nil }
                    return LimitWindow(id: key, usedPercent: used, minutes: raw.window_minutes ?? 0,
                                       resetsAt: raw.resets_at.map { Date(timeIntervalSince1970: $0) })
                }
                if !windows.isEmpty || raw.credits?.balance != nil {
                    limits = PlanLimits(observedAt: date, plan: raw.plan_type, windows: windows,
                                        creditBalance: raw.credits?.balance.map { String($0.prefix(64)) })
                }
            }
            guard let raw = payload.info?.total_token_usage else { return }
            let total = raw.tokens
            guard total != previous else { return }
            let delta = total.total < previous.total
                ? (payload.info?.last_token_usage?.tokens ?? total)
                : total.delta(from: previous)
            previous = total
            guard delta.total > 0 else { return }
            samples.append(UsageSample(
                fingerprint: "\(event.timestamp):\(total.input):\(total.cached):\(total.cacheWrite):\(total.output)",
                date: date, model: model, tokens: delta
            ))
        default: break
        }
    }

    static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(string, strategy: .iso8601)
    }

    private static let markers = ["session_meta", "turn_context", "token_count", "task_started", "task_complete", "turn_aborted", "item_completed"]
        .map { Data("\"\($0)\"".utf8) }
}

private struct LogEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let id: String?
        let cwd: String?
        let agent_nickname: String?
        let type: String?
        let model: String?
        let info: Info?
        let rate_limits: RawLimits?
    }

    struct Info: Decodable {
        let total_token_usage: RawTokens?
        let last_token_usage: RawTokens?
    }

    struct RawTokens: Decodable {
        let input_tokens: Int64?
        let cached_input_tokens: Int64?
        let cache_write_input_tokens: Int64?
        let output_tokens: Int64?

        var tokens: Tokens {
            Tokens(input: min(input_tokens ?? 0, 1_000_000_000_000),
                   cached: cached_input_tokens ?? 0, cacheWrite: cache_write_input_tokens ?? 0,
                   output: min(output_tokens ?? 0, 1_000_000_000_000))
        }
    }

    struct RawLimits: Decodable {
        let limit_id: String?
        let plan_type: String?
        let primary: Window?
        let secondary: Window?
        let credits: Credits?
    }

    struct Window: Decodable {
        let used_percent: Double?
        let window_minutes: Int?
        let resets_at: Double?
    }

    struct Credits: Decodable {
        let balance: String?
    }
}
