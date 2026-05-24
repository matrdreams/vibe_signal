import Darwin
import Foundation

public struct VibeSignalPaths: Sendable {
    public var appSupportDirectory: URL
    public var socketURL: URL
    public var snapshotURL: URL

    public init(
        appSupportDirectory: URL = VibeSignalPaths.defaultAppSupportDirectory(),
        socketURL: URL = VibeSignalPaths.defaultSocketURL(),
        snapshotURL: URL? = nil
    ) {
        self.appSupportDirectory = appSupportDirectory
        self.socketURL = socketURL
        if let snapshotURL {
            self.snapshotURL = snapshotURL
        } else if let override = ProcessInfo.processInfo.environment["VIBE_SIGNAL_SNAPSHOT"] {
            self.snapshotURL = URL(fileURLWithPath: override)
        } else {
            self.snapshotURL = appSupportDirectory.appendingPathComponent("state.json")
        }
    }

    public func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: appSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    public static func defaultAppSupportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["VIBE_SIGNAL_APP_SUPPORT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("VibeSignal", isDirectory: true)
    }

    public static func defaultSocketURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VIBE_SIGNAL_SOCKET"] {
            return URL(fileURLWithPath: override)
        }

        return URL(fileURLWithPath: "/tmp/vibe-signal-\(getuid()).sock")
    }
}
