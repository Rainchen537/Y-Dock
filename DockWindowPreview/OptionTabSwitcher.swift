import AppKit
import Carbon
import QuartzCore

private struct OptionTabItem {
    let window: WindowInfo
    let appIcon: NSImage
    let thumbnail: NSImage
    let thumbnailSize: NSSize
}

final class OptionTabSwitcher {
    private enum HotKeyID: UInt32 {
        case forward = 1
        case backward = 2
    }

    private let windowCollector: WindowCollector
    private let thumbnailProvider: WindowThumbnailProvider
    private let windowActivator: WindowActivator
    private let settings: AppSettings
    private lazy var panel: OptionTabPanel = {
        let panel = OptionTabPanel()
        panel.onClickItem = { [weak self] index in
            self?.activateSelection(at: index)
        }
        return panel
    }()

    private var eventHandler: EventHandlerRef?
    private var forwardHotKey: EventHotKeyRef?
    private var backwardHotKey: EventHotKeyRef?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var isStarted = false
    private var isSwitching = false
    private var items: [OptionTabItem] = []
    private var selectedIndex = 0
    private var sessionID = 0

    private let collectorQueue = DispatchQueue(label: "com.ydock.option-tab.collector", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "com.ydock.option-tab.thumbnails", qos: .userInitiated)
    private let hotKeySignature = OSType(UInt32(bigEndian: 0x59444F43)) // "YDCK"

    init(
        windowCollector: WindowCollector,
        thumbnailProvider: WindowThumbnailProvider,
        windowActivator: WindowActivator,
        settings: AppSettings
    ) {
        self.windowCollector = windowCollector
        self.thumbnailProvider = thumbnailProvider
        self.windowActivator = windowActivator
        self.settings = settings
    }

    func start() {
        guard !isStarted else { return }
        installHotKeyHandler()
        registerHotKeys()
        installFlagsMonitors()
        isStarted = true
        DWLog("Option+Tab switcher started")
    }

    func stop() {
        guard isStarted else { return }
        cancelSelection()

        if let forwardHotKey {
            UnregisterEventHotKey(forwardHotKey)
        }
        if let backwardHotKey {
            UnregisterEventHotKey(backwardHotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }

        forwardHotKey = nil
        backwardHotKey = nil
        eventHandler = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        isStarted = false
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID()
                let error = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard error == noErr else {
                    return error
                }

                let switcher = Unmanaged<OptionTabSwitcher>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    switcher.handleHotKey(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        if status != noErr {
            DWLog("Failed to install Option+Tab hotkey handler: \(status)")
        }
    }

    private func registerHotKeys() {
        let forwardID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.forward.rawValue)
        let forwardStatus = RegisterEventHotKey(
            UInt32(kVK_Tab),
            UInt32(optionKey),
            forwardID,
            GetApplicationEventTarget(),
            0,
            &forwardHotKey
        )

        let backwardID = EventHotKeyID(signature: hotKeySignature, id: HotKeyID.backward.rawValue)
        let backwardStatus = RegisterEventHotKey(
            UInt32(kVK_Tab),
            UInt32(optionKey | shiftKey),
            backwardID,
            GetApplicationEventTarget(),
            0,
            &backwardHotKey
        )

        if forwardStatus != noErr {
            DWLog("Failed to register Option+Tab hotkey: \(forwardStatus)")
        }
        if backwardStatus != noErr {
            DWLog("Failed to register Option+Shift+Tab hotkey: \(backwardStatus)")
        }
    }

    private func installFlagsMonitors() {
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleFlagsChanged(event.modifierFlags)
            }
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event.modifierFlags)
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                _ = self?.handleKeyDown(event)
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyDown(event) == true {
                return nil
            }
            return event
        }
    }

    private func handleHotKey(id: UInt32) {
        switch HotKeyID(rawValue: id) {
        case .forward:
            showOrAdvance(direction: 1)
        case .backward:
            showOrAdvance(direction: -1)
        case .none:
            break
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard isSwitching else { return }
        if !flags.contains(.option) {
            commitSelection()
        }
    }

    @discardableResult
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isSwitching, event.keyCode == UInt16(kVK_Escape) else {
            return false
        }

        cancelSelection()
        return true
    }

    private func showOrAdvance(direction: Int) {
        if isSwitching {
            moveSelection(direction: direction)
            return
        }

        // Option+Tab is an intentional switcher, so the first frame should include
        // minimized windows when Accessibility allows it. Dock hover still keeps
        // the lighter fast path elsewhere for sweep performance.
        let includeMinimized = AXIsProcessTrusted()
        var windows = windowCollector.switchableWindows(includeMinimized: includeMinimized)
        if windows.isEmpty, includeMinimized {
            windows = windowCollector.switchableWindows(includeMinimized: false)
        }
        guard !windows.isEmpty else {
            NSSound.beep()
            return
        }

        items = makeItems(from: windows)
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }

        isSwitching = true
        sessionID += 1
        let currentSessionID = sessionID
        selectedIndex = items.count > 1
            ? (direction > 0 ? 1 : items.count - 1)
            : 0

        panel.show(items: items, selectedIndex: selectedIndex)
        loadThumbnails(for: items, sessionID: currentSessionID)
    }

    private func moveSelection(direction: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + direction + items.count) % items.count
        panel.updateSelection(selectedIndex)
    }

    private func commitSelection() {
        guard isSwitching else { return }
        activateSelection(at: selectedIndex)
    }

    private func activateSelection(at index: Int) {
        guard items.indices.contains(index) else {
            cancelSelection()
            return
        }

        let window = items[index].window
        resetState()
        windowActivator.activate(window)
    }

    private func cancelSelection() {
        guard isSwitching || panel.isVisible else { return }
        resetState()
    }

    private func resetState() {
        sessionID += 1
        panel.hide()
        isSwitching = false
        items = []
        selectedIndex = 0
    }

    private func makeItems(from windows: [WindowInfo]) -> [OptionTabItem] {
        windows.compactMap { window in
            guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
                return nil
            }

            let targetSize = thumbnailTargetSize(for: window)
            let thumbnail = thumbnailProvider.placeholderThumbnail(for: window, targetSize: targetSize)
            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? AppIconFactory.appIcon(size: 64)

            return OptionTabItem(
                window: window,
                appIcon: icon,
                thumbnail: thumbnail,
                thumbnailSize: targetSize
            )
        }
    }

    private func loadThumbnails(for items: [OptionTabItem], sessionID: Int) {
        thumbnailQueue.async { [weak self] in
            guard let self else { return }

            for item in items {
                let image = self.thumbnailProvider.thumbnail(for: item.window, targetSize: item.thumbnailSize)
                DispatchQueue.main.async { [weak self] in
                    guard
                        let self,
                        self.isSwitching,
                        self.sessionID == sessionID
                    else {
                        return
                    }

                    self.panel.updateThumbnail(image, for: item.window.windowID)
                }
            }
        }
    }

    private func loadExpandedWindowListIfNeeded(sessionID: Int) {
        guard AXIsProcessTrusted() else { return }

        collectorQueue.async { [weak self] in
            guard let self else { return }

            let windows = self.windowCollector.switchableWindows(includeMinimized: true)
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.isSwitching,
                    self.sessionID == sessionID,
                    !windows.isEmpty
                else {
                    return
                }

                let currentIDs = self.items.map(\.window.windowID)
                let nextIDs = windows.map(\.windowID)
                guard currentIDs != nextIDs else { return }

                let selectedWindowID = self.items.indices.contains(self.selectedIndex)
                    ? self.items[self.selectedIndex].window.windowID
                    : nil

                self.items = self.makeItems(from: windows)
                if let selectedWindowID,
                   let preservedIndex = self.items.firstIndex(where: { $0.window.windowID == selectedWindowID }) {
                    self.selectedIndex = preservedIndex
                } else {
                    self.selectedIndex = min(self.selectedIndex, max(0, self.items.count - 1))
                }

                self.panel.show(items: self.items, selectedIndex: self.selectedIndex)
                self.loadThumbnails(for: self.items, sessionID: sessionID)
            }
        }
    }

    private func thumbnailTargetSize(for window: WindowInfo) -> CGSize {
        let cardScale: CGFloat = 1.50
        let baseHeight: CGFloat = max(96, min(128, CGFloat(settings.thumbnailHeight) * 0.68))
        let height = baseHeight * cardScale
        let aspect = window.bounds.height > 0 ? window.bounds.width / window.bounds.height : 1.6
        let baseWidth = max(148, min(240, baseHeight * aspect))
        let width = baseWidth * cardScale
        return CGSize(width: width, height: height)
    }
}

private final class OptionTabPanel: NSPanel {
    var onClickItem: ((Int) -> Void)?

    private enum Metrics {
        static let outerPadding: CGFloat = 24
        static let cardGap: CGFloat = 18
        static let rowGap: CGFloat = 18
        static let minPanelWidth: CGFloat = 460
        static let maxScreenWidthRatio: CGFloat = 0.8
        static let maxPanelHeightInset: CGFloat = 110
        static let panelCornerRadius: CGFloat = 28
    }

    private let backgroundView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stackView = NSStackView()
    private var cardViews: [OptionTabCardView] = []
    private var currentItems: [OptionTabItem] = []

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        animationBehavior = .utilityWindow
        setupViews()
    }

    func show(items: [OptionTabItem], selectedIndex: Int) {
        currentItems = items
        rebuildCards()

        let targetSize = preferredPanelSize(for: items)
        setFrame(centeredFrame(size: targetSize), display: false)
        updateSelection(selectedIndex)
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
        currentItems = []
        cardViews = []
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func updateSelection(_ index: Int) {
        for (cardIndex, card) in cardViews.enumerated() {
            card.isSelected = cardIndex == index
        }
        scrollSelectedCardToVisible(index)
    }

    func updateThumbnail(_ image: NSImage, for windowID: CGWindowID) {
        guard let card = cardViews.first(where: { $0.windowID == windowID }) else { return }
        card.updateThumbnail(image)
    }

    private func setupViews() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.wantsLayer = true
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.appearance = NSAppearance(named: .darkAqua)
        backgroundView.layer?.cornerRadius = Metrics.panelCornerRadius
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView

        documentView.translatesAutoresizingMaskIntoConstraints = false

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = Metrics.rowGap

        documentView.addSubview(stackView)
        backgroundView.addSubview(scrollView)
        self.contentView = backgroundView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: Metrics.outerPadding),
            scrollView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -Metrics.outerPadding),
            scrollView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: Metrics.outerPadding),
            scrollView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -Metrics.outerPadding),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stackView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor)
        ])
    }

    private func rebuildCards() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cardViews = []

        for rowItems in rows(for: currentItems, maxContentWidth: maxContentWidth()) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = Metrics.cardGap
            row.translatesAutoresizingMaskIntoConstraints = false

            for item in rowItems {
                let globalIndex = cardViews.count
                let card = OptionTabCardView(item: item)
                card.onClick = { [weak self] in
                    self?.onClickItem?(globalIndex)
                }
                row.addArrangedSubview(card)
                cardViews.append(card)
            }

            stackView.addArrangedSubview(row)
        }
    }

    private func rows(for items: [OptionTabItem], maxContentWidth: CGFloat) -> [[OptionTabItem]] {
        var rows: [[OptionTabItem]] = []
        var currentRow: [OptionTabItem] = []
        var currentWidth: CGFloat = 0

        for item in items {
            let itemWidth = OptionTabCardView.preferredSize(for: item).width
            let nextWidth = currentRow.isEmpty ? itemWidth : currentWidth + Metrics.cardGap + itemWidth

            if !currentRow.isEmpty && nextWidth > maxContentWidth {
                rows.append(currentRow)
                currentRow = [item]
                currentWidth = itemWidth
            } else {
                currentRow.append(item)
                currentWidth = nextWidth
            }
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }

    private func preferredPanelSize(for items: [OptionTabItem]) -> CGSize {
        let screen = screenForPanel()
        let maxPanelWidth = screen.visibleFrame.width * Metrics.maxScreenWidthRatio
        let rows = rows(for: items, maxContentWidth: maxContentWidth(for: screen))
        let rowSizes = rows.map { row in
            row.reduce(CGSize.zero) { partial, item in
                let size = OptionTabCardView.preferredSize(for: item)
                return CGSize(
                    width: partial.width + size.width,
                    height: max(partial.height, size.height)
                )
            }
        }

        let widestRow = rowSizes.enumerated().reduce(CGFloat.zero) { widest, element in
            let row = rows[element.offset]
            let gaps = CGFloat(max(0, row.count - 1)) * Metrics.cardGap
            return max(widest, element.element.width + gaps)
        }
        let totalHeight = rowSizes.reduce(CGFloat.zero) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * Metrics.rowGap

        let maxWidth = min(maxPanelWidth, screen.visibleFrame.width - 80)
        let maxHeight = screen.visibleFrame.height - Metrics.maxPanelHeightInset

        return CGSize(
            width: min(max(Metrics.minPanelWidth, widestRow + Metrics.outerPadding * 2), maxWidth),
            height: min(totalHeight + Metrics.outerPadding * 2, maxHeight)
        )
    }

    private func maxContentWidth(for screen: NSScreen? = nil) -> CGFloat {
        let targetScreen = screen ?? screenForPanel()
        return max(
            240,
            targetScreen.visibleFrame.width * Metrics.maxScreenWidthRatio - Metrics.outerPadding * 2
        )
    }

    private func centeredFrame(size: CGSize) -> CGRect {
        let screenFrame = screenForPanel().visibleFrame
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func screenForPanel() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func scrollSelectedCardToVisible(_ index: Int) {
        guard cardViews.indices.contains(index) else { return }
        let card = cardViews[index]
        card.scrollToVisible(card.bounds)
    }
}

private final class OptionTabCardView: NSView {
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            updateSelectionAppearance()
        }
    }

    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 12
        static let iconSize: CGFloat = 36
        static let titleGap: CGFloat = 12
        static let titleHeight: CGFloat = 51
        static let cardCornerRadius: CGFloat = 20
        static let thumbnailCornerRadius: CGFloat = 10
    }

    private let item: OptionTabItem
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    init(item: OptionTabItem) {
        self.item = item
        super.init(frame: .zero)
        setupViews()
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    var windowID: CGWindowID {
        item.window.windowID
    }

    static func preferredSize(for item: OptionTabItem) -> CGSize {
        CGSize(
            width: max(251, item.thumbnailSize.width + Metrics.horizontalPadding * 2),
            height: item.thumbnailSize.height + Metrics.verticalPadding * 2 + Metrics.titleHeight
        )
    }

    override var intrinsicContentSize: NSSize {
        Self.preferredSize(for: item)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func updateThumbnail(_ image: NSImage) {
        thumbnailView.image = image
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = Metrics.thumbnailCornerRadius
        thumbnailView.layer?.cornerCurve = .continuous
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.borderWidth = 1
        thumbnailView.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(thumbnailView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Metrics.titleGap),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            thumbnailView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            thumbnailView.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding + Metrics.titleHeight),
            thumbnailView.heightAnchor.constraint(equalToConstant: item.thumbnailSize.height),
            thumbnailView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding)
        ])
    }

    private func configure() {
        iconView.image = item.appIcon
        titleLabel.stringValue = item.window.title
        thumbnailView.image = item.thumbnail
        updateSelectionAppearance()
    }

    private func updateSelectionAppearance() {
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.26).cgColor
            : NSColor.black.withAlphaComponent(0.22).cgColor
        layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
            : NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.shadowColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        layer?.shadowOpacity = isSelected ? 0.28 : 0
        layer?.shadowRadius = isSelected ? 12 : 0
        layer?.shadowOffset = .zero
    }
}
