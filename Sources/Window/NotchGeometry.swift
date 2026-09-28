import AppKit

/// Where the notch is and how big each visual state of the black shape should be.
///
/// All `NSRect`s are in global screen coordinates. AppKit's origin is the
/// bottom-left of the primary display with y growing *upwards*, so "top of the
/// screen" is `frame.maxY`, not 0 as on the web.
struct NotchGeometry: Equatable {
    enum State: Equatable {
        case idle                   // nothing playing: exactly the notch, so it's invisible
        case collapsed              // notch + wings (artwork, equalizer) + title strip below
        case expanded(QueueLayout)  // hovered: the full player, plus the queue section
    }

    /// What the queue section at the bottom of the expanded player shows.
    enum QueueLayout: Equatable {
        case none    // no track, so no queue
        case prompt  // one line: "Connect Spotify…" or setup hint
        case list    // "Up next" header + rows
    }

    /// Rows visible at once; the queue scrolls when longer.
    static let queueRows = 4
    static let queueRowHeight: CGFloat = 36

    /// True on a MacBook with a camera housing. False → floating pill fallback.
    var hasNotch: Bool
    /// The physical notch, or the pill's resting size on screens without one.
    var notchSize: CGSize
    /// Horizontal center of the notch/pill, in screen coordinates.
    var centerX: CGFloat
    /// Y where the top edge of the shape sits, in screen coordinates.
    var topY: CGFloat

    // MARK: Detection

    static func current() -> NotchGeometry {
        // Prefer the built-in display when it has a notch, even if it isn't the
        // primary display. A notched screen reports a top safe-area inset (the
        // menu bar height beside the camera) plus the two usable areas either side.
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - left.width - right.width
            return NotchGeometry(
                hasNotch: true,
                notchSize: CGSize(width: notchWidth, height: screen.safeAreaInsets.top),
                centerX: screen.frame.minX + left.width + notchWidth / 2,
                topY: screen.frame.maxY
            )
        }

        // No notch (external display, lid closed, older Mac): float a pill just
        // below the menu bar of the primary display. `screens.first` is always the
        // one with the menu bar; `NSScreen.main` is whichever screen has key focus.
        guard let screen = NSScreen.screens.first else {
            return NotchGeometry(hasNotch: false, notchSize: CGSize(width: 160, height: 28), centerX: 0, topY: 0)
        }
        return NotchGeometry(
            hasNotch: false,
            // Wider than a real notch: without one, the title goes in the middle.
            notchSize: CGSize(width: 160, height: 28),
            centerX: screen.frame.midX,
            topY: screen.visibleFrame.maxY - 6
        )
    }

    // MARK: Sizes

    /// Width added on each side of the notch in the collapsed state.
    var wingWidth: CGFloat { notchSize.height + 10 }

    /// Vertical space at the top of the expanded shape that is hidden behind the
    /// physical notch, so content must start below it.
    var contentTopInset: CGFloat { hasNotch ? notchSize.height : 0 }

    /// Height of the "Title — Artist" strip under the notch when collapsed. Without
    /// a notch the title fits in the middle of the pill instead, so there's no strip.
    var titleStripHeight: CGFloat { hasNotch ? 22 : 0 }

    /// Height of the player part of the expanded view (below the notch inset).
    static let playerHeight: CGFloat = 150

    func queueHeight(_ layout: QueueLayout) -> CGFloat {
        switch layout {
        case .none: return 0
        case .prompt: return 44
        case .list: return 26 + CGFloat(Self.queueRows) * Self.queueRowHeight + 10
        }
    }

    func shapeSize(_ state: State) -> CGSize {
        switch state {
        case .idle:
            return notchSize
        case .collapsed:
            return CGSize(width: notchSize.width + wingWidth * 2, height: notchSize.height + titleStripHeight)
        case .expanded(let queue):
            let collapsedWidth = notchSize.width + wingWidth * 2
            return CGSize(width: max(collapsedWidth + 40, 380),
                          height: contentTopInset + Self.playerHeight + queueHeight(queue))
        }
    }

    /// (top, bottom) corner radii. With a notch the top edge is flush with the
    /// screen edge so only the bottom is rounded; the fallback pill is rounded all round.
    func cornerRadii(_ state: State) -> (top: CGFloat, bottom: CGFloat) {
        let bottom: CGFloat
        switch state {
        case .idle: bottom = hasNotch ? 10 : notchSize.height / 2
        case .collapsed: bottom = hasNotch ? 14 : notchSize.height / 2
        case .expanded: bottom = 28
        }
        return (hasNotch ? 0 : bottom, bottom)
    }

    /// The shape's rect on screen. Used for hover hit-testing.
    func shapeFrame(_ state: State) -> NSRect {
        let size = shapeSize(state)
        return NSRect(x: centerX - size.width / 2, y: topY - size.height, width: size.width, height: size.height)
    }

    /// The panel is always sized for the expanded state (plus slack so the spring's
    /// overshoot isn't clipped). The shape animates inside it; the panel never moves.
    var panelFrame: NSRect {
        let expanded = shapeSize(.expanded(.list))   // the largest state
        let size = CGSize(width: expanded.width + 40, height: expanded.height + 24)
        return NSRect(x: centerX - size.width / 2, y: topY - size.height, width: size.width, height: size.height)
    }
}
