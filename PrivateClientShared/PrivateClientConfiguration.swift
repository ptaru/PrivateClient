import Foundation
import Partout

enum PrivateClientConfiguration {
    static let teamIdentifier = "CM6PR6R3U2"
    static let appBundleIdentifier = "uk.tarun.PrivateClient"
    static let tunnelBundleIdentifier = "uk.tarun.PrivateClient.tunnel"
    static let appGroupIdentifier = "group.uk.tarun.PrivateClient"
    static let appDisplayName = "PrivateClient"

    static var sharedContainerURL: URL {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            return containerURL
        }

        let fallback = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrivateClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var cachesURL: URL {
        let url = sharedContainerURL.appending(path: "Library/Caches", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var tunnelLogURL: URL {
        cachesURL.appending(path: "tunnel.log")
    }

    static func moduleURL(for name: String) -> URL {
        let url = cachesURL.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension PrivateClientConfiguration {
    enum Log {
        static let maxLevel: DebugLog.Level = .info
        static let maxSize: UInt64 = 50_000
        static let maxBufferedLines = 2_000
        static let saveInterval: UInt64 = 60_000

        @Sendable
        static func formattedLine(_ line: DebugLog.Line) -> String {
            let timestamp = line.timestamp.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
            )
            return "\(timestamp) - \(line.message)"
        }
    }
}
