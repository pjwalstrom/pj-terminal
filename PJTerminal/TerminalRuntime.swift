import AppKit
import GhosttyKit

/// Minimal wrapper around libghostty runtime: creates and ticks the Ghostty app.
@MainActor
final class TerminalRuntime: ObservableObject {
    static let shared = TerminalRuntime()

    private let config: ghostty_config_t?
    private(set) var app: ghostty_app_t?
    private var tickTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        // Prepare configuration with defaults.
        self.config = ghostty_config_new()
        guard let config else { return }

        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        // Build runtime callbacks.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in TerminalRuntime.wakeup(userdata) },
            action_cb: { _, _, _ in true },
            read_clipboard_cb: { _, _, _ in },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
        )

        self.app = ghostty_app_new(&runtime, config)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        startTickLoop()
        NSApp.activate(ignoringOtherApps: true)
        observeAppFocus()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        tickTimer?.invalidate()
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    // MARK: - Callbacks

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<TerminalRuntime>.fromOpaque(userdata).takeUnretainedValue()
        runtime.tick()
    }

    // MARK: - Ticking

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func startTickLoop() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func observeAppFocus() {
        let center = NotificationCenter.default
        let become = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }
        let resign = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }
        notificationTokens.append(contentsOf: [become, resign])
    }
}
