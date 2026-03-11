import AppKit
import CoreServices

// Register with Launch Services so macOS can relaunch the app (e.g. after granting permissions)
LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
