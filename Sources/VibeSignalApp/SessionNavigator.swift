import AppKit
import VibeSignalCore

final class SessionNavigator {
    @discardableResult
    func open(_ event: SignalEvent) -> Bool {
        if let jumpURL = stringMetadata("jump_url", in: event),
           let url = URL(string: jumpURL),
           NSWorkspace.shared.open(url) {
            return true
        }

        if let processIdentifier = processIdentifierMetadata(in: event),
           let application = NSRunningApplication(processIdentifier: processIdentifier),
           application.activate(options: [.activateAllWindows]) {
            return true
        }

        return open(
            jumpURL: nil,
            hostBundleIdentifier: stringMetadata("host_bundle_id", in: event),
            workspace: event.workspace
        )
    }

    @discardableResult
    func open(jumpURL: String?, hostBundleIdentifier: String?, workspace: String?) -> Bool {
        if let jumpURL,
           let url = URL(string: jumpURL),
           NSWorkspace.shared.open(url) {
            return true
        }

        if let bundleIdentifier = hostBundleIdentifier,
           activate(bundleIdentifier: bundleIdentifier) {
            return true
        }

        guard let workspace else {
            return false
        }
        return NSWorkspace.shared.open(URL(fileURLWithPath: workspace, isDirectory: true))
    }

    private func activate(bundleIdentifier: String) -> Bool {
        if let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first {
            return application.activate(options: [.activateAllWindows])
        }

        guard let applicationURL = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    private func stringMetadata(_ key: String, in event: SignalEvent) -> String? {
        guard case .string(let value)? = event.metadata?[key] else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func processIdentifierMetadata(in event: SignalEvent) -> pid_t? {
        switch event.metadata?["host_pid"] {
        case .number(let value):
            guard value.isFinite,
                  value >= 1,
                  value <= Double(Int32.max) else {
                return nil
            }
            return pid_t(value)
        case .string(let value):
            guard let processIdentifier = Int32(value), processIdentifier >= 1 else {
                return nil
            }
            return processIdentifier
        default:
            return nil
        }
    }
}
