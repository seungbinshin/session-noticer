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
            } catch {
                NSLog("SessionNoticer: Failed to install hooks: \(error)")
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
            NSLog("SessionNoticer: Accessibility permission not granted yet")
        }

        setupEventWatcher()
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
        let permCount = sessionManager.sessions.values.filter { $0.state == .needsPermission }.count
        let awaitCount = sessionManager.sessions.values.filter { $0.state == .awaitingResponse }.count
        let attentionCount = permCount + awaitCount

        if permCount > 0 {
            // Orange: at least one session needs permission (most urgent)
            let image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "Needs permission")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            button.image = image.withSymbolConfiguration(config)
            button.title = " \(attentionCount)"
        } else if awaitCount > 0 {
            // Yellow: sessions awaiting user response
            let image = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "Awaiting response")!
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
            button.image = image.withSymbolConfiguration(config)
            button.title = " \(awaitCount)"
        } else if sessionManager.sessions.isEmpty {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Session Noticer")
            button.image?.isTemplate = true
            button.title = ""
        } else {
            // Green: sessions running or completed, no action needed
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
