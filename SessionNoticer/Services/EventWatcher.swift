import Foundation
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "watcher")

class EventWatcher {
    private let eventsDirectory: URL
    private var dirSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var fallbackTimer: Timer?
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
        startDirectoryWatch()
        // Backup poll at low frequency in case a filesystem event is missed
        // (e.g. volume sleep/wake) or the DispatchSource failed to attach.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.processAllEvents()
        }
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        dirSource?.cancel()
        dirSource = nil
    }

    private func startDirectoryWatch() {
        let fd = open(eventsDirectory.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("open() failed for \(self.eventsDirectory.path, privacy: .public) — falling back to poll only")
            return
        }
        dirFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.processAllEvents()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.dirFD >= 0 {
                close(self.dirFD)
                self.dirFD = -1
            }
        }
        source.resume()
        dirSource = source
        logger.info("DispatchSource watching \(self.eventsDirectory.path, privacy: .public)")
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
