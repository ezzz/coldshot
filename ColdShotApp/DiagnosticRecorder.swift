import Foundation
import OSLog

final class DiagnosticRecorder: @unchecked Sendable {
    static let shared = DiagnosticRecorder()

    private let lock = NSLock()
    private let maximumLogSize: UInt64 = 5 * 1_024 * 1_024

    private var directoryURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("ColdShot", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var logURL: URL {
        directoryURL.appendingPathComponent("coldshot.log")
    }

    func record(category: String, level: String, message: String) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                try rotateIfNeeded()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"
                let data = Data(line.utf8)
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                // The unified log remains available if the private diagnostic file fails.
            }
        }
    }

    func makeReport(summary: String, subsystem: String) -> String {
        let privateLog = lock.withLock {
            (try? String(contentsOf: logURL, encoding: .utf8)) ?? "Aucun journal applicatif disponible."
        }
        let unifiedLog: String
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: Date().addingTimeInterval(-7 * 24 * 60 * 60))
            unifiedLog = try store.getEntries(at: position).compactMap { entry in
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem == subsystem else { return nil }
                return "\(ISO8601DateFormatter().string(from: log.date)) [\(log.level)] [\(log.category)] \(log.composedMessage)"
            }.joined(separator: "\n")
        } catch {
            unifiedLog = "Journal système indisponible : \(error.localizedDescription)"
        }

        return """
        ColdShot — rapport de diagnostic
        Généré : \(ISO8601DateFormatter().string(from: Date()))

        SYNTHÈSE
        \(summary)

        JOURNAL APPLICATIF
        \(privateLog)

        JOURNAL SYSTÈME COLDSHOT
        \(unifiedLog)
        """
    }

    private func rotateIfNeeded() throws {
        guard let size = try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              UInt64(size) >= maximumLogSize else { return }
        let previousURL = directoryURL.appendingPathComponent("coldshot-previous.log")
        try? FileManager.default.removeItem(at: previousURL)
        try FileManager.default.moveItem(at: logURL, to: previousURL)
    }
}
