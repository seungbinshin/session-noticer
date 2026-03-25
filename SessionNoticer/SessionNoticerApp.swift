import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.sessionnoticer", category: "app")

@main
struct SessionNoticerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let sessionManager = SessionManager()
    private var eventWatcher: EventWatcher?
    private var httpListener: HTTPEventListener?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.sessionnoticer"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        if running.count > 1 {
            if let other = running.first(where: { $0 != NSRunningApplication.current }) {
                other.activate()
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()

        if !UserDefaults.standard.bool(forKey: "hooksInstalled") {
            do {
                let installer = HookInstaller()
                try installer.installHooks()
                try installer.installHookScriptFromKnownLocations()
                UserDefaults.standard.set(true, forKey: "hooksInstalled")
                logger.info("Hooks installed successfully")
            } catch {
                logger.error("Failed to install hooks: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "Setup Failed"
                alert.informativeText = "Could not install Claude Code hooks: \(error.localizedDescription)"
                alert.runModal()
            }
        }

        let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [checkOptPrompt: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            logger.warning("Accessibility permission not granted yet")
        }

        setupEventWatcher()
        setupHTTPListener()
        scanExistingSessions()
        sessionManager.startStaleSessionCleanup()

        sessionManager.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
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
        // Use .semitransient so clicks inside the popover work reliably
        // (.transient can dismiss the popover before button actions fire)
        popover.behavior = .semitransient
        popover.animates = true
        let view = MenuBarView(
            sessionManager: sessionManager,
            onSessionTap: { [weak self] session in
                guard let self else { return }
                logger.info("Session tapped: \(session.projectName) (PID: \(session.pid))")
                // Close popover AFTER scheduling the focus (async to avoid race)
                let sessionCopy = session
                DispatchQueue.main.async {
                    self.popover.performClose(nil)
                    ITerm2Focuser.focusSession(sessionCopy, in: self.sessionManager)
                }
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
            logger.debug("Event received: \(event.event.rawValue) for session \(event.sessionId)")
            let triggered = self.sessionManager.processEvent(event)
            self.updateIcon()
            if triggered {
                let session = self.sessionManager.sessions[event.sessionId]
                BannerController.shared.showBanner(for: session)
            }
        }
        eventWatcher?.processExistingEvents()
        eventWatcher?.start()
    }

    private func setupHTTPListener() {
        httpListener = HTTPEventListener(port: 9999)
        httpListener?.onEvent = { [weak self] event in
            guard let self else { return }
            logger.debug("Remote event: \(event.event.rawValue) for \(event.sessionId)")
            let triggered = self.sessionManager.processEvent(event)
            self.updateIcon()
            if triggered {
                let session = self.sessionManager.sessions[event.sessionId]
                BannerController.shared.showBanner(for: session)
            }
        }
        httpListener?.start()
    }

    private func scanExistingSessions() {
        let scanner = SessionScanner()
        let sessions = scanner.discoverSessions()
        logger.info("Discovered \(sessions.count) existing sessions")
        for session in sessions {
            sessionManager.addDiscoveredSession(session)
        }
        updateIcon()
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let permCount = sessionManager.needsAttentionCount

        if permCount > 0 {
            // Orange: sessions need permission (urgent)
            let image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "Needs permission")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = image.withSymbolConfiguration(config)
            button.title = " \(permCount)"
        } else if sessionManager.sessions.isEmpty {
            // Gray: no sessions
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.image?.isTemplate = true
            button.title = ""
        } else {
            // Green: sessions active, no action needed
            let image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "Sessions active")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
            button.image = image.withSymbolConfiguration(config)
            button.title = ""
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
