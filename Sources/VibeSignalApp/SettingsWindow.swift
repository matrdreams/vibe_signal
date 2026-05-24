import AppKit
import ServiceManagement
import SwiftUI
import VibeSignalCore

final class SettingsWindowController: NSWindowController {
    init(paths: VibeSignalPaths) {
        let view = SettingsView(paths: paths)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Vibe Signal Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 360))
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                IconPreview()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vibe Signal")
                        .font(.title2.weight(.semibold))
                    Text("Local status hub for coding agents")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            PathRow(label: "Socket", value: paths.socketURL.path)
            PathRow(label: "Snapshot", value: paths.snapshotURL.path)

            if #available(macOS 13.0, *) {
                LaunchAtLoginToggle()
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct IconPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView(image: TrafficLightIcon.image(for: .idle))
        imageView.setFrameSize(NSSize(width: 24, height: 24))
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

private struct PathRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.headline)
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
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
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { model.isEnabled },
                    set: { model.setEnabled($0) }
                )
            )
            if let detail = model.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
