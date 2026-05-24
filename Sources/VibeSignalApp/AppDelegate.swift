import AppKit
import VibeSignalCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths = VibeSignalPaths()
    private lazy var store = StatusStore(persistence: SnapshotPersistence(url: paths.snapshotURL))
    private var server: SignalHubServer?
    private var codexMonitor: CodexSessionMonitor?
    private var statusItem: NSStatusItem?
    private var currentSnapshot = SignalSnapshot(globalState: .unknown, sessions: [])
    private var settingsWindowController: SettingsWindowController?
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        var initialSnapshot: SignalSnapshot?
        do {
            try paths.ensureDirectories()
            configureStoreCallback()
            try startHub()
            store.removeEvents(source: "codex", adapter: "codex-session-monitor")
            startCodexMonitor()
            initialSnapshot = store.snapshot()
        } catch let error as VibeSignalError where error.isSocketOwnershipConflict {
            NSApp.terminate(nil)
            return
        } catch {
            configureStoreCallback()
            initialSnapshot = errorSnapshot(error)
        }

        setupStatusItem()
        apply(initialSnapshot ?? store.snapshot())

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.store.pruneExpired()
        }
    }

    private func configureStoreCallback() {
        store.onSnapshotChanged = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        codexMonitor?.stop()
        server?.stop()
    }

    private func startHub() throws {
        let hub = SignalHubServer(socketURL: paths.socketURL) { [weak self] event in
            self?.store.apply(event)
        }
        try hub.start()
        server = hub
    }

    private func startCodexMonitor() {
        let monitor = CodexSessionMonitor { [weak self] event in
            self?.store.apply(event)
        }
        monitor.start()
        codexMonitor = monitor
    }

    private func errorSnapshot(_ error: Error) -> SignalSnapshot {
        SignalSnapshot(
            globalState: .error,
            sessions: [
                SignalEvent(
                    source: "vibe-signal",
                    adapter: "app",
                    sessionId: "hub",
                    state: .error,
                    reason: SignalReason.error,
                    message: error.localizedDescription,
                    updatedAt: Date(),
                    ttlMs: nil
                )
            ]
        )
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Vibe Signal"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
    }

    private func apply(_ snapshot: SignalSnapshot) {
        currentSnapshot = snapshot
        statusItem?.button?.image = TrafficLightIcon.image(for: snapshot.globalState)
        statusItem?.button?.toolTip = "Vibe Signal: \(displayName(for: snapshot.globalState))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Vibe Signal: \(displayName(for: currentSnapshot.globalState))", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let active = currentSnapshot.activeSessions
        if active.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            addHeader("Active Sessions", to: menu)
            for event in active {
                menu.addItem(sessionItem(for: event))
            }
        }

        let recentIdle = Array(currentSnapshot.recentIdleSessions.prefix(5))
        if !recentIdle.isEmpty {
            menu.addItem(.separator())
            addHeader("Recent Idle", to: menu)
            for event in recentIdle {
                menu.addItem(sessionItem(for: event))
            }
        }

        menu.addItem(.separator())

        let openMenu = NSMenu()
        let openItem = NSMenuItem(title: "Open Workspace", action: nil, keyEquivalent: "")
        openItem.submenu = openMenu
        let workspaces = currentSnapshot.sessions.compactMap(\.workspace)
        if workspaces.isEmpty {
            let none = NSMenuItem(title: "No workspace", action: nil, keyEquivalent: "")
            none.isEnabled = false
            openMenu.addItem(none)
        } else {
            for workspace in unique(workspaces) {
                let item = NSMenuItem(
                    title: workspaceName(workspace),
                    action: #selector(openWorkspace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = workspace
                openMenu.addItem(item)
            }
        }
        menu.addItem(openItem)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Vibe Signal", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    private func sessionItem(for event: SignalEvent) -> NSMenuItem {
        let workspace = event.workspace.map(workspaceName) ?? event.sessionId
        let detail = event.message ?? event.reason
        let item = NSMenuItem(title: "\(workspace) - \(detail)", action: nil, keyEquivalent: "")
        item.image = TrafficLightIcon.dot(for: event.state)
        item.toolTip = "\(event.source) / \(event.adapter) / \(event.sessionId)"
        return item
    }

    @objc private func openWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else {
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(paths: paths)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func displayName(for state: SignalState) -> String {
        switch state {
        case .blocked:
            return "Needs input"
        case .working:
            return "Working"
        case .idle:
            return "Idle"
        case .error:
            return "Error"
        case .unknown:
            return "Unknown"
        }
    }

    private func workspaceName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
