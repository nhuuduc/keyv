import AppKit
import InputMethodKit
import CKeyV
import KeyVCore

// KeyVIME — InputMethodKit helper (P5).
//
// Runs from ~/Library/Input Methods/ as its own .app bundle. It speaks on
// behalf of the system keyboard pipeline: same clean-room Rust core, in-
// process (no IPC socket); composition is driven by the IMK client instead
// of CGEventTap backspace injection — the safest path for apps the tap
// struggles with.
//
// This is a compile-included skeleton installed only when the user opts in
// (scripts/install_ime.sh), and the Info.plist carries
// ComponentInputModeDict / tsInputSourceID per Apple's IME contract.

final class KeyVInputController: IMKInputController {
    private let engine: ViEngine

    override init(server: IMKServer?, delegate: Any?, client: Any?) {
        engine = ViEngine(method: .telex, orthography: .traditional)
        super.init(server: server, delegate: delegate, client: client)
    }

    override func inputText(_ string: String!, client: Any!) -> Bool {
        guard let string else { return false }
        guard let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1 else {
            return false
        }

        let action = engine.process(Character(String(scalar)))
        switch action {
        case .pass:
            return false
        case .replace(let backspaces, let chars):
            guard let textClient = client as? IMKTextInput else { return false }
            // Feed replacement through the marked-text composition pipeline.
            if backspaces > 0 {
                textClient.setMarkedText(String(repeating: "\u{0008}", count: backspaces),
                                     selectionRange: NSRange(location: NSNotFound, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            textClient.setMarkedText(chars,
                                 selectionRange: NSRange(location: chars.count, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "KeyV")
        let about = NSMenuItem(title: "KeyV IME (P5)", action: nil, keyEquivalent: "")
        menu.addItem(about)
        return menu
    }
}

final class IMEApplicationDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "app.keyv.ime"
        server = IMKServer(name: "KeyV_IME_Server", bundleIdentifier: bundleIdentifier)
        NSApp.setActivationPolicy(.prohibited)
    }
}

let imeApp = NSApplication.shared
let imeDelegate = IMEApplicationDelegate()
imeApp.delegate = imeDelegate
imeApp.run()
