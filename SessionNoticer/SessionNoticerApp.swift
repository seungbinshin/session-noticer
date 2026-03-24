import SwiftUI
import Combine

@main
struct SessionNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let sessionManager = SessionManager()
    private var eventWatcher: EventWatcher?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupEventWatcher()
        scanExistingSessions()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateIcon()
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.delegate = self
        let view = MenuBarView(
            sessionManager: sessionManager,
            onSessionTap: { [weak self] session in
                guard let self else { return }
                self.popover.performClose(nil)
                ITerm2Focuser.focusSession(session, in: self.sessionManager)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        popover.contentViewController = NSHostingController(rootView: view)
    }

    private func setupEventWatcher() {
        let eventsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SessionNoticer/events")

        BannerController.shared.sessionManager = sessionManager

        eventWatcher = EventWatcher(eventsDirectory: eventsDir)
        eventWatcher?.onEvent = { [weak self] event in
            guard let self else { return }
            let triggered = self.sessionManager.processEvent(event)
            self.updateIcon()
            if triggered {
                BannerController.shared.showBanner(for: self.sessionManager.sessions[event.sessionId])
            }
        }
        eventWatcher?.processExistingEvents()
        eventWatcher?.start()
    }

    private func scanExistingSessions() {
        let scanner = SessionScanner()
        for session in scanner.discoverSessions() {
            sessionManager.addDiscoveredSession(session)
        }
        updateIcon()
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let count = sessionManager.needsAttentionCount
        if count > 0 {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Needs attention")
            button.image?.isTemplate = false
            statusItem?.button?.title = " \(count)"
        } else {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.image?.isTemplate = true
            statusItem?.button?.title = ""
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
