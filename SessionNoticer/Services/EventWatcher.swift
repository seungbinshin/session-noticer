import Foundation

class EventWatcher {
    private let eventsDirectory: URL
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let fileDescriptor: Int32
    var onEvent: ((HookEvent) -> Void)?

    init(eventsDirectory: URL) {
        self.eventsDirectory = eventsDirectory
        try? FileManager.default.createDirectory(at: eventsDirectory, withIntermediateDirectories: true)
        self.fileDescriptor = open(eventsDirectory.path, O_EVTONLY)
    }

    deinit {
        stop()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    func processExistingEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        )) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in jsonFiles { processEventFile(file) }
    }

    func start() {
        guard fileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.checkForNewEvents() }
        source.setCancelHandler { }
        source.resume()
        self.dispatchSource = source
    }

    func stop() {
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    private func checkForNewEvents() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        let jsonFiles = files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in jsonFiles { processEventFile(file) }
    }

    private func processEventFile(_ file: URL) {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file) else { return }
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            NSLog("SessionNoticer: Failed to parse event file: \(file.lastPathComponent)")
            return
        }
        onEvent?(event)
    }
}
