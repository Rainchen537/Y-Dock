import AppKit
import Foundation
import QuartzCore

private enum PreviewPanelLayout {
    static let panelInset: CGFloat = 5
    static let rowSpacing: CGFloat = 5
    static let cardSpacing: CGFloat = 5
    static let cardInset: CGFloat = 4
    static let titleImageSpacing: CGFloat = 2
    static let titleRowHeight: CGFloat = 24
    static let titleBandHeight: CGFloat = titleRowHeight + titleImageSpacing
    static let titleFontSize: CGFloat = 13.4
    static let titleIconSize: CGFloat = 20
    static let controlButtonSize: CGFloat = 16.5
    static let controlSpacing: CGFloat = 6.5
    static let controlLeading: CGFloat = 8
    static var controlTop: CGFloat { cardInset + (titleRowHeight - controlButtonSize) / 2 }
    static let controlMaskWidth: CGFloat = 90
    static var controlMaskHeight: CGFloat { cardInset + titleRowHeight }
    static let dockBridgeInset: CGFloat = 18
    static let focusPreviewDelay: TimeInterval = 0.05
}

final class PreviewPanel: NSPanel {
    var onSelectWindow: ((WindowInfo) -> Void)?
    var onCloseWindow: ((WindowInfo) -> Void)?
    var onMinimizeWindow: ((WindowInfo) -> Void)?
    var onQuitApplication: ((WindowInfo) -> Void)?

    private let thumbnailProvider: WindowThumbnailProvider
    private let settings: AppSettings
    private let rootView = PreviewRootView()
    private let stackView = NSStackView()
    private let focusOverlay = FocusOverlayController()

    private struct PreviewItem {
        let window: WindowInfo
        let thumbnail: NSImage
        let thumbnailSize: NSSize
    }

    private var currentWindows: [WindowInfo] = []
    private var currentApp: NSRunningApplication?
    private var currentAnchor: NSPoint?
    private var currentDockEdge: DockEdge?

    init(thumbnailProvider: WindowThumbnailProvider, settings: AppSettings = .shared) {
        self.thumbnailProvider = thumbnailProvider
        self.settings = settings

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // The Dock tooltip is owned by Dock.app and cannot be disabled through
        // public APIs. Keep the preview panel close to the Dock, but render it
        // above system tooltip-style windows instead of artificially lifting it.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        setupContent()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(windows: [WindowInfo], app: NSRunningApplication, anchor: NSPoint, dockEdge: DockEdge?) {
        guard !windows.isEmpty else {
            hide()
            return
        }

        currentWindows = windows
        currentApp = app
        currentAnchor = anchor
        currentDockEdge = dockEdge

        let items = makePreviewItems(for: windows)
        rebuildContent(items: items, app: app)

        let targetSize = preferredPanelSize(for: items)
        setFrame(NSRect(origin: frame.origin, size: targetSize), display: false)
        contentView?.layoutSubtreeIfNeeded()

        let targetFrame = positionedFrame(size: targetSize, anchor: anchor, dockEdge: dockEdge)
        setFrame(targetFrame, display: true)
        orderFrontRegardless()
    }

    func hide() {
        focusOverlay.hide()
        orderOut(nil)
        currentWindows = []
        currentApp = nil
        currentAnchor = nil
        currentDockEdge = nil
    }

    func removeWindow(_ windowID: CGWindowID) {
        focusOverlay.hide()
        let previousCount = currentWindows.count
        currentWindows.removeAll { $0.windowID == windowID }
        guard currentWindows.count != previousCount else { return }

        guard
            !currentWindows.isEmpty,
            let app = currentApp,
            let anchor = currentAnchor
        else {
            hide()
            return
        }

        show(windows: currentWindows, app: app, anchor: anchor, dockEdge: currentDockEdge)
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard isVisible else { return false }

        if frame.insetBy(dx: -10, dy: -10).contains(point) {
            return true
        }

        guard let anchor = currentAnchor, let dockEdge = currentDockEdge else {
            return false
        }

        return bridgeFrame(from: anchor, dockEdge: dockEdge).contains(point)
    }

    private func setupContent() {
        rootView.material = .hudWindow
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 14
        rootView.layer?.masksToBounds = true
        contentView = rootView

        stackView.orientation = .vertical
        stackView.spacing = PreviewPanelLayout.rowSpacing
        stackView.edgeInsets = NSEdgeInsets(
            top: PreviewPanelLayout.panelInset,
            left: PreviewPanelLayout.panelInset,
            bottom: PreviewPanelLayout.panelInset,
            right: PreviewPanelLayout.panelInset
        )
        stackView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: rootView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
    }

    private func makePreviewItems(for windows: [WindowInfo]) -> [PreviewItem] {
        windows.map { window in
            let size = settings.thumbnailSize(for: window)
            let thumbnail = thumbnailProvider.thumbnail(for: window, targetSize: size)
            return PreviewItem(window: window, thumbnail: thumbnail, thumbnailSize: size)
        }
    }

    private func rebuildContent(items: [PreviewItem], app: NSRunningApplication) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let rows = makeRows(for: items, appIcon: app.icon)
        for row in rows {
            stackView.addArrangedSubview(row)
        }
    }

    private func makeRows(for items: [PreviewItem], appIcon: NSImage?) -> [WindowPreviewRowView] {
        let groups = rowGroups(for: items)
        var rows: [WindowPreviewRowView] = []

        for group in groups {
            let row = WindowPreviewRowView()
            row.orientation = .horizontal
            row.spacing = PreviewPanelLayout.cardSpacing
            row.alignment = .top
            row.distribution = .fill
            row.onFocusPreview = { [weak self] selectedWindow in
                self?.showFocusOverlay(for: selectedWindow)
            }
            row.onFocusPreviewEnded = { [weak self] in
                self?.focusOverlay.hide()
            }

            for item in group {
                let card = WindowPreviewCardView(
                    window: item.window,
                    appIcon: appIcon,
                    thumbnail: item.thumbnail,
                    thumbnailSize: item.thumbnailSize,
                    settings: settings
                )
                card.onClick = { [weak self] selectedWindow in
                    self?.onSelectWindow?(selectedWindow)
                }
                card.onClose = { [weak self] selectedWindow in
                    self?.onCloseWindow?(selectedWindow)
                }
                card.onMinimize = { [weak self] selectedWindow in
                    self?.onMinimizeWindow?(selectedWindow)
                }
                card.onQuitApplication = { [weak self] selectedWindow in
                    self?.onQuitApplication?(selectedWindow)
                }
                row.addArrangedSubview(card)
            }

            rows.append(row)
        }

        return rows
    }

    private func rowGroups(for items: [PreviewItem]) -> [[PreviewItem]] {
        let availableWidth = (NSScreen.main?.visibleFrame.width ?? 1440) - 32
        let maxContentWidth = max(280, availableWidth - 16)
        let spacing = PreviewPanelLayout.cardSpacing
        var groups: [[PreviewItem]] = []
        var currentGroup: [PreviewItem] = []
        var currentWidth: CGFloat = 0

        for item in items {
            let itemWidth = cardSize(for: item).width
            let nextWidth = currentGroup.isEmpty ? itemWidth : currentWidth + spacing + itemWidth
            if !currentGroup.isEmpty, (currentGroup.count >= 4 || nextWidth > maxContentWidth) {
                groups.append(currentGroup)
                currentGroup = [item]
                currentWidth = itemWidth
            } else {
                currentGroup.append(item)
                currentWidth = nextWidth
            }
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }

        return groups
    }

    private func preferredPanelSize(for items: [PreviewItem]) -> NSSize {
        let groups = rowGroups(for: items)
        let spacing = PreviewPanelLayout.rowSpacing
        let rowWidths = groups.map { group in
            group.reduce(CGFloat(0)) { $0 + cardSize(for: $1).width } + CGFloat(max(group.count - 1, 0)) * PreviewPanelLayout.cardSpacing
        }
        let rowHeights = groups.map { group in
            group.map { cardSize(for: $0).height }.max() ?? 0
        }
        let width = (rowWidths.max() ?? 0) + PreviewPanelLayout.panelInset * 2
        let height = rowHeights.reduce(CGFloat(0), +) + CGFloat(max(groups.count - 1, 0)) * spacing + PreviewPanelLayout.panelInset * 2

        guard let screen = NSScreen.main else {
            return NSSize(width: width, height: height)
        }

        return NSSize(
            width: min(width, screen.visibleFrame.width - 32),
            height: min(height, screen.visibleFrame.height - 32)
        )
    }

    private func cardSize(for item: PreviewItem) -> NSSize {
        let titleHeight: CGFloat = settings.showWindowTitles ? PreviewPanelLayout.titleBandHeight : 0
        return NSSize(
            width: item.thumbnailSize.width + PreviewPanelLayout.cardInset * 2,
            height: item.thumbnailSize.height + titleHeight + PreviewPanelLayout.cardInset * 2
        )
    }

    private func showFocusOverlay(for window: WindowInfo) {
        let targetSize = NSSize(
            width: max(80, window.bounds.width),
            height: max(60, window.bounds.height)
        )

        guard let image = thumbnailProvider.focusImage(for: window, targetSize: targetSize) else {
            focusOverlay.hide()
            return
        }

        focusOverlay.show(image: image, windowBounds: window.bounds)
        orderFrontRegardless()
    }

    private func positionedFrame(size: NSSize, anchor: NSPoint, dockEdge: DockEdge?) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = screen?.frame ?? visibleFrame
        let padding: CGFloat = 10

        var origin: NSPoint
        switch dockEdge {
        case .bottom:
            let dockTopY = visibleFrame.minY > screenFrame.minY + 20 ? visibleFrame.minY : anchor.y + 28
            let y = dockTopY + 6
            origin = NSPoint(x: anchor.x - size.width / 2, y: y)
        case .left:
            let dockRightX = visibleFrame.minX > screenFrame.minX + 20 ? visibleFrame.minX : anchor.x + 28
            let x = dockRightX + 6
            origin = NSPoint(x: x, y: anchor.y - size.height / 2)
        case .right:
            let dockLeftX = visibleFrame.maxX < screenFrame.maxX - 20 ? visibleFrame.maxX : anchor.x - 28
            let x = dockLeftX - size.width - 6
            origin = NSPoint(x: x, y: anchor.y - size.height / 2)
        case nil:
            origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 24)
        }

        origin.x = min(max(origin.x, visibleFrame.minX + padding), visibleFrame.maxX - size.width - padding)
        origin.y = min(max(origin.y, visibleFrame.minY + padding), visibleFrame.maxY - size.height - padding)

        return NSRect(origin: origin, size: size)
    }

    private func bridgeFrame(from anchor: NSPoint, dockEdge: DockEdge) -> NSRect {
        let inset = PreviewPanelLayout.dockBridgeInset

        switch dockEdge {
        case .bottom:
            let minY = min(anchor.y, frame.minY) - inset
            let maxY = max(anchor.y, frame.minY) + inset
            return NSRect(
                x: frame.minX - inset,
                y: minY,
                width: frame.width + inset * 2,
                height: max(1, maxY - minY)
            )
        case .left:
            let minX = min(anchor.x, frame.minX) - inset
            let maxX = max(anchor.x, frame.minX) + inset
            return NSRect(
                x: minX,
                y: frame.minY - inset,
                width: max(1, maxX - minX),
                height: frame.height + inset * 2
            )
        case .right:
            let minX = min(anchor.x, frame.maxX) - inset
            let maxX = max(anchor.x, frame.maxX) + inset
            return NSRect(
                x: minX,
                y: frame.minY - inset,
                width: max(1, maxX - minX),
                height: frame.height + inset * 2
            )
        }
    }
}

private final class WindowPreviewRowView: NSStackView {
    var onFocusPreview: ((WindowInfo) -> Void)?
    var onFocusPreviewEnded: (() -> Void)?

    private var focusPreviewWorkItem: DispatchWorkItem?
    private var scheduledWindowID: CGWindowID?
    private var activeWindowID: CGWindowID?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateFocusPreview(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateFocusPreview(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        cancelFocusPreview(notifyEnd: true)
    }

    private func updateFocusPreview(at point: NSPoint) {
        guard let card = focusCard(at: point) else {
            cancelFocusPreview(notifyEnd: true)
            return
        }

        let windowID = card.previewWindow.windowID
        if activeWindowID == windowID {
            focusPreviewWorkItem?.cancel()
            focusPreviewWorkItem = nil
            scheduledWindowID = nil
            return
        }

        guard scheduledWindowID != windowID else { return }

        focusPreviewWorkItem?.cancel()
        scheduledWindowID = windowID

        let workItem = DispatchWorkItem { [weak self, weak card] in
            guard let self, let card else { return }
            self.activeWindowID = card.previewWindow.windowID
            self.scheduledWindowID = nil
            self.onFocusPreview?(card.previewWindow)
        }
        focusPreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + PreviewPanelLayout.focusPreviewDelay, execute: workItem)
    }

    private func cancelFocusPreview(notifyEnd: Bool) {
        focusPreviewWorkItem?.cancel()
        focusPreviewWorkItem = nil
        scheduledWindowID = nil
        activeWindowID = nil

        if notifyEnd {
            onFocusPreviewEnded?()
        }
    }

    private func focusCard(at point: NSPoint) -> WindowPreviewCardView? {
        let cards = arrangedSubviews.compactMap { $0 as? WindowPreviewCardView }
        guard !cards.isEmpty else { return nil }

        let rects = cards.map { card in
            (card: card, rect: card.previewImageRect(in: self))
        }

        let imageBand = rects.reduce(NSRect.null) { partialResult, item in
            partialResult.union(NSRect(
                x: item.rect.minX,
                y: item.rect.minY,
                width: item.rect.width,
                height: item.rect.height
            ))
        }

        guard imageBand.contains(point) else { return nil }

        for index in rects.indices {
            let current = rects[index]
            let minX: CGFloat
            let maxX: CGFloat

            if index == rects.startIndex {
                minX = current.rect.minX
            } else {
                let previous = rects[rects.index(before: index)].rect
                minX = (previous.maxX + current.rect.minX) / 2
            }

            if index == rects.index(before: rects.endIndex) {
                maxX = current.rect.maxX
            } else {
                let next = rects[rects.index(after: index)].rect
                maxX = (current.rect.maxX + next.minX) / 2
            }

            if point.x >= minX, point.x <= maxX {
                return current.card
            }
        }

        return nil
    }
}

private final class PreviewRootView: NSVisualEffectView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
}

private final class WindowPreviewCardView: NSView {
    var onClick: ((WindowInfo) -> Void)?
    var onClose: ((WindowInfo) -> Void)?
    var onMinimize: ((WindowInfo) -> Void)?
    var onQuitApplication: ((WindowInfo) -> Void)?

    private let windowInfo: WindowInfo
    private let iconView = NSImageView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let controlMaskView = PreviewTitleMaskView()
    private let controlStack = NSStackView()
    private lazy var quitButton = PreviewControlButton(kind: .quitApp, target: self, action: #selector(quitApplicationButtonClicked))
    private lazy var closeButton = PreviewControlButton(kind: .closeWindow, target: self, action: #selector(closeButtonClicked))
    private lazy var minimizeButton = PreviewControlButton(kind: .minimizeWindow, target: self, action: #selector(minimizeButtonClicked))
    private let thumbnailSize: NSSize
    private let settings: AppSettings

    init(window: WindowInfo, appIcon: NSImage?, thumbnail: NSImage, thumbnailSize: NSSize, settings: AppSettings) {
        self.windowInfo = window
        self.thumbnailSize = thumbnailSize
        self.settings = settings
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor

        setupViews(appIcon: appIcon, thumbnail: thumbnail)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        let titleHeight: CGFloat = settings.showWindowTitles ? PreviewPanelLayout.titleBandHeight : 0
        return NSSize(
            width: thumbnailSize.width + PreviewPanelLayout.cardInset * 2,
            height: thumbnailSize.height + titleHeight + PreviewPanelLayout.cardInset * 2
        )
    }

    var previewWindow: WindowInfo {
        windowInfo
    }

    func previewImageRect(in view: NSView) -> NSRect {
        imageView.convert(imageView.bounds, to: view)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.95, alpha: 0.26).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.45, green: 0.65, blue: 1, alpha: 0.70).cgColor
        setControlButtonsVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        setControlButtonsVisible(false)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(windowInfo)
    }

    private func setControlButtonsVisible(_ visible: Bool) {
        quitButton.isEnabled = visible
        closeButton.isEnabled = visible
        minimizeButton.isEnabled = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.07
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            controlStack.animator().alphaValue = visible ? 1 : 0
            controlMaskView.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func quitApplicationButtonClicked() {
        setControlButtonsVisible(false)
        onQuitApplication?(windowInfo)
    }

    @objc private func closeButtonClicked() {
        setControlButtonsVisible(false)
        onClose?(windowInfo)
    }

    @objc private func minimizeButtonClicked() {
        setControlButtonsVisible(false)
        onMinimize?(windowInfo)
    }

    private func setupViews(appIcon: NSImage?, thumbnail: NSImage) {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = PreviewPanelLayout.titleImageSpacing
        contentStack.edgeInsets = NSEdgeInsets(
            top: PreviewPanelLayout.cardInset,
            left: PreviewPanelLayout.cardInset,
            bottom: PreviewPanelLayout.cardInset,
            right: PreviewPanelLayout.cardInset
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if settings.showWindowTitles {
            let titleRow = NSStackView()
            titleRow.orientation = .horizontal
            titleRow.spacing = 5
            titleRow.alignment = .centerY
            titleRow.distribution = .fill
            titleRow.widthAnchor.constraint(equalToConstant: thumbnailSize.width).isActive = true
            titleRow.heightAnchor.constraint(equalToConstant: PreviewPanelLayout.titleRowHeight).isActive = true

            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.widthAnchor.constraint(equalToConstant: PreviewPanelLayout.titleIconSize).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: PreviewPanelLayout.titleIconSize).isActive = true

            titleLabel.stringValue = windowInfo.title
            titleLabel.font = NSFont.systemFont(ofSize: PreviewPanelLayout.titleFontSize, weight: .semibold)
            titleLabel.textColor = NSColor(calibratedWhite: 0.94, alpha: 1)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.maximumNumberOfLines = 1
            titleLabel.alignment = .left
            titleLabel.usesSingleLineMode = true
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            titleRow.addArrangedSubview(iconView)
            titleRow.addArrangedSubview(titleLabel)
            contentStack.addArrangedSubview(titleRow)
        }

        imageView.image = thumbnail
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.widthAnchor.constraint(equalToConstant: thumbnailSize.width).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: thumbnailSize.height).isActive = true
        contentStack.addArrangedSubview(imageView)

        controlMaskView.alphaValue = 0
        controlMaskView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlMaskView)

        controlStack.orientation = .horizontal
        controlStack.spacing = PreviewPanelLayout.controlSpacing
        controlStack.alignment = .centerY
        controlStack.alphaValue = 0
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.addArrangedSubview(quitButton)
        controlStack.addArrangedSubview(closeButton)
        controlStack.addArrangedSubview(minimizeButton)
        addSubview(controlStack)

        NSLayoutConstraint.activate([
            controlMaskView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            controlMaskView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            controlMaskView.widthAnchor.constraint(equalToConstant: PreviewPanelLayout.controlMaskWidth),
            controlMaskView.heightAnchor.constraint(equalToConstant: PreviewPanelLayout.controlMaskHeight),

            controlStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PreviewPanelLayout.controlLeading),
            controlStack.topAnchor.constraint(equalTo: topAnchor, constant: PreviewPanelLayout.controlTop)
        ])
        setControlButtonsVisible(false)
    }
}

private final class PreviewTitleMaskView: NSView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let leftColor = NSColor(calibratedWhite: 1, alpha: 0.30).cgColor
        let midColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor
        let rightColor = NSColor(calibratedWhite: 1, alpha: 0).cgColor
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [leftColor, midColor, rightColor] as CFArray,
            locations: [0, 0.66, 1]
        ) else { return }

        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.addPath(CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context?.clip()
        context?.drawLinearGradient(
            gradient,
            start: CGPoint(x: bounds.minX, y: bounds.midY),
            end: CGPoint(x: bounds.maxX, y: bounds.midY),
            options: []
        )
        context?.restoreGState()
    }
}

private final class PreviewControlButton: NSButton {
    enum Kind {
        case quitApp
        case closeWindow
        case minimizeWindow
    }

    private let kind: Kind
    private var isHovered = false

    init(kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        let size = PreviewPanelLayout.controlButtonSize
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        isEnabled = false
        wantsLayer = true
        toolTip = kind.toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: PreviewPanelLayout.controlButtonSize, height: PreviewPanelLayout.controlButtonSize)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        needsDisplay = true
        super.mouseDown(with: event)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 0.35, dy: 0.35)
        NSColor(calibratedWhite: 0, alpha: isHighlighted ? 0.26 : 0.14).setFill()
        NSBezierPath(ovalIn: circleRect.offsetBy(dx: 0, dy: -0.6)).fill()

        kind.fillColor.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

        if isHovered {
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: circleRect).fill()

            NSColor.white.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.55, dy: 0.55))
            ring.lineWidth = 1
            ring.stroke()
        }

        if isHighlighted {
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: circleRect).fill()
        }

        switch kind {
        case .quitApp:
            drawPowerSymbol(in: circleRect)
        case .closeWindow:
            drawCloseSymbol(in: circleRect)
        case .minimizeWindow:
            drawMinimizeSymbol(in: circleRect)
        }
    }

    private func drawPowerSymbol(in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.86).setStroke()

        let center = NSPoint(x: rect.midX, y: rect.midY - rect.height * 0.035)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: rect.width * 0.27, startAngle: 130, endAngle: 410)
        arc.lineWidth = max(1.1, rect.width * 0.085)
        arc.lineCapStyle = .round
        arc.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.08))
        line.line(to: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.22))
        line.lineWidth = max(1.1, rect.width * 0.09)
        line.lineCapStyle = .round
        line.stroke()
    }

    private func drawCloseSymbol(in rect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 0.72).setStroke()

        let path = NSBezierPath()
        let inset = rect.width * 0.32
        path.lineWidth = max(1.1, rect.width * 0.085)
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    private func drawMinimizeSymbol(in rect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 0.68).setStroke()

        let path = NSBezierPath()
        let inset = rect.width * 0.29
        path.lineWidth = max(1.25, rect.width * 0.095)
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.midY))
        path.stroke()
    }
}

private extension PreviewControlButton.Kind {
    var fillColor: NSColor {
        switch self {
        case .quitApp:
            return NSColor(calibratedRed: 0.64, green: 0.36, blue: 0.96, alpha: 1)
        case .closeWindow:
            return NSColor(calibratedRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
        case .minimizeWindow:
            return NSColor(calibratedRed: 1.00, green: 0.76, blue: 0.28, alpha: 1)
        }
    }

    var toolTip: String {
        switch self {
        case .quitApp:
            return "退出此应用"
        case .closeWindow:
            return "关闭窗口"
        case .minimizeWindow:
            return "最小化窗口"
        }
    }
}
