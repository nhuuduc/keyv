import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Settings control that records a global hotkey combo.
/// Click → "recording" state → press the combo → saved & re-registered live.
public final class HotkeyRecorderView: NSView {
    var valueChanged: (_ keyCode: Int, _ carbonModifiers: UInt) -> Void = { _, _ in }
    var accessibilityLabelText: String = "Phím tắt"

    private var isRecording = false
    private var isHovered = false
    private var recordedKeyCode: Int
    private var recordedModifiers: UInt
    private var recordedCharactersHint: String?
    private var trackingAreaRef: NSTrackingArea?

    public init(keyCode: Int, carbonModifiers: UInt) {
        recordedKeyCode = keyCode
        recordedModifiers = carbonModifiers
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        wantsLayer = true
        redraw()
    }

    func descriptionOverride(keyCode: Int, carbonModifiers mods: UInt) {
        if recordedKeyCode != keyCode || recordedModifiers != mods {
            recordedCharactersHint = nil
        }
        recordedKeyCode = keyCode
        recordedModifiers = mods
        redraw()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        isRecording = true
        redraw()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        isRecording = false
        redraw()
        return true
    }

    public override func mouseDown(with event: NSEvent) {
        if isRecording { stopRecording() } else { startRecording() }
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }

        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let carbonMods = Self.carbonMask(of: event.modifierFlags)
        guard carbonMods != 0 else {
            NSSound.beep()
            redraw()
            return
        }

        recordedKeyCode = Int(event.keyCode)
        recordedModifiers = carbonMods
        recordedCharactersHint = event.charactersIgnoringModifiers
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
        window?.makeFirstResponder(nil)
        redraw()
    }

    private func redraw() {
        needsDisplay = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabelText)
        let value = Self.describeOn(
            keyCode: recordedKeyCode,
            carbonModifiers: recordedModifiers,
            charactersHint: recordedCharactersHint
        )
        setAccessibilityValue(isRecording ? "Đang ghi phím" : value)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        guard rect.width > 4, rect.height > 4 else { return }

        let cornerRadius: CGFloat = 7
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            path.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            path.stroke()
            drawRecordingPrompt(in: rect)
        } else {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            if isHovered {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
                path.fill()
            }
            path.lineWidth = 1.0
            (isHovered ? NSColor.secondaryLabelColor.withAlphaComponent(0.45) : NSColor.separatorColor).setStroke()
            path.stroke()
            drawShortcutLabel(in: rect)
        }
    }

    private func drawRecordingPrompt(in rect: NSRect) {
        let availableWidth = max(rect.width - 14, 20)
        let compact = bounds.width < 195
        let primaryText = compact ? "Nhấn phím… " : "Nhấn tổ hợp… "
        let hintText = compact ? "Esc" : "Esc hủy"

        for fontSize in stride(from: CGFloat(12.0), through: CGFloat(10.0), by: -0.5) {
            let attr = NSMutableAttributedString(
                string: primaryText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                ]
            )
            attr.append(NSAttributedString(
                string: hintText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: max(fontSize - 1.0, 9.5), weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            let size = attr.size()
            if size.width <= availableWidth || fontSize == 10.0 {
                drawCentered(attr, in: rect, maxWidth: availableWidth)
                return
            }
        }
    }

    private func drawShortcutLabel(in rect: NSRect) {
        let availableWidth = max(rect.width - 16, 20)
        let fullLabel = Self.describeOn(
            keyCode: recordedKeyCode,
            carbonModifiers: recordedModifiers,
            charactersHint: recordedCharactersHint
        )
        let compactLabel = Self.compactDescribe(
            keyCode: recordedKeyCode,
            carbonModifiers: recordedModifiers,
            charactersHint: recordedCharactersHint
        )

        let preferCompact = bounds.width < 195
        let candidates = preferCompact ? [compactLabel] : [fullLabel, compactLabel]

        for candidate in candidates {
            for fontSize in stride(from: CGFloat(12.0), through: CGFloat(10.0), by: -0.5) {
                let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
                let attr = NSAttributedString(
                    string: candidate,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
                if attr.size().width <= availableWidth {
                    drawCentered(attr, in: rect, maxWidth: availableWidth)
                    return
                }
            }
        }

        let fallback = NSAttributedString(
            string: compactLabel,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        drawCentered(fallback, in: rect, maxWidth: availableWidth)
    }

    private func drawCentered(_ attr: NSAttributedString, in rect: NSRect, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let mutable = NSMutableAttributedString(attributedString: attr)
        mutable.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: mutable.length))
        let measured = mutable.size()
        let drawWidth = min(measured.width + 2, maxWidth)
        let drawRect = NSRect(
            x: rect.midX - drawWidth / 2,
            y: rect.midY - measured.height / 2,
            width: drawWidth,
            height: measured.height
        )
        mutable.draw(in: drawRect)
    }

    // MARK: - Static helpers

    public static func carbonMask(of flags: NSEvent.ModifierFlags) -> UInt {
        var m: UInt = 0
        if flags.contains(.command) { m |= UInt(cmdKey) }
        if flags.contains(.option)  { m |= UInt(optionKey) }
        if flags.contains(.control) { m |= UInt(controlKey) }
        if flags.contains(.shift)   { m |= UInt(shiftKey) }
        return m
    }

    public static func appKitModifiers(of mask: UInt) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mask & UInt(controlKey) != 0 { flags.insert(.control) }
        if mask & UInt(optionKey) != 0  { flags.insert(.option) }
        if mask & UInt(shiftKey) != 0   { flags.insert(.shift) }
        if mask & UInt(cmdKey) != 0     { flags.insert(.command) }
        return flags
    }

    public static func menuKeyEquivalent(for keyCode: Int) -> String? {
        if keyCode == 49 { return " " }
        if keyCode == 36 { return "\r" }
        if let ch = qIndex[keyCode], ch.count == 1 {
            return ch.lowercased()
        }
        return nil
    }

    private static func modifierNames(_ mask: UInt) -> [String] {
        var names: [String] = []
        if mask & UInt(controlKey) != 0 { names.append("Control") }
        if mask & UInt(optionKey) != 0  { names.append("Option") }
        if mask & UInt(shiftKey) != 0   { names.append("Shift") }
        if mask & UInt(cmdKey) != 0     { names.append("Command") }
        return names
    }

    private static func modifierSymbols(_ mask: UInt) -> String {
        var symbols = ""
        if mask & UInt(controlKey) != 0 { symbols += "⌃" }
        if mask & UInt(optionKey) != 0  { symbols += "⌥" }
        if mask & UInt(shiftKey) != 0   { symbols += "⇧" }
        if mask & UInt(cmdKey) != 0     { symbols += "⌘" }
        return symbols
    }

    public static func describe(keyCode: Int, carbonModifiers mask: UInt) -> String {
        (modifierNames(mask) + [keyName(keyCode: keyCode)]).joined(separator: " + ")
    }

    public static func describeOn(keyCode: Int, carbonModifiers mask: UInt, charactersHint: String?) -> String {
        if let hint = sanitizedHint(charactersHint) {
            return (modifierNames(mask) + [hint]).joined(separator: " + ")
        }
        return describe(keyCode: keyCode, carbonModifiers: mask)
    }

    public static func compactDescribe(keyCode: Int, carbonModifiers mask: UInt, charactersHint: String? = nil) -> String {
        let mods = modifierSymbols(mask)
        let key = sanitizedHint(charactersHint) ?? keyName(keyCode: keyCode)
        if mods.isEmpty { return key }
        return "\(mods) \(key)"
    }

    private static func sanitizedHint(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F }) else {
            return nil
        }
        return trimmed.uppercased()
    }

    private static func keyName(keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 53: return "Esc"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "⇞"
        case 121: return "⇟"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            if let ch = qIndex[keyCode] {
                return ch
            }
            return "Key \(keyCode)"
        }
    }

    private static let qIndex: [Int: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
    ]
}

/// SwiftUI bridge for the recorder, syncing state both ways.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: UInt
    var label: String = "Phím tắt"

    func makeNSView(context: Context) -> HotkeyRecorderView {
        let view = HotkeyRecorderView(keyCode: keyCode, carbonModifiers: modifiers)
        view.accessibilityLabelText = label
        view.valueChanged = { code, mods in
            keyCode = code
            modifiers = mods
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderView, context: Context) {
        nsView.accessibilityLabelText = label
        nsView.refresh(keyCode: keyCode, carbonModifiers: modifiers)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HotkeyRecorderView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 190, height: proposal.height ?? 30)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var view: HotkeyRecorderView?
    }
}

extension HotkeyRecorderView {
    func refresh(keyCode: Int, carbonModifiers mods: UInt) {
        if window != nil && isRecording { return }
        descriptionOverride(keyCode: keyCode, carbonModifiers: mods)
    }
}
