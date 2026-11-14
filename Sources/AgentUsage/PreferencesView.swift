import AppKit
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("menuBarMetric") private var metric = "remaining"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Menu bar", selection: $metric) {
                    Text("Usage remaining").tag("remaining")
                    Text("Running agents").tag("agents")
                    Text("Today's API value").tag("cost")
                    Text("Today's tokens").tag("tokens")
                }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                }))
                if let loginError {
                    Text(loginError).foregroundStyle(.secondary)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("Codex account") {
                if let account = store.account {
                    LabeledContent("Account", value: account.title)
                    if let plan = account.plan { LabeledContent("Plan", value: plan.capitalized) }
                } else {
                    Text(store.accountError ?? "Detecting your existing Codex sign-in…")
                        .foregroundStyle(.secondary)
                }
                Text("Account and data location are detected automatically. Uses Codex's existing sign-in to check limits and account totals every minute. Local token and agent history refreshes every 5 seconds.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Estimates") {
                Text("API value uses standard USD token prices bundled on 14 November 2026. It is not billed spend or a subscription charge. Unknown models are excluded; fast tiers and tool charges are not included.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Link("OpenAI pricing", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
            }
        }
        .formStyle(.grouped)
        .tint(.primary)
        .frame(width: 460, height: 410)
    }
}
