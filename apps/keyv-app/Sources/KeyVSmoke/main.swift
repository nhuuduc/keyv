import Foundation
import Carbon.HIToolbox
import CoreGraphics
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

private func keyCodeForASCII(_ ch: Character) -> CGKeyCode {
    switch ch.lowercased() {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "h": return 4
    case "g": return 5
    case "z": return 6
    case "x": return 7
    case "c": return 8
    case "v": return 9
    case "b": return 11
    case "q": return 12
    case "w": return 13
    case "e": return 14
    case "r": return 15
    case "y": return 16
    case "t": return 17
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "6": return 22
    case "5": return 23
    case "9": return 25
    case "7": return 26
    case "8": return 28
    case "0": return 29
    case "o": return 31
    case "u": return 32
    case "i": return 34
    case "p": return 35
    case "l": return 37
    case "j": return 38
    case "k": return 40
    case "n": return 45
    case "m": return 46
    case ".": return 47
    case " ": return 49
    default: return 0
    }
}

private func makeHardwareKeyEvent(
    _ ch: Character,
    keyDown: Bool,
    timestamp: UInt64,
    autorepeat: Int64 = 0,
    flags: CGEventFlags = []
) -> CGEvent {
    let src = CGEventSource(stateID: .hidSystemState)
    let kc = keyCodeForASCII(ch)
    let ev = CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: keyDown)!
    if !flags.isEmpty {
        ev.flags.formUnion(flags)
    }
    ev.timestamp = timestamp
    ev.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
    let units = Array(String(ch).utf16)
    ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    return ev
}

private func simulateFastRolloverBurst(
    _ input: String,
    bundleID: String,
    initialBuffer: String = "",
    initialAutocompleteSuffix: String = "",
    orthography: ViOrthography = .modern
) -> (text: String, emitted: [EventInjector.EmittedEvent], leakedConsumedKeyUps: Int) {
    let engine = ViEngine(method: .telex, orthography: orthography, allowWAsConsonant: true)
    engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
    let injector = EventInjector(compatFixEnabled: true)
    let tap = TapController(engine: engine, injector: injector)
    tap.activeBundleID = bundleID
    tap.activePID = 4242
    tap.isSecureInputActive = false

    var buffer = initialBuffer
    var selectedSuffix = initialAutocompleteSuffix
    var emitted: [EventInjector.EmittedEvent] = []

    let applyDeleteBackward = {
        if !selectedSuffix.isEmpty {
            selectedSuffix = ""
        } else if !buffer.isEmpty {
            buffer.removeLast()
        }
    }
    let applyInsert = { (str: String) in
        selectedSuffix = ""
        buffer += str
    }

    injector.eventSink = { item in
        emitted.append(item)
        switch item {
        case .virtualKey(let kc, let keyDown, _, _):
            if keyDown && kc == 51 {
                applyDeleteBackward()
            }
        case .unicode(let units, let keyDown, _, _):
            if keyDown {
                applyInsert(String(decoding: units, as: UTF16.self))
            }
        }
    }

    var ts: UInt64 = 1_000_000_000
    var pendingKeyUps: [(Character, Bool)] = []
    var leakedConsumedKeyUps = 0

    for (idx, ch) in input.enumerated() {
        while let existingIdx = pendingKeyUps.firstIndex(where: { $0.0 == ch }) {
            let (upCh, consumed) = pendingKeyUps.removeFirst()
            ts += 1_000_000
            let up = makeHardwareKeyEvent(upCh, keyDown: false, timestamp: ts)
            let passedUp = tap.processEventForTesting(type: .keyUp, event: up)
            if consumed && passedUp != nil {
                leakedConsumedKeyUps += 1
            }
            if existingIdx == 0 { break }
        }
        ts += 5_000_000
        let down = makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)
        let passed = tap.processEventForTesting(type: .keyDown, event: down)
        let wasConsumed = (passed == nil)
        if let passed {
            applyInsert(passed.keyboardString())
        }
        pendingKeyUps.append((ch, wasConsumed))

        if pendingKeyUps.count >= 3 || idx == input.count - 1 {
            while !pendingKeyUps.isEmpty {
                let (upCh, consumed) = pendingKeyUps.removeFirst()
                ts += 1_000_000
                let up = makeHardwareKeyEvent(upCh, keyDown: false, timestamp: ts)
                let passedUp = tap.processEventForTesting(type: .keyUp, event: up)
                if consumed && passedUp != nil {
                    leakedConsumedKeyUps += 1
                }
            }
        }
    }

    return (buffer + selectedSuffix, emitted, leakedConsumedKeyUps)
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

// Real-world fast Vietnamese + English cases
check(screen("hayx", method: .telex, orthography: .modern, spellCheck: true), "hãy", "fast hayx modern")
check(screen("haxy", method: .telex, orthography: .modern, spellCheck: true), "hãy", "fast haxy modern")
check(
    screen("lene tene nhana dana cono mono hono mama ddeme theme totos motoj matas ddatas nhatas tiengse chuyener duongwfd dand", method: .telex, spellCheck: true),
    "lên tên nhân dân côn môn hôn mâm đêm thêm tốt một mất đất nhất tiếng chuyển đường đan",
    "delayed Telex circumflex/horn/stroke Vietnamese words"
)
check(
    screen("lenee memee monoo dadd", method: .telex, spellCheck: true),
    "lene meme mono dad",
    "double-key escape restores ASCII words"
)
check(
    screen("todo haha banana canada server terminal docker github testing window chrome safari data photo ", method: .telex, spellCheck: true),
    "todo haha banana canada server terminal docker github testing window chrome safari data photo ",
    "non-Vietnamese phonotactic and stop-coda word-boundary auto-restore"
)
check(screen("tesst", method: .telex, spellCheck: true), "test", "tesst escape to test")
check(screen("tests", method: .telex, spellCheck: true), "tests", "tests restores English")
check(screen("tester", method: .telex, spellCheck: true), "tester", "tester restores English")
check(screen("testing", method: .telex, spellCheck: true), "testing", "testing restores English")
check(screen("next text west web wifi work world w", method: .telex, spellCheck: true), "next text west web wifi work world w", "English + w words")
check(screen("raw saw law rawng sawts ", method: .telex, spellCheck: true), "raw saw law răng sắt ", "open breve English vs closed breve Vietnamese")

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

// Fast-typing TapController + EventInjector rollover & race regression suite
do {
    let orcaHayx = simulateFastRolloverBurst("hayx", bundleID: "com.stablyai.orca")
    check(orcaHayx.text, "hãy", "TapController fast rollover hayx in Electron/Orca")
    check(String(orcaHayx.leakedConsumedKeyUps), "0", "TapController swallows consumed keyUp in hayx")
    let unicodeEventsHayx = orcaHayx.emitted.compactMap { ev -> [UniChar]? in
        if case .unicode(let units, true, _, _) = ev { return units }
        return nil
    }
    check(String(unicodeEventsHayx.count), "2", "EventInjector emits 1 Character per CGEvent for ãy")
    let preserved20000000 = orcaHayx.emitted.allSatisfy { ev in
        switch ev {
        case .virtualKey(_, _, let flags, _), .unicode(_, _, let flags, _):
            return (flags & 0x2000_0000) != 0
        }
    }
    check(preserved20000000 ? "ok" : "wiped", "ok", "EventInjector preserves 0x20000000 CGEvent flag")

    var monotonicOK = true
    var prevTS: UInt64 = 0
    for ev in orcaHayx.emitted {
        let ts: UInt64 = switch ev {
        case .virtualKey(_, _, _, let t), .unicode(_, _, _, let t): t
        }
        if ts <= prevTS { monotonicOK = false }
        prevTS = ts
    }
    check(monotonicOK ? "ok" : "bad", "ok", "EventInjector stamps strictly monotonic timestamps")

    let orcaHaxy = simulateFastRolloverBurst("haxy", bundleID: "com.stablyai.orca")
    check(orcaHaxy.text, "hãy", "TapController fast rollover haxy serializes trailing y")
    check(String(orcaHaxy.leakedConsumedKeyUps), "0", "TapController swallows consumed keyUp in haxy")
    let unicodeEventsHaxy = orcaHaxy.emitted.compactMap { ev -> String? in
        if case .unicode(let units, true, _, _) = ev { return String(decoding: units, as: UTF16.self) }
        return nil
    }
    check(unicodeEventsHaxy.joined(separator: "|"), "ã|y", "TapController serializes post-replace Pass y after ã")

    let chromePlain = simulateFastRolloverBurst("hayx gox tieengs Vieetj nhanh", bundleID: "com.google.Chrome")
    check(chromePlain.text, "hãy gõ tiếng Việt nhanh", "Browser compat U+202F burst with no selection")

    let delayedAndBoundaryBurst = simulateFastRolloverBurst(
        "lene tene nhana mono dand data photo ",
        bundleID: "com.stablyai.orca"
    )
    check(
        delayedAndBoundaryBurst.text,
        "lên tên nhân môn đan data photo ",
        "TapController FIFO serializes delayed Telex + stop-coda boundary restore"
    )
    check(
        String(delayedAndBoundaryBurst.leakedConsumedKeyUps),
        "0",
        "TapController swallows consumed keyUp in delayed/boundary burst"
    )

    do {
        let engine = ViEngine(method: .telex, orthography: .modern, allowWAsConsonant: true)
        engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
        let injector = EventInjector(compatFixEnabled: true)
        let tap = TapController(engine: engine, injector: injector)
        tap.activeBundleID = "com.google.Chrome"
        tap.isSecureInputActive = false

        var omniboxBuf = ""
        var omniboxAuto = ""
        injector.eventSink = { item in
            switch item {
            case .virtualKey(51, true, _, _):
                if !omniboxAuto.isEmpty { omniboxAuto = "" }
                else if !omniboxBuf.isEmpty { omniboxBuf.removeLast() }
            case .unicode(let u, true, _, _):
                omniboxAuto = ""
                omniboxBuf += String(decoding: u, as: UTF16.self)
            default:
                break
            }
        }
        for ch in "hay" {
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: 1_000)) {
                omniboxBuf += p.keyboardString()
            }
        }
        omniboxAuto = "stack.com"
        _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("x", keyDown: true, timestamp: 2_000))
        check(omniboxBuf + omniboxAuto, "hãy", "Browser omnibox active autocomplete selection replaced cleanly via U+202F")
    }

    let ghosttyBurst = simulateFastRolloverBurst("hayx dduowcj tests w", bundleID: "com.mitchellh.ghostty")
    check(ghosttyBurst.text, "hãy được tests w", "Terminal bundle ID skips autocomplete spacer")
    let hasSpacerInTerminal = ghosttyBurst.emitted.contains { ev in
        if case .unicode(let u, true, _, _) = ev {
            return u == [0x202F] || u == [0x200C]
        }
        return false
    }
    check(hasSpacerInTerminal ? "bad" : "ok", "ok", "Terminal never receives U+202F or U+200C")

    do {
        let engine = ViEngine(method: .telex, orthography: .traditional, allowWAsConsonant: true)
        engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
        let injector = EventInjector(compatFixEnabled: false)
        var injectedCount = 0
        injector.eventSink = { _ in injectedCount += 1 }
        let tap = TapController(engine: engine, injector: injector)
        tap.isSecureInputActive = false

        _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("a", keyDown: true, timestamp: 100))
        let repeatEv = makeHardwareKeyEvent("a", keyDown: true, timestamp: 200, autorepeat: 1)
        let repeatOut = tap.processEventForTesting(type: .keyDown, event: repeatEv)
        check(repeatOut != nil && injectedCount == 0 ? "ok" : "bad", "ok", "Autorepeat passes through without triggering aa->â")

        _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("t", keyDown: true, timestamp: 300))
        _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("a", keyDown: true, timestamp: 400))
        let fnF = makeHardwareKeyEvent("f", keyDown: true, timestamp: 500, flags: .maskSecondaryFn)
        let fnOut = tap.processEventForTesting(type: .keyDown, event: fnF)
        check(fnOut != nil && injectedCount == 0 ? "ok" : "bad", "ok", "Fn+F system shortcut passes through without applying huyền tone")
    }
}

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
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  KeyV-0.3.1-macos-universal.zip
    fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 *KeyV-0.3.1-macos-universal.dmg
    """
    check(
        UpdateVerification.parseSHA256Sums(sums, assetName: "KeyV-0.3.1-macos-universal.zip") ?? "",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "SHA256SUMS zip lookup"
    )
    check(
        UpdateVerification.parseSHA256Sums(sums, assetName: "KeyV-0.3.1-macos-universal.dmg") ?? "",
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

    let migrationSuiteName = "app.keyv.smoke.migration.\(ProcessInfo.processInfo.processIdentifier)"
    if let migrationStore = UserDefaults(suiteName: migrationSuiteName) {
        migrationStore.removePersistentDomain(forName: migrationSuiteName)
        migrationStore.set(false, forKey: "allowWAsConsonant")
        migrationStore.set(false, forKey: "repeatedRestore")
        migrationStore.set(false, forKey: "spellCheck")
        AppSettings.shared.migrateLegacyDefaultsIfNeeded(in: migrationStore)
        check(
            migrationStore.bool(forKey: "allowWAsConsonant")
                && migrationStore.bool(forKey: "repeatedRestore")
                && migrationStore.bool(forKey: "spellCheck")
                && migrationStore.integer(forKey: "settingsSchemaVersion") == AppSettings.currentSchemaVersion
                ? "ok" : "bad",
            "ok",
            "Legacy schema v0 settings migrate broken false flags to true"
        )
        migrationStore.removePersistentDomain(forName: migrationSuiteName)
    }

    let model = SettingsModel()
    check(String(model.method.rawValue), "1", "fresh install defaults to Telex")
    check(model.spellCheck ? "true" : "false", "true", "fresh install enables spellCheck")
    check(model.allowWAsConsonant ? "true" : "false", "true", "fresh install enables allowWAsConsonant")
    check(model.repeatedRestore ? "true" : "false", "true", "fresh install enables repeatedRestore")
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
        ClipboardEntry(id: 3, kind: .text, createdAt: Date(), sourceBundleID: "com.tinyspeck.slackmacgap", text: "Release notes v0.3.1"),
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
    print("KeyVSmoke: ALL PASS (engine + fast-typing rollover + UniKey parity + updater + host settings & UI regressions)")
} else {
    for f in failures { print("FAIL: \(f)") }
    exit(1)
}
