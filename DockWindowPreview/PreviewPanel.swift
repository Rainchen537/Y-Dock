import AppKit
import Foundation
import QuartzCore

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

        level = .floating
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
        frame.insetBy(dx: -10, dy: -10).contains(point)
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
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
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

    private func makeRows(for items: [PreviewItem], appIcon: NSImage?) -> [NSStackView] {
        let groups = rowGroups(for: items)
        var rows: [NSStackView] = []

        for group in groups {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .top
            row.distribution = .fill

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
                card.onFocusPreview = { [weak self] selectedWindow in
                    self?.showFocusOverlay(for: selectedWindow)
                }
                card.onFocusPreviewEnded = { [weak self] in
                    self?.focusOverlay.hide()
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
        let spacing: CGFloat = 6
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
        let spacing: CGFloat = 6
        let rowWidths = groups.map { group in
            group.reduce(CGFloat(0)) { $0 + cardSize(for: $1).width } + CGFloat(max(group.count - 1, 0)) * spacing
        }
        let rowHeights = groups.map { group in
            group.map { cardSize(for: $0).height }.max() ?? 0
        }
        let width = (rowWidths.max() ?? 0) + 12
        let height = rowHeights.reduce(CGFloat(0), +) + CGFloat(max(groups.count - 1, 0)) * spacing + 12

        guard let screen = NSScreen.main else {
            return NSSize(width: width, height: height)
        }

        return NSSize(
            width: min(width, screen.visibleFrame.width - 32),
            height: min(height, screen.visibleFrame.height - 32)
        )
    }

    private func cardSize(for item: PreviewItem) -> NSSize {
        let titleHeight: CGFloat = settings.showWindowTitles ? 27 : 0
        return NSSize(width: item.thumbnailSize.width + 12, height: item.thumbnailSize.height + titleHeight + 12)
    }

    private func showFocusOverlay(for window: WindowInfo) {
        let aspectRatio = max(0.2, window.bounds.width / max(window.bounds.height, 1))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let screenFrame = screen?.frame
        let availableFrame = screen?.visibleFrame ?? screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetSize = focusImageSize(aspectRatio: aspectRatio, in: availableFrame)

        guard let image = thumbnailProvider.focusImage(for: window, targetSize: targetSize) else {
            focusOverlay.hide()
            return
        }

        focusOverlay.show(image: image, aspectRatio: aspectRatio, preferredScreenFrame: screenFrame)
        orderFrontRegardless()
    }

    private func focusImageSize(aspectRatio: CGFloat, in rect: NSRect) -> NSSize {
        let ratio = max(0.2, min(aspectRatio, 5))
        let maxWidth = rect.width * 0.76
        let maxHeight = rect.height * 0.70
        var width = maxWidth
        var height = width / ratio

        if height > maxHeight {
            height = maxHeight
            width = height * ratio
        }

        return NSSize(width: max(80, width), height: max(60, height))
    }

    private func positionedFrame(size: NSSize, anchor: NSPoint, dockEdge: DockEdge?) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screenFrame = screen?.frame ?? visibleFrame
        let padding: CGFloat = 10

        var origin: NSPoint
        switch dockEdge {
        case .bottom:
            let y = visibleFrame.minY > screenFrame.minY + 20 ? visibleFrame.minY + padding : screenFrame.minY + 92
            origin = NSPoint(x: anchor.x - size.width / 2, y: y)
        case .left:
            let x = visibleFrame.minX > screenFrame.minX + 20 ? visibleFrame.minX + padding : screenFrame.minX + 92
            origin = NSPoint(x: x, y: anchor.y - size.height / 2)
        case .right:
            let x = visibleFrame.maxX < screenFrame.maxX - 20 ? visibleFrame.maxX - size.width - padding : screenFrame.maxX - size.width - 92
            origin = NSPoint(x: x, y: anchor.y - size.height / 2)
        case nil:
            origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 24)
        }

        origin.x = min(max(origin.x, visibleFrame.minX + padding), visibleFrame.maxX - size.width - padding)
        origin.y = min(max(origin.y, visibleFrame.minY + padding), visibleFrame.maxY - size.height - padding)

        return NSRect(origin: origin, size: size)
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
    var onFocusPreview: ((WindowInfo) -> Void)?
    var onFocusPreviewEnded: (() -> Void)?

    private let windowInfo: WindowInfo
    private let iconView = NSImageView()
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let controlStack = NSStackView()
    private lazy var quitButton = PreviewControlButton(kind: .quitApp, target: self, action: #selector(quitApplicationButtonClicked))
    private lazy var closeButton = PreviewControlButton(kind: .closeWindow, target: self, action: #selector(closeButtonClicked))
    private lazy var minimizeButton = PreviewControlButton(kind: .minimizeWindow, target: self, action: #selector(minimizeButtonClicked))
    private let thumbnailSize: NSSize
    private let settings: AppSettings
    private var focusPreviewWorkItem: DispatchWorkItem?

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
        let titleHeight: CGFloat = settings.showWindowTitles ? 27 : 0
        return NSSize(width: thumbnailSize.width + 12, height: thumbnailSize.height + titleHeight + 12)
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
        scheduleFocusPreview()
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.06).cgColor
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        setControlButtonsVisible(false)
        cancelFocusPreview(notifyEnd: true)
    }

    override func mouseDown(with event: NSEvent) {
        cancelFocusPreview(notifyEnd: true)
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
        }
    }

    private func scheduleFocusPreview() {
        focusPreviewWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onFocusPreview?(self.windowInfo)
        }
        focusPreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func cancelFocusPreview(notifyEnd: Bool) {
        focusPreviewWorkItem?.cancel()
        focusPreviewWorkItem = nil
        if notifyEnd {
            onFocusPreviewEnded?()
        }
    }

    @objc private func quitApplicationButtonClicked() {
        cancelFocusPreview(notifyEnd: true)
        setControlButtonsVisible(false)
        onQuitApplication?(windowInfo)
    }

    @objc private func closeButtonClicked() {
        cancelFocusPreview(notifyEnd: true)
        setControlButtonsVisible(false)
        onClose?(windowInfo)
    }

    @objc private func minimizeButtonClicked() {
        cancelFocusPreview(notifyEnd: true)
        setControlButtonsVisible(false)
        onMinimize?(windowInfo)
    }

    private func setupViews(appIcon: NSImage?, thumbnail: NSImage) {
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 5
        contentStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
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
            titleRow.spacing = 6
            titleRow.alignment = .centerY
            titleRow.distribution = .fill
            titleRow.widthAnchor.constraint(equalToConstant: thumbnailSize.width).isActive = true

            iconView.image = appIcon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true

            titleLabel.stringValue = windowInfo.title
            titleLabel.font = NSFont.systemFont(ofSize: 11.7, weight: .semibold)
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

        controlStack.orientation = .horizontal
        controlStack.spacing = 7
        controlStack.alignment = .centerY
        controlStack.alphaValue = 0
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        controlStack.addArrangedSubview(quitButton)
        controlStack.addArrangedSubview(closeButton)
        controlStack.addArrangedSubview(minimizeButton)
        addSubview(controlStack)

        NSLayoutConstraint.activate([
            controlStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controlStack.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        ])
        setControlButtonsVisible(false)
    }
}

private final class PreviewControlButton: NSButton {
    enum Kind {
        case quitApp
        case closeWindow
        case minimizeWindow
    }

    private let kind: Kind

    init(kind: Kind, target: AnyObject?, action: Selector) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        self.target = target
        self.action = action
        title = ""
        isBordered = false
        isEnabled = false
        wantsLayer = true
        toolTip = kind.toolTip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 12).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 12, height: 12)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let circleRect = bounds.insetBy(dx: 0.25, dy: 0.25)
        NSColor(calibratedWhite: 0, alpha: isHighlighted ? 0.18 : 0.10).setFill()
        NSBezierPath(ovalIn: circleRect.offsetBy(dx: 0, dy: -0.5)).fill()

        kind.fillColor.setFill()
        NSBezierPath(ovalIn: circleRect).fill()

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

        let center = NSPoint(x: rect.midX, y: rect.midY - 0.35)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 3.15, startAngle: 130, endAngle: 410)
        arc.lineWidth = 1.05
        arc.lineCapStyle = .round
        arc.stroke()

        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.midX, y: rect.midY + 1.0))
        line.line(to: NSPoint(x: rect.midX, y: rect.midY + 4.0))
        line.lineWidth = 1.1
        line.lineCapStyle = .round
        line.stroke()
    }

    private func drawCloseSymbol(in rect: NSRect) {
        NSColor(calibratedWhite: 0.16, alpha: 0.72).setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + 3.65, y: rect.minY + 3.65))
        path.line(to: NSPoint(x: rect.maxX - 3.65, y: rect.maxY - 3.65))
        path.move(to: NSPoint(x: rect.maxX - 3.65, y: rect.minY + 3.65))
        path.line(to: NSPoint(x: rect.minX + 3.65, y: rect.maxY - 3.65))
        path.stroke()
    }

    private func drawMinimizeSymbol(in rect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 0.68).setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + 3.15, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - 3.15, y: rect.midY))
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
