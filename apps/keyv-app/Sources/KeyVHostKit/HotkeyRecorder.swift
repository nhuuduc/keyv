import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Settings control that records a global hotkey combo.
/// Click → "recording" state → press the combo → saved & re-registered live.
final class HotkeyRecorderView: NSView {
    var valueChanged: (_ keyCode: Int, _ carbonModifiers: UInt) -> Void = { _, _ in }

    private var isRecording = false
    private var currentKeyName: String

    init(keyCode: Int, carbonModifiers: UInt) {
        currentKeyName = HotkeyRecorderView.describe(keyCode: keyCode, carbonModifiers: carbonModifiers)
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 32))
        wantsLayer = true
        redraw()
    }

    func descriptionOverride(keyCode: Int, carbonModifiers mods: UInt) {
        currentKeyName = HotkeyRecorderView.describe(keyCode: keyCode, carbonModifiers: mods)
        redraw()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 230, height: 32) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        redraw()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        redraw()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        if event.keyCode == 53 {          // Esc cancels
            stopRecording()
            return
        }

        let carbonMods = Self.carbonMask(of: event.modifierFlags)
        guard carbonMods != 0 else {
            // require at least one modifier so global hotkeys stay sane
            redraw()
            return
        }

        currentKeyName = Self.describeOn(keyCode: Int(event.keyCode),
                                         carbonModifiers: carbonMods,
                                         charactersHint: event.charactersIgnoringModifiers)
        valueChanged(Int(event.keyCode), carbonMods)
        stopRecording()
    }

    private func startRecording() {
        isRecording = true
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        redraw()
    }

    private func stopRecording() {
        isRecording = false
        window?.makeFirstResponder(window ?? self)
        redraw()
    }

    private func redraw() {
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Phím mở lịch sử clipboard")
        setAccessibilityValue(isRecording ? "Đang ghi phím" : currentKeyName)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
        let text = NSAttributedString(string: isRecording ? "Nhấn phím… Esc hủy" : currentKeyName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    // MARK: - Static helpers

    static func carbonMask(of flags: NSEvent.ModifierFlags) -> UInt {
        var m: UInt = 0
        if flags.contains(.command) { m |= UInt(cmdKey) }
        if flags.contains(.option)  { m |= UInt(optionKey) }
        if flags.contains(.control) { m |= UInt(controlKey) }
        if flags.contains(.shift)   { m |= UInt(shiftKey) }
        return m
    }

    private static func modifierNames(_ mask: UInt) -> [String] {
        var names: [String] = []
        if mask & UInt(controlKey) != 0 { names.append("Control") }
        if mask & UInt(optionKey) != 0 { names.append("Option") }
        if mask & UInt(shiftKey) != 0 { names.append("Shift") }
        if mask & UInt(cmdKey) != 0 { names.append("Command") }
        return names
    }

    static func describe(keyCode: Int, carbonModifiers mask: UInt) -> String {
        (modifierNames(mask) + [keyName(keyCode: keyCode)]).joined(separator: " + ")
    }

    static func describeOn(keyCode: Int, carbonModifiers mask: UInt, charactersHint: String?) -> String {
        if let hint = charactersHint, !hint.isEmpty, hint.uppercased() != " " {
            return (modifierNames(mask) + [hint.uppercased()]).joined(separator: " + ")
        }
        return describe(keyCode: keyCode, carbonModifiers: mask)
    }

    private static func keyName(keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"; case 53: return "Esc"; case 51: return "⌫"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 115: return "Home"; case 119: return "End"; case 116: return "⇞"; case 121: return "⇟"
        default:
            // A..Z row: US-ANSI codes.
            if let ch = qIndex[keyCode] {
                return ch
            }
            return "Key \(keyCode)"
        }
    }

    private static let qIndex: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 6: "Y", 16: "Z",
    ]

}

/// SwiftUI bridge for the recorder, syncing state both ways.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: UInt

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(keyCode: keyCode, carbonModifiers: modifiers)
        view.valueChanged = { code, mods in
            keyCode = code
            modifiers = mods
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        // External settings changes (e.g. defaults reset) refresh the label.
        nsView.refresh(keyCode: keyCode, carbonModifiers: modifiers)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var view: HotkeyRecorderView?
    }
}

extension HotkeyRecorderView {
    func refresh(keyCode: Int, carbonModifiers mods: UInt) {
        if window != nil && isRecording { return }
        // Re-describe via a light re-init path (cheap snapshot redraw).
        descriptionOverride(keyCode: keyCode, carbonModifiers: mods)
    }
}
