import AppKit

final class FocusOverlayController {
    private var panel: FocusOverlayPanel?

    func show(image: NSImage, aspectRatio: CGFloat, preferredScreenFrame: NSRect?) {
        let overlayFrame = Self.allScreensFrame()
        let screenFrame = preferredScreenFrame ?? NSScreen.main?.frame ?? overlayFrame

        if panel == nil {
            panel = FocusOverlayPanel(frame: overlayFrame)
        }

        panel?.setFrame(overlayFrame, display: false)
        panel?.configure(image: image, aspectRatio: aspectRatio, screenFrame: screenFrame)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func allScreensFrame() -> NSRect {
        guard let firstScreen = NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }

        return NSScreen.screens.dropFirst().reduce(firstScreen.frame) { partialResult, screen in
            partialResult.union(screen.frame)
        }
    }
}

private final class FocusOverlayPanel: NSPanel {
    private let overlayView = FocusOverlayView()

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Public-API visual focus only: this panel covers the desktop and draws
        // the selected window snapshot instead of actually hiding other apps.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func configure(image: NSImage, aspectRatio: CGFloat, screenFrame: NSRect) {
        overlayView.configure(
            image: image,
            aspectRatio: aspectRatio,
            screenFrame: screenFrame,
            overlayFrame: frame
        )
    }
}

private final class FocusOverlayView: NSView {
    private var image: NSImage?
    private var focusRect: NSRect = .zero

    override var isFlipped: Bool { false }

    func configure(image: NSImage, aspectRatio: CGFloat, screenFrame: NSRect, overlayFrame: NSRect) {
        self.image = image

        let localScreenFrame = screenFrame.offsetBy(dx: -overlayFrame.minX, dy: -overlayFrame.minY)
        let horizontalInset = min(max(48, localScreenFrame.width * 0.12), localScreenFrame.width * 0.20)
        let verticalInset = min(max(48, localScreenFrame.height * 0.12), localScreenFrame.height * 0.20)
        let availableRect = localScreenFrame.insetBy(dx: horizontalInset, dy: verticalInset)

        focusRect = Self.aspectFitRect(aspectRatio: aspectRatio, in: availableRect)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.015, alpha: 0.76).setFill()
        bounds.fill()

        guard let image, !focusRect.isEmpty else { return }

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.45)

        let roundedRect = NSBezierPath(roundedRect: focusRect, xRadius: 12, yRadius: 12)

        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(calibratedWhite: 0.02, alpha: 0.88).setFill()
        roundedRect.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        roundedRect.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: focusRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
        let border = NSBezierPath(roundedRect: focusRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 1
        border.stroke()
    }

    private static func aspectFitRect(aspectRatio: CGFloat, in rect: NSRect) -> NSRect {
        let ratio = max(0.2, min(aspectRatio, 5))
        var width = rect.width
        var height = width / ratio

        if height > rect.height {
            height = rect.height
            width = height * ratio
        }

        return NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }
}
