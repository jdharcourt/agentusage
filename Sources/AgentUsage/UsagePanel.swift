import AgentUsageCore
import AppKit
import SwiftUI

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    let openPreferences: () -> Void
    @State private var tab = "Overview"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 18, weight: .medium))
                Text("AgentUsage").font(.system(size: 16, weight: .semibold))
                Spacer()
                if let plan = store.account?.plan ?? store.limits?.plan {
                    Text(plan.capitalized).foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.refresh() }
                    Task { await store.refreshAccount() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .disabled(store.refreshing || store.checkingAccount)
                .help("Refresh usage (⌘R)")
                .accessibilityLabel("Refresh usage")
                .keyboardShortcut("r")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            HStack(spacing: 24) {
                ForEach(["Overview", "Agents", "History"], id: \.self) { title in
                    Button { tab = title } label: {
                        VStack(spacing: 10) {
                            HStack(spacing: 4) {
                                Text(title)
                                if title == "Agents", let snapshot = store.snapshot {
                                    Text("\(snapshot.running.count)").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(tab == title ? .primary : .secondary)
                            Rectangle()
                                .fill(tab == title ? Color.primary : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == title ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let account = store.account {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(account.title, systemImage: "person.crop.circle")
                                .fontWeight(.medium).lineLimit(1).textSelection(.enabled)
                            if let workspace = account.workspace {
                                Text(workspace).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    } else if store.checkingAccount {
                        Text("Detecting your Codex account…").foregroundStyle(.secondary)
                    }
                    if let error = store.accountError {
                        Text(error).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let snapshot = store.snapshot {
                        if snapshot.unreadableFiles > 0 || snapshot.malformedLines > 0 {
                            Text("Some history could not be read: \(snapshot.unreadableFiles) files, \(snapshot.malformedLines) skipped records.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        switch tab {
                        case "Agents": AgentsView(snapshot: snapshot)
                        case "History": HistoryView(snapshot: snapshot, account: store.account)
                        default: OverviewView(snapshot: snapshot, limits: store.limits, liveLimits: store.account?.limits != nil)
                        }
                    } else if store.refreshing {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Reading local Codex history…").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        Text("Waiting for Codex usage. Your account and history are detected automatically.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 440)

            Divider()
            HStack(spacing: 8) {
                if let snapshot = store.snapshot {
                    Text(snapshot.updatedAt, style: .relative)
                        .help("Last read of local logs; plan limits have their own observation time.")
                    Text("· \(store.account?.limits == nil ? "Local history" : "Account connected")")
                } else {
                    Text("Automatic detection")
                }
                Spacer()
                Button(action: openPreferences) {
                    Image(systemName: "gearshape").frame(width: 28, height: 28)
                }
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
                .keyboardShortcut(",")
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power").frame(width: 28, height: 28)
                }
                .help("Quit AgentUsage (⌘Q)")
                .accessibilityLabel("Quit AgentUsage")
                .keyboardShortcut("q")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .frame(height: 44)
        }
        .font(.system(size: 13))
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
        .task { await store.refresh() }
    }
}

private struct OverviewView: View {
    let snapshot: UsageSnapshot
    let limits: PlanLimits?
    let liveLimits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Plan limits").fontWeight(.semibold)
                Spacer()
                if let limits {
                    Text("\(liveLimits ? "Checked" : "Observed") \(limits.observedAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let limits {
                ForEach(limits.windows) { window in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(window.title)
                            Spacer()
                            Text(window.hasExpired(at: snapshot.updatedAt)
                                 ? "Awaiting update"
                                 : "\(Int(window.remainingPercent.rounded()))% remaining")
                                .monospacedDigit().fontWeight(.medium)
                        }
                        ProgressView(value: window.remainingPercent, total: 100)
                            .tint(Color(nsColor: .labelColor))
                            .accessibilityLabel("\(window.title) usage remaining")
                            .accessibilityValue("\(Int(window.remainingPercent.rounded())) percent, last observed")
                        if let reset = window.resetsAt {
                            Text(window.hasExpired(at: snapshot.updatedAt)
                                 ? "Reset time passed. Waiting for fresh limits."
                                 : "Resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                if let balance = limits.creditBalance {
                    StatRow(title: "Credits", value: Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX"))?
                        .formatted(.number.precision(.fractionLength(0...2))) ?? balance, detail: balance)
                        .help("Codex's recorded credit balance, in its reported units. This is not a dollar balance.")
                }
                if snapshot.updatedAt.timeIntervalSince(limits.observedAt) > 900 {
                    Text("Limits are from your last Codex activity and may have changed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Plan limits appear automatically for a signed-in ChatGPT account. API-key accounts do not expose a plan allowance.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("Today").fontWeight(.semibold)
            VStack(spacing: 10) {
                StatRow(title: "Tokens", value: snapshot.today.tokens.total.tokenText,
                        detail: snapshot.today.tokens.total.formatted())
                StatRow(title: "Estimated API value", value: snapshot.today.costText)
                StatRow(title: "Cached input", value: snapshot.today.tokens.cached.tokenText,
                        detail: snapshot.today.tokens.cached.formatted())
                StatRow(title: "Running agents", value: "\(snapshot.running.count)")
            }
            if let session = snapshot.running.first ?? snapshot.sessions.first {
                Divider()
                Text(snapshot.running.isEmpty ? "Latest session" : "Current session").fontWeight(.semibold)
                SessionRow(session: session, now: snapshot.updatedAt)
            }
            Text("API value is an estimate, not your bill.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .help("Uses bundled standard USD token prices. Subscription usage is not an API charge. Fast tiers, tools, regional charges, and unknown models are not priced.")
        }
    }
}

private struct AgentsView: View {
    let snapshot: UsageSnapshot

    private var recent: [AgentSession] {
        snapshot.sessions.filter { !$0.isRunning(at: snapshot.updatedAt) }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Running agents · \(snapshot.running.count)").fontWeight(.semibold)
            if snapshot.running.isEmpty {
                Text("No agents currently observed running.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.running) { session in
                SessionRow(session: session, now: snapshot.updatedAt)
                Divider()
            }
            Text("Inferred from task events in local logs. Tasks with no updates for 10 minutes are unconfirmed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !recent.isEmpty {
                Divider()
                Text("Recent sessions").fontWeight(.semibold)
                ForEach(recent) { session in
                    SessionRow(session: session, now: snapshot.updatedAt)
                    if session.id != recent.last?.id { Divider() }
                }
            }
        }
    }
}

private struct HistoryView: View {
    let snapshot: UsageSnapshot
    let account: CodexAccountSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account, let tokens = account.lifetimeTokens {
                Text("Account lifetime").fontWeight(.semibold)
                VStack(spacing: 10) {
                    StatRow(title: "Total tokens", value: tokens.tokenText, detail: tokens.formatted())
                    if let peak = account.peakDailyTokens {
                        StatRow(title: "Peak daily tokens", value: peak.tokenText, detail: peak.formatted())
                    }
                    if let streak = account.currentStreakDays {
                        StatRow(title: "Current streak", value: "\(streak) days")
                    }
                    if let streak = account.longestStreakDays {
                        StatRow(title: "Longest streak", value: "\(streak) days")
                    }
                }
                Text("Reported by Codex for your account. Billed API spend is not exposed by this connection.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            Text("Lifetime on this Mac").fontWeight(.semibold)
            if let date = snapshot.oldestRecord {
                Text("Available local history since \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                StatRow(title: "Total tokens", value: snapshot.lifetime.tokens.total.tokenText,
                        detail: snapshot.lifetime.tokens.total.formatted())
                StatRow(title: "Estimated API value", value: snapshot.lifetime.costText)
                StatRow(title: "Input", value: snapshot.lifetime.tokens.input.tokenText,
                        detail: snapshot.lifetime.tokens.input.formatted())
                StatRow(title: "Cached input", value: snapshot.lifetime.tokens.cached.tokenText,
                        detail: snapshot.lifetime.tokens.cached.formatted())
                StatRow(title: "Output", value: snapshot.lifetime.tokens.output.tokenText,
                        detail: snapshot.lifetime.tokens.output.formatted())
                StatRow(title: "Sessions", value: snapshot.sessions.count.formatted())
            }
            Divider()
            Text("By model").fontWeight(.semibold)
            ForEach(snapshot.lifetime.models.sorted { $0.value.total > $1.value.total }, id: \.key) { model, tokens in
                StatRow(title: model, value: tokens.total.tokenText, detail: tokens.total.formatted())
            }
            if snapshot.lifetime.unpricedTokens > 0 {
                Text("\(snapshot.lifetime.unpricedTokens.tokenText) tokens have no published price in the bundled price list. Their cost is excluded.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Cached input is included in input. Reasoning is included in output. History from other Macs and deleted logs is unavailable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name ?? session.project).fontWeight(.medium).lineLimit(1)
                Spacer()
                Label(session.status(at: now), systemImage: session.isRunning(at: now) ? "play.circle" : "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Text(session.model).lineLimit(1)
                Spacer()
                Text("\(session.tokens.total.tokenText) tokens").monospacedDigit()
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if session.name != nil {
                Text(session.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct StatRow: View {
    let title: String
    let value: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().textSelection(.enabled).lineLimit(1)
                .help(detail.isEmpty ? value : detail)
                .accessibilityLabel(detail.isEmpty ? value : detail)
        }
    }
}

extension Int64 {
    var tokenText: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

extension UsageTotal {
    var costText: String {
        if tokens.total > 0 && unpricedTokens == tokens.total { return "Unavailable" }
        return estimatedCost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
            + (unpricedTokens > 0 ? " + unpriced" : "")
    }
}
