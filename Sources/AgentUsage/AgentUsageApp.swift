import AgentUsageCore
import AppKit
import Combine
import SwiftUI

@main
enum AgentUsageMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--diagnose-account") {
            Task.detached {
                do {
                    if CommandLine.arguments.contains("--diagnose-account") {
                        let account = try await CodexAccountClient().fetch()
                        let data = try JSONSerialization.data(withJSONObject: [
                            "accountType": account.type,
                            "hasEmail": account.email != nil,
                            "plan": account.plan ?? "unavailable",
                            "lifetimeTokens": account.lifetimeTokens.map { $0 as Any } ?? NSNull(),
                            "limitWindows": account.limits?.windows.count ?? 0
                        ], options: [.prettyPrinted, .sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        exit(0)
                    }
                    let snapshot = try await SessionReader(prices: PriceBook.bundled()).scan(home: UsageStore.defaultHome)
                    let data = try JSONSerialization.data(withJSONObject: [
                        "files": snapshot.fileCount,
                        "sessions": snapshot.sessions.count,
                        "runningAgents": snapshot.running.count,
                        "lifetimeTokens": snapshot.lifetime.tokens.total,
                        "todayTokens": snapshot.today.tokens.total,
                        "estimatedLifetimeUSD": snapshot.lifetime.estimatedCost,
                        "unpricedTokens": snapshot.lifetime.unpricedTokens,
                        "unreadableFiles": snapshot.unreadableFiles,
                        "skippedLines": snapshot.malformedLines
                    ], options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let controller = StatusBarController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var preferences: NSWindow?
    private var subscriptions: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "AgentUsage")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: UsagePanel(store: store, openPreferences: { [weak self] in
            self?.showPreferences()
        }))
        popover.contentSize = NSSize(width: 400, height: 568)
        store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &subscriptions)
        let menu = NSMenu()
        let appMenu = NSMenu()
        for (title, action, key) in [
            ("Settings…", #selector(showPreferences), ","),
            ("Refresh Usage", #selector(refresh), "r"),
            ("Quit AgentUsage", #selector(quit), "q")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            appMenu.addItem(item)
        }
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApplication.shared.mainMenu = menu
        updateTitle()
        showPanel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func showPreferences() {
        popover.performClose(nil)
        if preferences == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 410),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AgentUsage Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView(store: store))
            window.center()
            preferences = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferences?.makeKeyAndOrderFront(nil)
    }

    @objc private func refresh() {
        Task { await store.refresh() }
        Task { await store.refreshAccount() }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateTitle() {
        let title: String
        switch UserDefaults.standard.string(forKey: "menuBarMetric") ?? "remaining" {
        case "agents": title = store.snapshot.map { "\($0.running.count)" } ?? "—"
        case "cost": title = store.snapshot?.today.costText ?? "—"
        case "tokens": title = store.snapshot?.today.tokens.total.tokenText ?? "—"
        default:
            guard let window = store.limits?.windows.first,
                  !window.hasExpired(at: Date()) else {
                statusItem?.button?.title = " —"
                return
            }
            title = "\(Int(window.remainingPercent.rounded()))%"
        }
        statusItem?.button?.title = " " + title
        statusItem?.button?.toolTip = "AgentUsage · Click for Codex usage"
        statusItem?.button?.setAccessibilityLabel("AgentUsage, \(title)")
    }
}
