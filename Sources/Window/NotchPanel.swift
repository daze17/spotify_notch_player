import AppKit
import Combine
import SwiftUI

/// A borderless, transparent panel that floats over the notch.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        // .nonactivatingPanel: clicking the panel doesn't make NotchPlayer the
        // active app, so the app you're typing in keeps focus.
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        // .statusBar is one level above .mainMenu, so we draw over the menu bar
        // strip beside the notch instead of underneath it.
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        // Panels hide by default when their app deactivates. An accessory app is
        // effectively never active, so turn that off or we'd vanish immediately.
        hidesOnDeactivate = false
        // Show on every Space and over full-screen apps, stay put during Mission
        // Control, and leave Cmd-` window cycling alone.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Start click-through; NotchPanelController turns clicks on while hovering.
        ignoresMouseEvents = true
        animationBehavior = .none
        // Always dark: the panel is black regardless of the system appearance, so
        // scrollers and context menus must use their light-on-dark variants.
        appearance = NSAppearance(named: .darkAqua)
    }

    // Never take keyboard focus away from the user's frontmost window.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // AppKit nudges windows so they don't overlap the menu bar. We *want* to sit
    // over it, so accept whatever frame we're given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view for the panel's SwiftUI content.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// Called for mouse movement over the panel while it accepts mouse events.
    var onMouseMoved: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    // The panel is never key, so without this the first click on a button would
    // only "focus" the window and be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit only sends plain mouseMoved events to the key window, and ours never
    // is. A tracking area with .activeAlways reports movement over this view no
    // matter which app is frontmost.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseMoved?()
    }
}

/// Owns the panel, keeps it over the notch, and drives hover expand/collapse.
///
/// Click-through: the panel covers the whole expanded area, but most of it is
/// transparent. A hit-test override in the view wouldn't help because the window
/// would still swallow the click. So the panel ignores mouse events by default,
/// and we watch the global cursor position and only accept events while the
/// cursor is inside the visible black shape.
@MainActor
final class NotchPanelController {
    private let panel: NotchPanel
    private let model: NotchViewModel
    private var eventMonitors: [Any] = []
    private var collapseTask: Task<Void, Never>?
    private let spotify: SpotifyController
    private let queue: QueueController
    private var cancellables = Set<AnyCancellable>()

    init(spotify: SpotifyController, queue: QueueController) {
        self.spotify = spotify
        self.queue = queue
        let geometry = NotchGeometry.current()
        model = NotchViewModel(geometry: geometry)
        panel = NotchPanel(contentRect: geometry.panelFrame)

        // Poll the playback position and queue only while the expanded player is on screen.
        model.$isExpanded
            .sink { [weak spotify, weak queue] expanded in
                spotify?.isExpandedVisible = expanded
                queue?.isVisible = expanded
            }
            .store(in: &cancellables)

        let hostingView = NotchHostingView(rootView: NotchView(model: model, spotify: spotify, queue: queue))
        // By default NSHostingView resizes its window to fit the SwiftUI content.
        // The panel's size is fixed by NotchGeometry, so opt out.
        hostingView.sizingOptions = []
        hostingView.onMouseMoved = { [weak self] in self?.updateHover() }
        panel.contentView = hostingView

        // orderFrontRegardless shows the window without activating our app
        // (plain orderFront is ignored for inactive apps).
        panel.orderFrontRegardless()
        installMouseMonitors()

        // Fires on display plug/unplug, resolution or arrangement changes, and
        // lid open/close. The notch might now be on another screen, or gone.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.relayout() } }
            .store(in: &cancellables)
    }

    private func relayout() {
        let geometry = NotchGeometry.current()
        guard geometry != model.geometry else { return }
        model.isExpanded = false
        model.geometry = geometry
        panel.setFrame(geometry.panelFrame, display: true)
        updateHover()
    }

    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .rightMouseDown,
        ]
        // Global monitors see events headed to *other* apps: every move while our
        // panel is click-through, and every click outside it (which closes the
        // expanded player). Mouse events don't need Accessibility permission (only
        // key events do). The handler isn't guaranteed to run on the main actor,
        // so hop there explicitly.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            Task { @MainActor in
                if isClick { self?.clickedOutside() } else { self?.updateHover() }
            }
        }) {
            eventMonitors.append(global)
        }
        // Local monitors see events delivered to our own app (panel under the cursor).
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged],
                                                        handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) {
            eventMonitors.append(local)
        }
    }

    private var currentState: NotchGeometry.State {
        .current(isExpanded: model.isExpanded, spotify: spotify, queue: queue)
    }

    /// The visible shape on screen. Inflated a little: at the very top edge the
    /// cursor's y can equal maxY, which NSRect.contains treats as outside.
    private var hotZone: NSRect {
        model.geometry.shapeFrame(currentState).insetBy(dx: -2, dy: -2)
    }

    // MARK: Interaction
    //
    //   pointer enters shape → expand
    //   pointer leaves       → collapse after 300 ms (moving back in cancels)
    //   click elsewhere      → collapse immediately

    /// Called on every mouse move; decides click-through, expanding and the leave timer.
    private func updateHover() {
        // NSEvent.mouseLocation is in global screen coordinates, same as NotchGeometry.
        let inside = hotZone.contains(NSEvent.mouseLocation)

        // Mid-drag (e.g. scrubbing past the edge of the shape), keep the panel as
        // it is until the button is released; the next mouse move re-evaluates.
        let isDragging = NSEvent.pressedMouseButtons & 1 != 0
        if !inside, isDragging, !panel.ignoresMouseEvents { return }

        // Accept clicks only over the visible shape; everywhere else passes through.
        panel.ignoresMouseEvents = !inside

        if inside {
            cancelScheduledCollapse()
            if !model.isExpanded { model.isExpanded = true }
        } else if model.isExpanded, collapseTask == nil {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.collapse()
            }
        }
    }

    /// A click went to another app. Our panel is click-through outside the shape,
    /// so that includes clicks on the transparent parts of our own window.
    private func clickedOutside() {
        guard model.isExpanded, !hotZone.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    private func collapse() {
        cancelScheduledCollapse()
        model.isExpanded = false
    }

    private func cancelScheduledCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }
}
