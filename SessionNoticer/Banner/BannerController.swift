import SwiftUI
import AppKit

class BannerController {
    static let shared = BannerController()

    weak var sessionManager: SessionManager?

    private var bannerWindow: NSWindow?
    private var hideTimer: Timer?
    private var queue: [Session] = []
    private var isShowing = false

    func showBanner(for session: Session?) {
        guard let session else { return }
        if isShowing {
            queue.append(session)
            return
        }
        displayBanner(for: session)
    }

    private func displayBanner(for session: Session) {
        isShowing = true
        guard let screen = NSScreen.main else { return }
        let bannerWidth: CGFloat = 320
        let bannerHeight: CGFloat = 56
        let menuBarHeight: CGFloat = NSStatusBar.system.thickness
        let x = (screen.frame.width - bannerWidth) / 2
        let y = screen.frame.height - menuBarHeight - bannerHeight - 4

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false

        let bannerView = BannerView(
            projectName: session.projectName,
            message: "Needs permission",
            onTap: { [weak self] in
                ITerm2Focuser.focusSession(session, in: self?.sessionManager)
                self?.hideBanner()
            }
        )
        window.contentViewController = NSHostingController(rootView: bannerView)

        window.alphaValue = 0
        window.setFrame(NSRect(x: x, y: y + 20, width: bannerWidth, height: bannerHeight), display: false)
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(NSRect(x: x, y: y, width: bannerWidth, height: bannerHeight), display: true)
        }

        bannerWindow = window
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.hideBanner()
        }
    }

    private func hideBanner() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let window = bannerWindow else {
            isShowing = false
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.bannerWindow = nil
            self?.isShowing = false
            if let next = self?.queue.first {
                self?.queue.removeFirst()
                self?.displayBanner(for: next)
            }
        })
    }
}

struct BannerView: View {
    let projectName: String
    let message: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Click to focus")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
