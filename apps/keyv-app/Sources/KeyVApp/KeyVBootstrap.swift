import AppKit
import KeyVHostKit

// KeyV host bootstrap (accessory app, LSUIElement). NSApplication +
// delegate wiring lives here; everything else in AppDelegate.swift.

@main
struct KeyVBootstrap {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
