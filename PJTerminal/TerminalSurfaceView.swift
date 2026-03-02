import AppKit
import SwiftUI
import GhosttyKit

/// SwiftUI representable that embeds the Ghostty terminal surface.
struct TerminalSurfaceRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalSurfaceView {
        TerminalSurfaceView(runtime: .shared)
    }

    func updateNSView(_ nsView: TerminalSurfaceView, context: Context) {}
}

/// NSView that hosts a Ghostty surface and forwards keyboard/mouse input.
final class TerminalSurfaceView: NSView {
    private let runtime: TerminalRuntime
    private var surface: ghostty_surface_t?
    private var renderTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var keyMonitor: Any?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createSurfaceIfNeeded()
        bringToFrontAndFocus()
        installKeyMonitor()
        startRenderLoop()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        createSurfaceIfNeeded()
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        setSurfaceFocus(true)
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        setSurfaceFocus(false)
        return ok
    }

    private func setSurfaceFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func updateLayer() {
        super.updateLayer()
        updateSurfaceSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
        let w = UInt32(bounds.width * scale)
        let h = UInt32(bounds.height * scale)
        ghostty_surface_set_size(surface, w, h)
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
    }

    // MARK: - Rendering

    private func startRenderLoop() {
        renderTimer?.invalidate()
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_draw(surface)
        }
    }

    // MARK: - Surface creation

    private func createSurfaceIfNeeded() {
        guard surface == nil, let app = runtime.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()
        ))
        cfg.scale_factor = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
        cfg.font_size = 0
        cfg.wait_after_command = false

        self.surface = ghostty_surface_new(app, &cfg)
        updateSurfaceSize()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        let mods = modsFromFlags(event.modifierFlags)

        // Determine which modifier key changed
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        let action: ghostty_input_action_e = (mods.rawValue & mod != 0)
            ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = mods
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = false
        ghostty_surface_key(surface, keyEvent)
    }

    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = modsFromFlags(event.modifierFlags)
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.composing = false

        if let text = translatedText(from: event), !text.isEmpty {
            text.withCString { buffer in
                keyEvent.text = buffer
                ghostty_surface_key(surface, keyEvent)
            }
        } else {
            ghostty_surface_key(surface, keyEvent)
        }
    }

    private func translatedText(from event: NSEvent) -> String? {
        event.characters
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = ghostty_input_mods_e(0)
        if flags.contains(.shift) { mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods = ghostty_input_mods_e(mods.rawValue | GHOSTTY_MODS_CAPS.rawValue) }
        return mods
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        bringToFrontAndFocus()
        setSurfaceFocus(true)
        sendMouse(event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouse(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseDragged(with event: NSEvent) { sendMouseMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouseMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouseMove(event) }
    override func mouseMoved(with event: NSEvent) { sendMouseMove(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let mods = modsFromFlags(event.modifierFlags)
        ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY,
            ghostty_input_scroll_mods_t(mods.rawValue)
        )
    }

    private func sendMouse(_ event: NSEvent, state: ghostty_input_mouse_state_e) {
        guard let surface else { return }
        let mods = modsFromFlags(event.modifierFlags)
        let button = mouseButton(from: event)
        ghostty_surface_mouse_button(surface, state, button, mods)
        sendMouseMove(event)
    }

    private func sendMouseMove(_ event: NSEvent) {
        guard let surface else { return }
        let location = convert(event.locationInWindow, from: nil)
        let mods = modsFromFlags(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, location.x, bounds.height - location.y, mods)
    }

    private func mouseButton(from event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    // MARK: - Helpers

    private func bringToFrontAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.acceptsMouseMovedEvents = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                self.sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
                return nil
            case .keyUp:
                self.sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
                return nil
            default:
                return event
            }
        }
    }
}
