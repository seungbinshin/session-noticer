import Foundation
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "watcher")

class EventWatcher {
    private let eventsDirectory: URL
    private var pollTimer: Timer?
    var onEvent: ((HookEvent) -> Void)?

    init(eventsDirectory: URL) {
        self.eventsDirectory = eventsDirectory
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        stop()
    }

    func processExistingEvents() {
        processAllEvents()
    }

    func start() {
        // Poll every 1 second — more reliable than kqueue for small event files
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.processAllEvents()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func processAllEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []

        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in jsonFiles {
            processEventFile(file)
        }
    }

    private func processEventFile(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else {
            return // File might still be written — skip, try next poll
        }

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            // Could be partial write — if older than 5s, it's malformed, delete it
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) > 5 {
                logger.warning("Deleting malformed event file: \(file.lastPathComponent)")
                try? FileManager.default.removeItem(at: file)
            }
            return
        }

        // Successfully parsed — delete and dispatch
        try? FileManager.default.removeItem(at: file)
        logger.debug("Processed event: \(event.event.rawValue) session=\(event.sessionId)")
        onEvent?(event)
    }
}
