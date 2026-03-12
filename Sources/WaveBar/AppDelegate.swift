import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var visualizerView: VisualizerView!
    private var audioCaptureManager: AudioCaptureManager!
    private var audioAnalyzer: AudioAnalyzer!
    private var displayTimer: Timer?
    private var statusMenuItem: NSMenuItem!

    // For hover preview: save current values to restore on menu close
    private var savedStyle: VisualizerStyle?
    private var savedColorScheme: ColorScheme?
    private var savedWidth: Int?
    private var savedSensitivity: Float?

    // UserDefaults keys
    private enum Keys {
        static let style = "visualizerStyle"
        static let colorScheme = "colorScheme"
        static let width = "width"
        static let sensitivity = "sensitivity"
        static let hasCompletedSetup = "hasCompletedSetup"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupAudio()
        restoreSettings()
        startDisplayTimer()
        showFirstLaunchSetupIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        audioCaptureManager?.stopCapture()
        displayTimer?.invalidate()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: 72)

        visualizerView = VisualizerView()
        visualizerView.frame = NSRect(x: 0, y: 0, width: 72, height: NSStatusBar.system.thickness)

        if let button = statusItem.button {
            visualizerView.frame = button.bounds
            visualizerView.autoresizingMask = [.width, .height]
            button.addSubview(visualizerView)
        }

        let menu = NSMenu()
        menu.delegate = self

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        statusMenuItem = NSMenuItem(title: "WaveBar v\(version) — Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Style
        let styleMenu = NSMenu()
        styleMenu.delegate = self
        for style in VisualizerStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(setStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            if style == .bars { item.state = .on }
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        // Color
        let colorMenu = NSMenu()
        colorMenu.delegate = self
        for scheme in ColorScheme.allCases {
            let item = NSMenuItem(title: scheme.rawValue, action: #selector(setColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scheme
            if scheme == .cyan { item.state = .on }
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        // Width
        let widthMenu = NSMenu()
        widthMenu.delegate = self
        for (title, width) in [("Extra Narrow", 32), ("Narrow", 48), ("Medium", 72), ("Wide", 100), ("Extra Wide", 140)] {
            let item = NSMenuItem(title: title, action: #selector(setWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = width
            if width == 72 { item.state = .on }
            widthMenu.addItem(item)
        }
        let widthItem = NSMenuItem(title: "Width", action: nil, keyEquivalent: "")
        widthItem.submenu = widthMenu
        menu.addItem(widthItem)

        // Sensitivity
        let sensitivityMenu = NSMenu()
        sensitivityMenu.delegate = self
        for (title, value) in [("Low", 0.5), ("Medium", 1.0), ("High", 2.0), ("Max", 4.0)] as [(String, Float)] {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(value * 100)
            if value == 1.0 { item.state = .on }
            sensitivityMenu.addItem(item)
        }
        let sensitivityItem = NSMenuItem(title: "Sensitivity", action: nil, keyEquivalent: "")
        sensitivityItem.submenu = sensitivityMenu
        menu.addItem(sensitivityItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let permItem = NSMenuItem(title: "Check Audio Permissions...", action: #selector(openAudioPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit WaveBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - First Launch Setup

    private func showFirstLaunchSetupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Keys.hasCompletedSetup) else { return }
        UserDefaults.standard.set(true, forKey: Keys.hasCompletedSetup)

        // Bring app to front (needed for LSUIElement apps)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Welcome to WaveBar!"
        alert.informativeText = """
            WaveBar visualizes your system audio in the menu bar.

            To work, it needs access to System Audio Recording:

            1. Click "Open Settings" below
            2. In Privacy & Security, find "System Audio Recording"
               (⚠️ not "Screen Recording" — scroll down if needed)
            3. Click the "+" button at the bottom of the list
            4. Find and select WaveBar.app, then click Open
            5. Make sure the toggle next to WaveBar is ON

            Once permission is granted, play some music and \
            WaveBar will start visualizing automatically!
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "I'll do it later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
        }
    }

    // MARK: - Persistence

    private func restoreSettings() {
        let defaults = UserDefaults.standard

        if let styleName = defaults.string(forKey: Keys.style),
           let style = VisualizerStyle(rawValue: styleName) {
            visualizerView.style = style
            if let styleMenu = statusItem.menu?.item(withTitle: "Style")?.submenu {
                for item in styleMenu.items {
                    item.state = (item.representedObject as? VisualizerStyle) == style ? .on : .off
                }
            }
        }

        if let colorName = defaults.string(forKey: Keys.colorScheme),
           let scheme = ColorScheme(rawValue: colorName) {
            visualizerView.colorScheme = scheme
            if let colorMenu = statusItem.menu?.item(withTitle: "Color")?.submenu {
                for item in colorMenu.items {
                    item.state = (item.representedObject as? ColorScheme) == scheme ? .on : .off
                }
            }
        }

        let width = defaults.integer(forKey: Keys.width)
        if width > 0 {
            applyWidth(width)
        }

        let sens = defaults.float(forKey: Keys.sensitivity)
        if sens > 0 {
            audioAnalyzer.sensitivity = sens
            if let sensMenu = statusItem.menu?.item(withTitle: "Sensitivity")?.submenu {
                for item in sensMenu.items {
                    item.state = item.tag == Int(sens * 100) ? .on : .off
                }
            }
        }
    }

    // MARK: - Audio

    private func setupAudio() {
        audioAnalyzer = AudioAnalyzer(fftSize: 1024, bandCount: 16)
        audioCaptureManager = AudioCaptureManager()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        audioCaptureManager.onStatusChanged = { [weak self] status in
            self?.statusMenuItem?.title = "WaveBar v\(version) — \(status.rawValue)"
        }
        audioCaptureManager.startCapture()
    }

    // MARK: - Display

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.updateVisualization()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private var lastBands: [Float] = []

    private func updateVisualization() {
        let samples = audioCaptureManager.currentSamples
        guard !samples.isEmpty else { return }
        let bands = audioAnalyzer.analyze(samples: samples)
        // Skip redraw if bands haven't changed meaningfully
        if lastBands.count == bands.count {
            var maxDiff: Float = 0
            for i in 0..<bands.count {
                maxDiff = max(maxDiff, abs(bands[i] - lastBands[i]))
            }
            if maxDiff < 0.005 { return }
        }
        lastBands = bands
        visualizerView.bands = bands
    }

    // MARK: - Actions

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? VisualizerStyle else { return }
        savedStyle = nil  // commit the preview
        visualizerView.style = style
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
        UserDefaults.standard.set(style.rawValue, forKey: Keys.style)

        let isCircle = style == .circle || style == .circleRays || style == .circleDots
        if isCircle {
            applyWidth(32)
            UserDefaults.standard.set(32, forKey: Keys.width)
        }
    }

    private func applyWidth(_ width: Int) {
        statusItem.length = CGFloat(width)
        if let button = statusItem.button {
            visualizerView.frame = button.bounds
        }
        visualizerView.needsDisplay = true
        if let widthMenu = statusItem.menu?.item(withTitle: "Width")?.submenu {
            for item in widthMenu.items {
                item.state = item.tag == width ? .on : .off
            }
        }
    }

    @objc private func setColor(_ sender: NSMenuItem) {
        guard let scheme = sender.representedObject as? ColorScheme else { return }
        savedColorScheme = nil
        visualizerView.colorScheme = scheme
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
        UserDefaults.standard.set(scheme.rawValue, forKey: Keys.colorScheme)
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        savedWidth = nil
        applyWidth(sender.tag)
        UserDefaults.standard.set(sender.tag, forKey: Keys.width)
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        savedSensitivity = nil
        let sens = Float(sender.tag) / 100.0
        audioAnalyzer.sensitivity = sens
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
        UserDefaults.standard.set(sens, forKey: Keys.sensitivity)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                sender.state = .off
            } else {
                try SMAppService.mainApp.register()
                sender.state = .on
            }
        } catch {
            print("WaveBar: Login item toggle failed: \(error)")
        }
    }

    @objc private func openAudioPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    @objc private func quitApp() {
        audioCaptureManager.stopCapture()
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate (hover preview)

extension AppDelegate: @preconcurrency NSMenuDelegate {
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        handleHighlight(menu: menu, item: item)
    }

    private func handleHighlight(menu: NSMenu, item: NSMenuItem?) {
        // Style preview
        if menu.items.first?.representedObject is VisualizerStyle {
            if let style = item?.representedObject as? VisualizerStyle {
                if savedStyle == nil { savedStyle = visualizerView.style }
                visualizerView.style = style
                let isCircle = style == .circle || style == .circleRays || style == .circleDots
                if isCircle {
                    if savedWidth == nil { savedWidth = Int(statusItem.length) }
                    statusItem.length = 32
                    if let button = statusItem.button { visualizerView.frame = button.bounds }
                } else if let sw = savedWidth {
                    statusItem.length = CGFloat(sw)
                    if let button = statusItem.button { visualizerView.frame = button.bounds }
                    savedWidth = nil
                }
            }
            return
        }

        // Color preview
        if menu.items.first?.representedObject is ColorScheme {
            if let scheme = item?.representedObject as? ColorScheme {
                if savedColorScheme == nil { savedColorScheme = visualizerView.colorScheme }
                visualizerView.colorScheme = scheme
            }
            return
        }

        // Width preview
        if menu.items.contains(where: { $0.action == #selector(setWidth(_:)) }) {
            if let w = item, w.action == #selector(setWidth(_:)) {
                if savedWidth == nil { savedWidth = Int(statusItem.length) }
                statusItem.length = CGFloat(w.tag)
                if let button = statusItem.button { visualizerView.frame = button.bounds }
                visualizerView.needsDisplay = true
            }
            return
        }

        // Sensitivity preview
        if menu.items.contains(where: { $0.action == #selector(setSensitivity(_:)) }) {
            if let s = item, s.action == #selector(setSensitivity(_:)) {
                if savedSensitivity == nil { savedSensitivity = audioAnalyzer.sensitivity }
                audioAnalyzer.sensitivity = Float(s.tag) / 100.0
            }
            return
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        restoreAfterPreview()
    }

    private func restoreAfterPreview() {
        // Restore any previewed-but-not-committed values
        if let style = savedStyle {
            visualizerView.style = style
            savedStyle = nil
        }
        if let scheme = savedColorScheme {
            visualizerView.colorScheme = scheme
            savedColorScheme = nil
        }
        if let width = savedWidth {
            statusItem.length = CGFloat(width)
            if let button = statusItem.button { visualizerView.frame = button.bounds }
            visualizerView.needsDisplay = true
            savedWidth = nil
        }
        if let sens = savedSensitivity {
            audioAnalyzer.sensitivity = sens
            savedSensitivity = nil
        }
    }
}
