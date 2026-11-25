import Foundation
import Carbon.HIToolbox
import KeyVCore
import KeyVHostKit
import AppKit

// FFI wrapper + host + updater smoke test (no XCTest on Command Line Tools) —
// mirrors the Rust engine semantics through the Swift ViEngine layer. Exit 0 = pass.

var failures: [String] = []

private func screen(
    _ input: String,
    method: ViInputMethod,
    orthography: ViOrthography = .traditional,
    allowWAsConsonant: Bool = true,
    spellCheck: Bool = false
) -> String {
    let engine = ViEngine(method: method, orthography: orthography, allowWAsConsonant: allowWAsConsonant)
    engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: spellCheck)
    var cursor = ""
    for ch in input {
        if ch == "\u{0008}" {
            engine.processBackspace()
            if !cursor.isEmpty { cursor.removeLast() }
            continue
        }
        switch engine.process(ch) {
        case .pass:
            cursor.append(ch)
        case .replace(let backspaces, let chars):
            let pops = min(backspaces, cursor.count)
            cursor.removeLast(pops)
            cursor += chars
        }
    }
    return cursor
}

private func check(_ got: String, _ want: String, _ label: String) {
    if got != want {
        failures.append("\(label): got \"\(got)\" want \"\(want)\"")
    }
}

// Telex basics
check(screen("ddawng", method: .telex), "đăng", "telex ddawng")
check(screen("dduowngf", method: .telex), "đường", "single-w uow compound")
check(screen("dduongwf", method: .telex), "đường", "delayed-w uow compound")
check(screen("nuowcs", method: .telex), "nước", "nuowcs")
check(screen("nguowif", method: .telex), "người", "nguowif")
check(screen("thuowr", method: .telex), "thuở", "open thuowr")
check(screen("thuowng", method: .telex), "thương", "closed thuowng")
check(screen("khuyur", method: .telex), "khuỷu", "triphthong khuyur")
check(screen("toafn", method: .telex), "toàn", "tone reposition toafn")
check(screen("gifa", method: .telex), "già", "gi cluster reposition")
check(screen("qura", method: .telex), "quả", "qu cluster reposition")
check(screen("muonj", method: .telex), "muộn", "auto-circumflex muonj")
check(screen("ddienf", method: .telex), "điền", "auto-circumflex ddienf")

check(screen("tieenh\u{0008}gs", method: .telex), "tiếng", "backspace mid-syllable")
check(screen("ds\u{0008}d", method: .telex), "đ", "backspace before dd")

check(
    screen("Minhf ddang code Swift treen macos voiws terminal vaf github", method: .telex, spellCheck: true),
    "Mình đang code Swift trên macos với terminal và github",
    "mixed Vietnamese + English with spellCheck"
)

// Orthography: traditional tone on first vowel (òa), modern on second (oà)
check(screen("hoaf", method: .telex, orthography: .traditional), "h\u{00F2}a", "ortho traditional")
check(screen("hoaf", method: .telex, orthography: .modern), "ho\u{00E0}", "ortho modern")

// VNI
check(screen("d9", method: .vni), "đ", "vni d9")
check(screen("dang9", method: .vni), "đang", "vni delayed 9")
check(screen("duong972", method: .vni), "đường", "vni duong972")
check(screen("u7", method: .vni), "ư", "vni u7")
check(screen("a1", method: .vni), "á", "vni a1")

// Off mode passes everything through
check(screen("d9", method: .off), "d9", "off passthrough")

// Live tone strip (`0`)
check(screen("ha20", method: .vni), "ha", "live tone strip (ha20)")
check(screen("muon50", method: .vni), "muon", "live tone strip clears implicit hat")

// Macro path via FFI
do {
    let engine = ViEngine(method: .telex, orthography: .traditional, macroEnabled: true)
    engine.setMacro("hvbt", value: "nhé bạn")
    engine.setMacro("ddk", value: "đăng ký")
    var cursor = ""
    for ch in "ddawng ddk hvbt" {
        switch engine.process(ch) {
        case .pass: cursor.append(ch)
        case .replace(let b, let s):
            if b > cursor.count {
                failures.append("macro over-remove: b=\(b) cursor=\(cursor.count)")
                exit(2)
            }
            cursor.removeLast(b); cursor += s
        }
    }
    check(cursor, "đăng đăng ký nhé bạn", "macro FFI + telex coexistence")
}

// Unikey repeated-key restore via FFI
check(screen("barr", method: .telex), "bar", "repeated r restores bar")
check(screen("bass", method: .telex), "bas", "repeated s restores bas")
check(screen("baszz", method: .telex), "baz", "z strips tone then literal")
check(screen("ddienff", method: .telex), "đienf", "repeated f restores marks")

// Auto-capitalize
do {
    let engine = ViEngine(method: .telex, orthography: .traditional)
    engine.setOptions(autoCapitalize: true, repeatedRestore: true)
    var cursor = ""
    for ch in ". ba nam" {
        switch engine.process(ch) {
        case .pass: cursor.append(ch)
        case .replace(let b, let s): cursor.removeLast(min(b, cursor.count)); cursor += s
        }
    }
    check(cursor, ". Ba nam", "auto-capitalize after sentence end")
}

// UniKey public key conventions through the Rust-to-Swift ABI.
check(screen("win", method: .telex), "win", "literal leading w")
check(screen("wwin", method: .telex, allowWAsConsonant: false), "win", "escaped leading w")
check(screen("WWindowws", method: .telex, allowWAsConsonant: false), "Windows", "UniKey manual example")
check(screen("aaa eee ooo ddd aww oww uww", method: .telex), "aa ee oo dd aw ow uw", "repeated mark escapes")
check(screen("toanfs", method: .telex), "toán", "closed oa tone placement")
check(screen("e11", method: .vni), "e1", "VNI repeated tone escape")

do {
    let v020 = SemVer(parsing: "0.2.0")
    let v030 = SemVer(parsing: "v0.3.0")
    let v030Beta = SemVer(parsing: "0.3.0-beta.1")
    let v031 = SemVer(parsing: "0.3.1+build42")
    check(v020 != nil && v030 != nil && v030Beta != nil && v031 != nil ? "ok" : "nil", "ok", "SemVer parsing")
    if let v020, let v030, let v030Beta, let v031 {
        check(v020 < v030Beta && v030Beta < v030 && v030 < v031 ? "ok" : "bad", "ok", "SemVer ordering")
    }
    let sums = """
    # SHA-256 checksums
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  KeyV-0.3.0-macos-universal.zip
    fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 *KeyV-0.3.0-macos-universal.dmg
    """
    check(
        UpdateVerification.parseSHA256Sums(sums, assetName: "KeyV-0.3.0-macos-universal.zip") ?? "",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "SHA256SUMS zip lookup"
    )
    check(
        UpdateVerification.parseSHA256Sums(sums, assetName: "KeyV-0.3.0-macos-universal.dmg") ?? "",
        "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
        "SHA256SUMS dmg lookup"
    )
}

// Host settings + UI controller regressions use the smoke executable's defaults, never app.keyv.host.
MainActor.assumeIsolated {
    let defaults = UserDefaults.standard
    let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    precondition(domain != "app.keyv.host")
    let previous = defaults.persistentDomain(forName: domain)
    defaults.removePersistentDomain(forName: domain)
    defer {
        defaults.removePersistentDomain(forName: domain)
        if let previous { defaults.setPersistentDomain(previous, forName: domain) }
    }
    let model = SettingsModel()
    check(String(model.method.rawValue), "1", "fresh install defaults to Telex")
    check(model.spellCheck ? "true" : "false", "true", "fresh install enables spellCheck")
    check(model.ctrlShiftSwitch ? "true" : "false", "true", "fresh install enables Ctrl+Shift switch")
    check(model.autoCheckUpdates ? "true" : "false", "true", "fresh install enables autoCheckUpdates")
    model.method = .vni
    model.isEnglishMode = true
    check(String(model.method.rawValue), "0", "English radio updates method picker")
    model.isEnglishMode = false
    check(String(model.method.rawValue), "3", "Vietnamese radio restores VNI")
    model.updateRow(id: "test.keyv", methodRaw: 3, orthoRaw: 1)
    model.updateRow(id: "test.keyv", methodRaw: nil, orthoRaw: 1)
    let row = model.rows.first { $0.id == "test.keyv" }
    check(row?.methodRaw == nil && row?.orthoRaw == 1 ? "ok" : "bad", "ok", "clear method keeps orthography")
    model.updateRow(id: "test.keyv", methodRaw: nil, orthoRaw: nil)
    check(model.rows.contains { $0.id == "test.keyv" } ? "bad" : "ok", "ok", "clear final override returns to global")

    check(
        HotkeyRecorderView.describe(keyCode: 49, carbonModifiers: UInt(optionKey)),
        "Option + Space",
        "HotkeyRecorder full label"
    )
    check(
        HotkeyRecorderView.compactDescribe(keyCode: 6, carbonModifiers: UInt(optionKey)),
        "⌥ Z",
        "HotkeyRecorder compact label"
    )
    check(
        HotkeyRecorderView.compactDescribe(keyCode: 49, carbonModifiers: UInt(controlKey | shiftKey)),
        "⌃⇧ Space",
        "HotkeyRecorder compact multi-modifier label"
    )
    check(
        HotkeyRecorderView.menuKeyEquivalent(for: 6) ?? "",
        "z",
        "HotkeyRecorder lowercase menu keyEquivalent"
    )

    let picker = PickerController()
    picker.entries = [
        ClipboardEntry(id: 1, kind: .text, createdAt: Date(), sourceBundleID: "com.apple.TextEdit", text: "Xin chào KeyV trên macOS"),
        ClipboardEntry(id: 2, kind: .fileURL, createdAt: Date(), sourceBundleID: "com.apple.Finder", fileURL: URL(fileURLWithPath: "/tmp/bao-cao-tai-chinh.pdf")),
        ClipboardEntry(id: 3, kind: .text, createdAt: Date(), sourceBundleID: "com.tinyspeck.slackmacgap", text: "Release notes v0.3.0"),
    ]
    picker.selectionIndex = 2
    picker.searchQuery = "bao-cao"
    check(String(picker.filteredEntries.count), "1", "PickerController filters by file name")
    check(String(picker.selectionIndex), "0", "PickerController resets selection on search")
    check(picker.handleEscape() ? "close" : "clear", "clear", "PickerController first Esc clears searchQuery")
    check(String(picker.filteredEntries.count), "3", "PickerController restores entries after clearing query")
    check(picker.handleEscape() ? "close" : "clear", "close", "PickerController second Esc closes panel")
}

if failures.isEmpty {
    print("KeyVSmoke: ALL PASS (engine + UniKey parity + updater + host settings & UI regressions)")
} else {
    for f in failures { print("FAIL: \(f)") }
    exit(1)
}
