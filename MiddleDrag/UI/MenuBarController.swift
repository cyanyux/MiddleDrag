import Cocoa
import Carbon.HIToolbox

/// Manages the menu bar UI and user interactions
@MainActor
public class MenuBarController: NSObject {

    // MARK: - Properties

    private struct StatusItemBox: @unchecked Sendable {
        let value: NSStatusItem
    }

    private var statusItemStorage: StatusItemBox?
    private var statusItem: NSStatusItem! {
        get { statusItemStorage?.value }
        set { statusItemStorage = newValue.map(StatusItemBox.init(value:)) }
    }
    private weak var multitouchManager: MultitouchManager?
    private var preferences: UserPreferences
    private(set) var isMenuBarVisible = true

    // MARK: - Initialization

    public init(multitouchManager: MultitouchManager, preferences: UserPreferences) {
        self.multitouchManager = multitouchManager
        self.preferences = preferences
        super.init()

        setupStatusItem()

        // Listen for late device connections (e.g., Bluetooth trackpad connecting after boot)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceDidConnect),
            name: .middleDragDeviceConnected,
            object: nil
        )

        // Listen for polling timeout (no device found within time limit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pollingDidTimeout),
            name: .middleDragPollingTimedOut,
            object: nil
        )
    }

    deinit {
        let statusItemToRemove = statusItemStorage

        if Thread.isMainThread {
            if let statusItemToRemove {
                NSStatusBar.system.removeStatusItem(statusItemToRemove.value)
            }
            return
        }

        DispatchQueue.main.async {
            if let statusItemToRemove {
                NSStatusBar.system.removeStatusItem(statusItemToRemove.value)
            }
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if statusItem.button != nil {
            updateStatusIcon(enabled: multitouchManager?.isEnabled ?? false)
        }

        buildMenu()
    }

    func updateStatusIcon(enabled: Bool) {
        guard let button = statusItem.button else { return }

        // Active: filled. Disabled: outline + dimmed — clearly distinct.
        // 17pt sizing for the menu-bar icon (default symbols render ~15pt).
        let iconName = enabled ? "ellipsis.circle.fill" : "ellipsis.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let image =
            (NSImage(systemSymbolName: iconName, accessibilityDescription: "MiddleDrag")
            ?? NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "MiddleDrag"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image

        // Brief pulse on change, then settle at full opacity (active) or dimmed (disabled).
        let targetAlpha: CGFloat = enabled ? 1.0 : 0.5
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            button.animator().alphaValue = 0.7
        }, completionHandler: {
            // Ensure mutation happens on the main actor
            Task { @MainActor in
                button.alphaValue = targetAlpha
            }
        })
    }

    // MARK: - Menu Building

    func buildMenu() {
        let menu = NSMenu()

        // Status
        menu.addItem(createStatusItem())
        menu.addItem(NSMenuItem.separator())

        // Enable/Disable
        menu.addItem(createEnabledItem())
        menu.addItem(createTapToClickItem())
        menu.addItem(createMiddleDragItem())
        menu.addItem(NSMenuItem.separator())

        // Settings
        menu.addItem(createSensitivityMenu())
        menu.addItem(createAdvancedMenu())
        menu.addItem(NSMenuItem.separator())

        // App items
        menu.addItem(createMenuItem(title: "About MiddleDrag", action: #selector(showAbout)))
        menu.addItem(createLaunchAtLoginItem())
        menu.addItem(createCheckForUpdatesItem())
        menu.addItem(createAutoUpdateItem())
        menu.addItem(NSMenuItem.separator())

        // Actions
        menu.addItem(createMenuItem(title: "Quick Setup", action: #selector(showQuickSetup)))
        menu.addItem(createMenuItem(title: "Hide Menu Bar Icon (⌘⇧M or Spotlight to restore)", action: #selector(hideMenuBarIcon)))
        menu.addItem(createMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func createStatusItem() -> NSMenuItem {
        let isEnabled = multitouchManager?.isEnabled ?? false
        let isPolling = multitouchManager?.isPollingForDevices ?? false
        let title: String
        if isPolling {
            title = "Waiting for Trackpad…"
        } else if isEnabled {
            title = "MiddleDrag Active"
        } else {
            title = "MiddleDrag Disabled"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func createEnabledItem() -> NSMenuItem {
        // No keyEquivalent: a custom-view menu item (keepOpen) ignores key equivalents,
        // so it would be a dead, invisible shortcut. The global ⌘⇧E hotkey still toggles.
        let item = NSMenuItem(
            title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        item.target = self  // IMPORTANT: Set target
        return keepOpen(item, checked: { [weak self] in self?.multitouchManager?.isEnabled ?? false })
    }

    private func createMiddleDragItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Drag", action: #selector(toggleMiddleDrag), keyEquivalent: "")
        item.target = self
        // Only checked/enabled when the main toggle is on.
        return keepOpen(
            item,
            checked: { [weak self] in
                (self?.multitouchManager?.isEnabled ?? false) && (self?.preferences.middleDragEnabled ?? false)
            },
            enabled: { [weak self] in self?.multitouchManager?.isEnabled ?? false })
    }

    private func createTapToClickItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Tap to Click", action: #selector(toggleTapToClick), keyEquivalent: "")
        item.target = self
        return keepOpen(
            item,
            checked: { [weak self] in
                (self?.multitouchManager?.isEnabled ?? false) && (self?.preferences.tapToClickEnabled ?? false)
            },
            enabled: { [weak self] in self?.multitouchManager?.isEnabled ?? false })
    }

    private func createLaunchAtLoginItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.target = self  // IMPORTANT: Set target
        return keepOpen(item, checked: { [weak self] in self?.preferences.launchAtLogin ?? false })
    }

    private func createCheckForUpdatesItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        return item
    }

    private func createAutoUpdateItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Automatically Check for Updates", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        item.target = self
        return keepOpen(item, checked: { UpdateManager.shared.automaticallyChecksForUpdates })
    }

    private func createMenuItem(title: String, action: Selector, keyEquivalent: String = "")
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self  // IMPORTANT: Set target
        return item
    }

    private func createSensitivityMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Drag Sensitivity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let sensitivities: [(String, Float)] = [
            ("Slow (0.5x)", 0.5),
            ("Precision (0.75x)", 0.75),
            ("Normal (1x)", 1.0),
            ("Fast (1.5x)", 1.5),
            ("Very Fast (2x)", 2.0),
        ]

        for (title, value) in sensitivities {
            let menuItem = NSMenuItem(
                title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            menuItem.target = self  // IMPORTANT: Set target
            menuItem.representedObject = value
            submenu.addItem(
                keepOpen(
                    menuItem,
                    checked: { [weak self] in abs(Float(self?.preferences.dragSensitivity ?? -1) - value) < 0.01 }))
        }

        item.submenu = submenu
        return item
    }

    private func createAdvancedMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Add system gesture configuration option
        let gestureItem = NSMenuItem(
            title: "Configure System Gestures...",
            action: #selector(configureSystemGestures),
            keyEquivalent: ""
        )
        gestureItem.target = self
        submenu.addItem(gestureItem)

        submenu.addItem(NSMenuItem.separator())

        // Palm Rejection section
        submenu.addItem(createPalmRejectionMenu())

        submenu.addItem(NSMenuItem.separator())

        // Minimum Window Size section (separate from palm rejection as it's window-based)
        let windowSizeItem = createAdvancedMenuItem(
            title: "Ignore Small Windows",
            checked: { [weak self] in self?.preferences.minimumWindowSizeFilterEnabled ?? false },
            action: #selector(toggleMinimumWindowSizeFilter)
        )
        submenu.addItem(windowSizeItem)

        // Window size threshold options (always shown; enabled only when the filter is on)
        let windowSizes: [(String, Double)] = [
            ("Very Small (50px)", 50),
            ("Small (100px)", 100),
            ("Medium (200px)", 200),
            ("Large (300px)", 300),
        ]
        for (title, value) in windowSizes {
            let sizeItem = NSMenuItem(
                title: "    \(title)", action: #selector(setMinimumWindowSize(_:)),
                keyEquivalent: "")
            sizeItem.target = self
            sizeItem.representedObject = value
            submenu.addItem(
                keepOpen(
                    sizeItem,
                    checked: { [weak self] in abs((self?.preferences.minimumWindowWidth ?? -1) - value) < 0.01 },
                    enabled: { [weak self] in self?.preferences.minimumWindowSizeFilterEnabled ?? false }))
        }

        // Ignore Desktop option (suppress gestures when cursor is over desktop)
        let ignoreDesktopItem = createAdvancedMenuItem(
            title: "Ignore Desktop",
            checked: { [weak self] in self?.preferences.ignoreDesktop ?? false },
            action: #selector(toggleIgnoreDesktop)
        )
        submenu.addItem(ignoreDesktopItem)

        // Window Bar Drag - pass through gestures when cursor is over title bar
        // Allows macOS native three-finger drag to work for window dragging
        let windowBarDragItem = createAdvancedMenuItem(
            title: "Window Bar Drag",
            checked: { [weak self] in self?.preferences.passThroughTitleBar ?? false },
            action: #selector(toggleWindowBarDrag)
        )
        submenu.addItem(windowBarDragItem)

        let verticalSwipeItem = createAdvancedMenuItem(
            title: "Pass Through Vertical Swipes",
            checked: { [weak self] in self?.preferences.passThroughVerticalSwipes ?? false },
            action: #selector(toggleVerticalSwipePassthrough)
        )
        submenu.addItem(verticalSwipeItem)

        let altTabItem = createAdvancedMenuItem(
            title: "Pass Through AltTab Switcher",
            checked: { [weak self] in self?.preferences.passThroughAltTab ?? false },
            action: #selector(toggleAltTabPassthrough)
        )
        submenu.addItem(altTabItem)

        submenu.addItem(NSMenuItem.separator())

        // Relift during drag - Linux-style text selection
        submenu.addItem(
            createAdvancedMenuItem(
                title: "Allow Relift During Drag",
                checked: { [weak self] in self?.preferences.allowReliftDuringDrag ?? false },
                action: #selector(toggleAllowReliftDuringDrag)
            ))

        submenu.addItem(NSMenuItem.separator())
        
        // Emergency release for stuck drags
        let forceReleaseItem = NSMenuItem(
            title: "Force Release Stuck Drag",
            action: #selector(forceReleaseStuckDrag),
            keyEquivalent: ""
        )
        forceReleaseItem.target = self
        submenu.addItem(forceReleaseItem)
        
        submenu.addItem(NSMenuItem.separator())

        // Hotkey rebinding
        let hotkeyItem = NSMenuItem(
            title: "Change Toggle Hotkey (\(preferences.toggleHotKey.displayString))…",
            action: #selector(rebindToggleHotKey),
            keyEquivalent: ""
        )
        hotkeyItem.target = self
        submenu.addItem(hotkeyItem)

        let menuBarHotkeyItem = NSMenuItem(
            title: "Change Menu Bar Hotkey (\(preferences.menuBarHotKey.displayString))…",
            action: #selector(rebindMenuBarHotKey),
            keyEquivalent: ""
        )
        menuBarHotkeyItem.target = self
        submenu.addItem(menuBarHotkeyItem)

        submenu.addItem(NSMenuItem.separator())

        // Telemetry section header
        let telemetryHeader = NSMenuItem(
            title: "Help Improve MiddleDrag:", action: nil, keyEquivalent: "")
        telemetryHeader.isEnabled = false
        submenu.addItem(telemetryHeader)

        // Crash reporting (only sends on crash)
        submenu.addItem(
            createAdvancedMenuItem(
                title: "Send Crash Reports",
                checked: { CrashReporter.shared.isEnabled },
                action: #selector(toggleCrashReporting)
            ))

        // Performance monitoring (sends during use)
        submenu.addItem(
            createAdvancedMenuItem(
                title: "Send Performance Data",
                checked: { CrashReporter.shared.performanceMonitoringEnabled },
                action: #selector(togglePerformanceMonitoring)
            ))

        item.submenu = submenu
        return item
    }

    private func createPalmRejectionMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Palm Rejection", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        // Edge Exclusion Zone section
        let exclusionItem = createAdvancedMenuItem(
            title: "Edge Exclusion Zone",
            checked: { [weak self] in self?.preferences.exclusionZoneEnabled ?? false },
            action: #selector(toggleExclusionZone)
        )
        submenu.addItem(exclusionItem)

        // Per-edge toggles — always shown; enabled only when the zone is on.
        let edges: [(String, () -> Bool, Selector)] = [
            ("Bottom Edge", { [weak self] in self?.preferences.excludeBottomEdge ?? false }, #selector(toggleExcludeBottomEdge)),
            ("Left Edge", { [weak self] in self?.preferences.excludeLeftEdge ?? false }, #selector(toggleExcludeLeftEdge)),
            ("Right Edge", { [weak self] in self?.preferences.excludeRightEdge ?? false }, #selector(toggleExcludeRightEdge)),
        ]
        for (title, checked, action) in edges {
            let edgeItem = NSMenuItem(title: "    \(title)", action: action, keyEquivalent: "")
            edgeItem.target = self
            submenu.addItem(
                keepOpen(
                    edgeItem, checked: checked,
                    enabled: { [weak self] in self?.preferences.exclusionZoneEnabled ?? false }))
        }

        submenu.addItem(NSMenuItem.separator())

        let sizes: [(String, Double)] = [
            ("Band: 3% (Small)", 0.03),
            ("Band: 5% (Default)", 0.05),
            ("Band: 8% (Medium)", 0.08),
            ("Band: 12% (Large)", 0.12),
        ]
        for (title, value) in sizes {
            let sizeItem = NSMenuItem(
                title: "    \(title)", action: #selector(setExclusionZoneSize(_:)), keyEquivalent: "")
            sizeItem.target = self
            sizeItem.representedObject = value
            submenu.addItem(
                keepOpen(
                    sizeItem,
                    checked: { [weak self] in abs((self?.preferences.exclusionZoneSize ?? -1) - value) < 0.01 },
                    enabled: { [weak self] in self?.preferences.exclusionZoneEnabled ?? false }))
        }

        submenu.addItem(NSMenuItem.separator())

        // Modifier Key section
        let modifierItem = createAdvancedMenuItem(
            title: "Require Modifier Key",
            checked: { [weak self] in self?.preferences.requireModifierKey ?? false },
            action: #selector(toggleRequireModifierKey)
        )
        submenu.addItem(modifierItem)

        // Modifier key options — always shown; enabled only when required.
        for keyType in ModifierKeyType.allCases {
            let keyItem = NSMenuItem(
                title: "    \(keyType.displayName)", action: #selector(setModifierKeyType(_:)),
                keyEquivalent: "")
            keyItem.target = self
            keyItem.representedObject = keyType.rawValue
            submenu.addItem(
                keepOpen(
                    keyItem,
                    checked: { [weak self] in self?.preferences.modifierKeyType == keyType },
                    enabled: { [weak self] in self?.preferences.requireModifierKey ?? false }))
        }

        submenu.addItem(NSMenuItem.separator())

        // Contact Size Filter section
        let contactSizeItem = createAdvancedMenuItem(
            title: "Filter Large Contacts",
            checked: { [weak self] in self?.preferences.contactSizeFilterEnabled ?? false },
            action: #selector(toggleContactSizeFilter)
        )
        submenu.addItem(contactSizeItem)

        // Contact size threshold options — always shown; enabled only when filtering.
        let contactThresholds: [(String, Double)] = [
            ("Strict (1.0)", 1.0),
            ("Normal (1.5)", 1.5),
            ("Lenient (2.0)", 2.0),
        ]
        for (title, value) in contactThresholds {
            let thresholdItem = NSMenuItem(
                title: "    \(title)", action: #selector(setContactSizeThreshold(_:)),
                keyEquivalent: "")
            thresholdItem.target = self
            thresholdItem.representedObject = value
            submenu.addItem(
                keepOpen(
                    thresholdItem,
                    checked: { [weak self] in abs((self?.preferences.maxContactSize ?? -1) - value) < 0.01 },
                    enabled: { [weak self] in self?.preferences.contactSizeFilterEnabled ?? false }))
        }

        item.submenu = submenu
        return item
    }

    /// Build a boolean-toggle menu item that keeps the menu open when clicked.
    /// `checked`/`enabled` are read live on every redraw.
    private func createAdvancedMenuItem(
        title: String,
        checked: @escaping () -> Bool,
        enabled: @escaping () -> Bool = { true },
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self  // IMPORTANT: Set target
        return keepOpen(item, checked: checked, enabled: enabled)
    }

    /// Attach a keep-open interactive view to an already-configured menu item.
    @discardableResult
    private func keepOpen(
        _ item: NSMenuItem,
        checked: @escaping () -> Bool,
        enabled: @escaping () -> Bool = { true }
    ) -> NSMenuItem {
        item.view = InteractiveMenuItemView(item: item, checked: checked, enabled: enabled)
        return item
    }

    // MARK: - Actions

    @objc func deviceDidConnect() {
        let isEnabled = multitouchManager?.isEnabled ?? false
        updateStatusIcon(enabled: isEnabled)
        buildMenu()
    }

    @objc func pollingDidTimeout() {
        updateStatusIcon(enabled: false)
        buildMenu()
    }

    @objc public func toggleEnabled() {
        multitouchManager?.toggleEnabled()
        let isEnabled = multitouchManager?.isEnabled ?? false

        updateStatusIcon(enabled: isEnabled)
        // Rebuild so the status line ("MiddleDrag Active/Disabled" — a plain item that
        // does not live-refresh) is correct the next time the menu opens. The interactive
        // rows in the currently-open menu update in place via InteractiveMenuItemView.
        buildMenu()
    }

    @objc func toggleMiddleDrag() {
        preferences.middleDragEnabled.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.middleDragEnabled = preferences.middleDragEnabled
        multitouchManager?.updateConfiguration(config)

        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleTapToClick() {
        preferences.tapToClickEnabled.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.tapToClickEnabled = preferences.tapToClickEnabled
        multitouchManager?.updateConfiguration(config)

        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func setSensitivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Float else { return }

        // Update preferences and manager. The radio checkmark is drawn from the row's
        // `checked` closure and refreshed in place by InteractiveMenuItemView.mouseUp.
        preferences.dragSensitivity = Double(value)
        multitouchManager?.configuration.sensitivity = value

        // Notify delegate to save preferences
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func configureSystemGestures() {
        // Check if settings are already optimal
        if !SystemGestureHelper.hasConflictingSettings() {
            AlertHelper.showGestureConfigurationAlreadyOptimal()
            return
        }

        // Show prompt and apply if user confirms
        if AlertHelper.showGestureConfigurationPrompt() {
            if SystemGestureHelper.applyRecommendedSettings() {
                AlertHelper.showGestureConfigurationSuccess()
            } else {
                AlertHelper.showGestureConfigurationFailure()
            }
        }
    }
    
    @objc func rebindToggleHotKey() {
        showHotKeyRecorderPanel(
            title: "Toggle MiddleDrag Hotkey",
            current: preferences.toggleHotKey
        ) { [weak self] newBinding in
            guard let self else { return }
            self.preferences.toggleHotKey = newBinding
            NotificationCenter.default.post(name: .preferencesChanged, object: self.preferences)
            self.buildMenu()
        }
    }

    @objc func rebindMenuBarHotKey() {
        showHotKeyRecorderPanel(
            title: "Menu Bar Visibility Hotkey",
            current: preferences.menuBarHotKey
        ) { [weak self] newBinding in
            guard let self else { return }
            self.preferences.menuBarHotKey = newBinding
            NotificationCenter.default.post(name: .preferencesChanged, object: self.preferences)
            self.buildMenu()
        }
    }

    private func showHotKeyRecorderPanel(
        title: String,
        current: HotKeyBinding,
        onAccept: @escaping (HotKeyBinding) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Press a new key combination (with at least one modifier). Press Escape to cancel."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let recorder = HotKeyRecorderView(binding: current)
        recorder.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        alert.accessoryView = recorder

        // Bring app to front so the alert can receive key events
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        // Ensure the recorder's local keyboard monitor is cleaned up regardless
        // of how the alert was dismissed (clicking OK/Cancel without pressing a key
        // does not trigger resignFirstResponder on the accessory view)
        recorder.cancelRecording()

        if response == .alertFirstButtonReturn {
            onAccept(recorder.binding)
        }
    }

    // MARK: - Palm Rejection Actions

    @objc func toggleExclusionZone() {
        preferences.exclusionZoneEnabled.toggle()
        applyExclusionZoneConfig()
    }

    @objc func toggleExcludeBottomEdge() {
        preferences.excludeBottomEdge.toggle()
        applyExclusionZoneConfig()
    }

    @objc func toggleExcludeLeftEdge() {
        preferences.excludeLeftEdge.toggle()
        applyExclusionZoneConfig()
    }

    @objc func toggleExcludeRightEdge() {
        preferences.excludeRightEdge.toggle()
        applyExclusionZoneConfig()
    }

    /// Push the full edge-exclusion configuration to the manager and refresh.
    private func applyExclusionZoneConfig() {
        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.exclusionZoneEnabled = preferences.exclusionZoneEnabled
        config.exclusionZoneSize = Float(preferences.exclusionZoneSize)
        config.excludeBottomEdge = preferences.excludeBottomEdge
        config.excludeLeftEdge = preferences.excludeLeftEdge
        config.excludeRightEdge = preferences.excludeRightEdge
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func setExclusionZoneSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }

        preferences.exclusionZoneSize = value

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.exclusionZoneSize = Float(value)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleRequireModifierKey() {
        preferences.requireModifierKey.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.requireModifierKey = preferences.requireModifierKey
        config.modifierKeyType = preferences.modifierKeyType
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func setModifierKeyType(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let keyType = ModifierKeyType(rawValue: rawValue)
        else { return }

        preferences.modifierKeyType = keyType

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.modifierKeyType = keyType
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleContactSizeFilter() {
        preferences.contactSizeFilterEnabled.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.contactSizeFilterEnabled = preferences.contactSizeFilterEnabled
        config.maxContactSize = Float(preferences.maxContactSize)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func setContactSizeThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }

        preferences.maxContactSize = value

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.maxContactSize = Float(value)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleMinimumWindowSizeFilter() {
        preferences.minimumWindowSizeFilterEnabled.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.minimumWindowSizeFilterEnabled = preferences.minimumWindowSizeFilterEnabled
        config.minimumWindowWidth = CGFloat(preferences.minimumWindowWidth)
        config.minimumWindowHeight = CGFloat(preferences.minimumWindowHeight)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func setMinimumWindowSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }

        // Set both width and height to the same value (square threshold)
        preferences.minimumWindowWidth = value
        preferences.minimumWindowHeight = value

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.minimumWindowWidth = CGFloat(value)
        config.minimumWindowHeight = CGFloat(value)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleIgnoreDesktop() {
        preferences.ignoreDesktop.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.ignoreDesktop = preferences.ignoreDesktop
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleWindowBarDrag() {
        preferences.passThroughTitleBar.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.passThroughTitleBar = preferences.passThroughTitleBar
        config.titleBarHeight = CGFloat(preferences.titleBarHeight)
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleVerticalSwipePassthrough() {
        preferences.passThroughVerticalSwipes.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.passThroughVerticalSwipes = preferences.passThroughVerticalSwipes
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleAltTabPassthrough() {
        preferences.passThroughAltTab.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.passThroughAltTab = preferences.passThroughAltTab
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func toggleAllowReliftDuringDrag() {
        preferences.allowReliftDuringDrag.toggle()

        var config = multitouchManager?.configuration ?? GestureConfiguration()
        config.allowReliftDuringDrag = preferences.allowReliftDuringDrag
        multitouchManager?.updateConfiguration(config)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }
    
    @objc func forceReleaseStuckDrag() {
        multitouchManager?.forceReleaseStuckDrag()
        
        // Provide visual feedback that the action was triggered
        flashStatusBarIcon()
    }
    
    /// Flash the status bar icon to provide visual feedback for actions
    /// Uses alpha animation consistent with updateStatusIcon pattern
    private func flashStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        
        // Use alpha animation for visual feedback (consistent with updateStatusIcon)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            button.animator().alphaValue = 0.3
        } completionHandler: { [weak button] in
            // NSAnimationContext runs completion handlers on the main thread,
            // but Swift's concurrency doesn't know that statically
            MainActor.assumeIsolated {
                guard let button = button else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    button.animator().alphaValue = 1.0
                }
            }
        }
    }

    @objc func toggleLaunchAtLogin() {
        preferences.launchAtLogin.toggle()
        // Checkmark refreshes in place via InteractiveMenuItemView.mouseUp.

        NotificationCenter.default.post(
            name: .launchAtLoginChanged, object: preferences.launchAtLogin)
        NotificationCenter.default.post(name: .preferencesChanged, object: preferences)
    }

    @objc func checkForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }

    @objc func toggleAutoUpdate() {
        UpdateManager.shared.automaticallyChecksForUpdates.toggle()
        // Checkmark refreshes in place via InteractiveMenuItemView.mouseUp.
    }

    @objc func toggleCrashReporting() {
        CrashReporter.shared.isEnabled.toggle()
        // Checkmark refreshes in place via InteractiveMenuItemView.mouseUp.
    }

    @objc func togglePerformanceMonitoring() {
        CrashReporter.shared.performanceMonitoringEnabled.toggle()
        // Checkmark refreshes in place via InteractiveMenuItemView.mouseUp.
    }

    @objc private func showAbout() {
        AlertHelper.showAbout()
    }

    @objc private func showQuickSetup() {
        AlertHelper.showQuickSetup()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Menu Bar Visibility

    @objc func hideMenuBarIcon() {
        setMenuBarVisible(false)
    }

    /// Show the menu bar icon (no-op if already visible). Called from Spotlight reopen.
    public func showMenuBarIcon() {
        guard !isMenuBarVisible else { return }
        setMenuBarVisible(true)
    }

    /// Toggle menu bar icon visibility. Called from the global hotkey (⌘⇧M).
    public func toggleMenuBarVisibility() {
        setMenuBarVisible(!isMenuBarVisible)
    }

    private func setMenuBarVisible(_ visible: Bool) {
        isMenuBarVisible = visible
        statusItem.isVisible = visible

        if visible {
            // Rebuild menu and update icon to reflect current state
            let isEnabled = multitouchManager?.isEnabled ?? false
            updateStatusIcon(enabled: isEnabled)
            buildMenu()

            // Pop the menu open so the user knows it's back
            // Skip during tests — performClick opens a modal menu loop that stalls CI
            let isRunningTests = NSClassFromString("XCTestCase") != nil
            if !isRunningTests, let button = statusItem.button {
                button.performClick(nil)
            }
        }
    }
}

// MARK: - Interactive (keep-open) menu item

/// A menu-item view that performs its item's action on click WITHOUT dismissing the
/// menu, so toggles and option pickers can be changed several times in a row. The
/// checkmark and enabled state are read through closures on every redraw, so when one
/// row changes a value the whole menu can be refreshed in place (no rebuild needed).
final class InteractiveMenuItemView: NSView {
    private weak var item: NSMenuItem?
    private let isChecked: () -> Bool
    private let isRowEnabled: () -> Bool
    private var hovered = false

    // Title and its measured size are fixed for the view's lifetime (the menu is rebuilt
    // when any title changes), so measure once in init rather than on every draw.
    private let title: String
    private let titleSize: NSSize

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let rowHeight: CGFloat = 22
    private static let checkX: CGFloat = 7
    private static let textX: CGFloat = 22
    private static let rightPad: CGFloat = 26
    private static let minWidth: CGFloat = 210

    init(item: NSMenuItem, checked: @escaping () -> Bool, enabled: @escaping () -> Bool) {
        self.item = item
        self.isChecked = checked
        self.isRowEnabled = enabled
        let title = item.title
        let titleSize = (title as NSString).size(withAttributes: [.font: Self.font])
        self.title = title
        self.titleSize = titleSize
        super.init(
            frame: NSRect(
                x: 0, y: 0,
                width: max(Self.minWidth, Self.textX + ceil(titleSize.width) + Self.rightPad),
                height: Self.rowHeight))
        // Let AppKit stretch the row to the full menu width so the highlight fills it.
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = isRowEnabled()

        if hovered && enabled {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }

        let textColor: NSColor =
            !enabled ? .disabledControlTextColor : (hovered ? .selectedMenuItemTextColor : .labelColor)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor]
        let y = (bounds.height - titleSize.height) / 2

        if isChecked() {
            ("✓" as NSString).draw(at: NSPoint(x: Self.checkX, y: y), withAttributes: attrs)
        }
        (title as NSString).draw(at: NSPoint(x: Self.textX, y: y), withAttributes: attrs)
    }

    override func mouseUp(with event: NSEvent) {
        guard isRowEnabled(), let item = item, let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        // Refresh every interactive row in this menu so radio selection and
        // parent-dependent enabled state update live, without closing the menu.
        if let siblings = item.menu?.items {
            for sibling in siblings {
                (sibling.view as? InteractiveMenuItemView)?.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
}

// MARK: - Notification Names

extension Notification.Name {
    public static let preferencesChanged = Notification.Name("MiddleDragPreferencesChanged")
    public static let launchAtLoginChanged = Notification.Name("MiddleDragLaunchAtLoginChanged")
    /// Posted when a multitouch device connects after polling (e.g., Bluetooth trackpad at boot)
    public static let middleDragDeviceConnected = Notification.Name("MiddleDragDeviceConnected")
    /// Posted when device polling times out without finding a device
    public static let middleDragPollingTimedOut = Notification.Name("MiddleDragPollingTimedOut")
}
