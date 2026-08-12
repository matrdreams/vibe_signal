import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import VibeSignalCore

final class SettingsWindowController: NSWindowController {
    init(paths: VibeSignalPaths) {
        let view = SettingsView(paths: paths)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Vibe Signal Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 610))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct SettingsView: View {
    let paths: VibeSignalPaths

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.accentColor.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                AppHeader()

                SettingsSection(title: "Notifications") {
                    NotificationSettings()
                }

                SettingsSection(title: "Codex") {
                    CodexIntegrationToggle()
                }

                SettingsSection(title: "General") {
                    if #available(macOS 13.0, *) {
                        LaunchAtLoginToggle()
                    }
                }

                SettingsSection(title: "Diagnostics") {
                    VStack(spacing: 0) {
                        DiagnosticRow(
                            icon: "network",
                            title: "Status socket",
                            value: paths.socketURL.path,
                            displayValue: paths.socketURL.lastPathComponent
                        )
                        CardDivider()
                        DiagnosticRow(
                            icon: "doc.text",
                            title: "State snapshot",
                            value: paths.snapshotURL.path,
                            displayValue: (paths.snapshotURL.path as NSString).abbreviatingWithTildeInPath
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 520, height: 610)
    }
}

private struct AppHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Vibe Signal")
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Monitoring locally")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .frame(height: 62)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            content
                .padding(.horizontal, 15)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
    }
}

private struct NotificationSettings: View {
    @AppStorage(NotificationPreferences.attentionKey) private var needsAttention = true
    @AppStorage(NotificationPreferences.completionKey) private var completion = true

    var body: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                icon: "hand.raised.fill",
                tint: .orange,
                title: "Needs attention",
                detail: "Approval, a question, or an error",
                isOn: $needsAttention
            )
            CardDivider()
            SettingsToggleRow(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "Task finished",
                detail: "Only after running for 15 seconds",
                isOn: $completion
            )
        }
        .onChange(of: needsAttention) { enabled in
            requestAuthorization(if: enabled)
        }
        .onChange(of: completion) { enabled in
            requestAuthorization(if: enabled)
        }
    }

    private func requestAuthorization(if enabled: Bool) {
        guard enabled else {
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            SettingIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .frame(height: 57)
    }
}

private struct DiagnosticRow: View {
    let icon: String
    let title: String
    let value: String
    let displayValue: String
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 12) {
            SettingIcon(systemName: icon, tint: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(displayValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(didCopy ? "Copied" : "Copy full path")
        }
        .frame(height: 53)
    }
}

private struct SettingIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 30, height: 30)
    }
}

private struct CardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 42)
    }
}

private final class CodexIntegrationModel: ObservableObject {
    @Published var isEnabled = false
    @Published var detail: String?

    private let manager: CodexHookConfigurationManager

    init() {
        let executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("vibe-signal")
        manager = CodexHookConfigurationManager(executableURL: executableURL)
        isEnabled = manager.isInstalled()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try manager.install()
                detail = "Enabled. Codex may ask you to review this hook once."
            } else {
                try manager.uninstall()
                detail = nil
            }
        } catch {
            detail = error.localizedDescription
        }
        isEnabled = manager.isInstalled()
    }
}

private struct CodexIntegrationToggle: View {
    @StateObject private var model = CodexIntegrationModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SettingIcon(systemName: "bolt.fill", tint: .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Instant status detection")
                        .font(.body.weight(.medium))
                    Text("Local lifecycle hints; final colours use verified events")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .frame(height: 57)

            if let detail = model.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(model.isEnabled ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 42)
                    .padding(.bottom, 10)
            }
        }
    }
}

@available(macOS 13.0, *)
private final class LaunchAtLoginModel: ObservableObject {
    @Published var isEnabled = SMAppService.mainApp.status == .enabled
    @Published var detail: String?

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            detail = nil
        } catch {
            detail = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

@available(macOS 13.0, *)
private struct LaunchAtLoginToggle: View {
    @StateObject private var model = LaunchAtLoginModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SettingIcon(systemName: "power", tint: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.body.weight(.medium))
                    Text("Keep task status available automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { model.setEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .frame(height: 57)

            if let detail = model.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 42)
                    .padding(.bottom, 10)
            }
        }
    }
}
