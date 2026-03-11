import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var visualizerView: VisualizerView!
    private var audioCaptureManager: AudioCaptureManager!
    private var audioAnalyzer: AudioAnalyzer!
    private var displayTimer: Timer?
    private var statusMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupAudio()
        startDisplayTimer()
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

        statusMenuItem = NSMenuItem(title: "WaveBar — Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Style
        let styleMenu = NSMenu()
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

        let quitItem = NSMenuItem(title: "Quit WaveBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Audio

    private func setupAudio() {
        audioAnalyzer = AudioAnalyzer(fftSize: 1024, bandCount: 16)
        audioCaptureManager = AudioCaptureManager()
        audioCaptureManager.onStatusChanged = { [weak self] status in
            self?.statusMenuItem?.title = "WaveBar — \(status.rawValue)"
        }
        audioCaptureManager.startCapture()
    }

    // MARK: - Display

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.updateVisualization()
            }
        }
        // .common includes eventTracking mode, so animation continues while menu is open
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func updateVisualization() {
        let samples = audioCaptureManager.currentSamples
        guard !samples.isEmpty else { return }
        let bands = audioAnalyzer.analyze(samples: samples)
        visualizerView.bands = bands
    }

    // MARK: - Actions

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? VisualizerStyle else { return }
        visualizerView.style = style
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
    }

    @objc private func setColor(_ sender: NSMenuItem) {
        guard let scheme = sender.representedObject as? ColorScheme else { return }
        visualizerView.colorScheme = scheme
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
    }

    @objc private func setWidth(_ sender: NSMenuItem) {
        let width = CGFloat(sender.tag)
        statusItem.length = width
        if let button = statusItem.button {
            visualizerView.frame = button.bounds
        }
        visualizerView.needsDisplay = true
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        let value = Float(sender.tag) / 100.0
        audioAnalyzer.sensitivity = value
        if let menu = sender.menu {
            for item in menu.items { item.state = (item == sender) ? .on : .off }
        }
    }

    @objc private func quitApp() {
        audioCaptureManager.stopCapture()
        NSApp.terminate(nil)
    }
}
