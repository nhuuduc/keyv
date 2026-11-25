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
    case "?": return 44
    case "!": return 18
    case "@": return 19
    case ":": return 41
    case "\r", "\n": return 36
    case "\t": return 48
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
    for ch in "ddawng ddk hvbt " {
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
    check(cursor, "đăng đăng ký nhé bạn ", "macro FFI + telex coexistence")
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

    do {
        let engine = ViEngine(method: .telex, orthography: .modern, allowWAsConsonant: true)
        engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
        let injector = EventInjector(compatFixEnabled: true)
        let tap = TapController(engine: engine, injector: injector)
        tap.activeBundleID = "com.tinyspeck.slackmacgap"
        tap.activePID = 9001
        tap.isSecureInputActive = false

        var chatBuf = ""
        injector.eventSink = { item in
            switch item {
            case .virtualKey(let kc, true, _, _):
                if kc == 51 && !chatBuf.isEmpty { chatBuf.removeLast() }
                if kc == 36 || kc == 76 { chatBuf += "<ENTER>" }
                if kc == 48 { chatBuf += "<TAB>" }
            case .unicode(let u, true, _, _):
                chatBuf += String(decoding: u, as: UTF16.self)
            default:
                break
            }
        }

        var ts: UInt64 = 10_000
        for ch in "data" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        injector.clearRecordedClonedKeys()
        let shiftEnter = makeHardwareKeyEvent("\r", keyDown: true, timestamp: ts, flags: .maskShift)
        let passedShiftEnter = tap.processEventForTesting(type: .keyDown, event: shiftEnter)
        check(passedShiftEnter == nil ? "consumed" : "leaked", "consumed", "Shift+Return after incomplete Vietnamese word is serialized")
        check(chatBuf, "data<ENTER>", "Return triggers word-boundary restoration (dât -> data) before Enter")
        let downShiftEnter = injector.recordedClonedKeys.first { $0.keyDown }
        let keptKeyCode36 = downShiftEnter?.keyCode == 36
        let keptShiftFlag = ((downShiftEnter?.flags ?? 0) & CGEventFlags.maskShift.rawValue) != 0
        check(keptKeyCode36 && keptShiftFlag ? "ok" : "bad", "ok", "Shift+Return preserves keyCode 36 and .maskShift flag")

        chatBuf = ""
        for ch in "photo" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        injector.clearRecordedClonedKeys()
        let src = CGEventSource(stateID: .hidSystemState)
        let kpEnter = CGEvent(keyboardEventSource: src, virtualKey: 76, keyDown: true)!
        kpEnter.flags.formUnion(.maskNumericPad)
        kpEnter.timestamp = ts
        kpEnter.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0003])
        _ = tap.processEventForTesting(type: .keyDown, event: kpEnter)
        check(chatBuf, "photo<ENTER>", "KeypadEnter (76 + .maskNumericPad) triggers word-boundary restoration")
        check(injector.recordedClonedKeys.first(where: { $0.keyDown })?.keyCode == 76 ? "ok" : "bad", "ok", "KeypadEnter preserves keyCode 76")

        chatBuf = ""
        for ch in "raw" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        injector.clearRecordedClonedKeys()
        let tabEv = makeHardwareKeyEvent("\t", keyDown: true, timestamp: ts)
        _ = tap.processEventForTesting(type: .keyDown, event: tabEv)
        check(chatBuf, "raw<TAB>", "Tab triggers word-boundary restoration (ră -> raw)")
        check(injector.recordedClonedKeys.first(where: { $0.keyDown })?.keyCode == 48 ? "ok" : "bad", "ok", "Tab preserves keyCode 48")

        chatBuf = ""
        for ch in "nhes" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        injector.clearRecordedClonedKeys()
        let spaceEv = makeHardwareKeyEvent(" ", keyDown: true, timestamp: ts)
        _ = tap.processEventForTesting(type: .keyDown, event: spaceEv)
        let clonedSpace = injector.recordedClonedKeys.first { $0.keyDown }
        check(clonedSpace?.keyCode == 49 ? "ok" : "bad", "ok", "Post-replace Space preserves physical keyCode 49")

        chatBuf = ""
        for ch in "ddc" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        injector.clearRecordedClonedKeys()
        let qEv = makeHardwareKeyEvent("?", keyDown: true, timestamp: ts, flags: .maskShift)
        if let p = tap.processEventForTesting(type: .keyDown, event: qEv) {
            chatBuf += p.keyboardString()
        }
        check(chatBuf, "đc?", "Vietnamese shorthand đc? in chat")
        if let clonedQ = injector.recordedClonedKeys.first(where: { $0.keyDown }) {
            let okQ = clonedQ.keyCode == 44 && (clonedQ.flags & CGEventFlags.maskShift.rawValue) != 0
            check(okQ ? "ok" : "bad", "ok", "Shifted '?' preserves keyCode 44 and .maskShift")
        }

        chatBuf = ""
        for ch in "tieen" {
            ts += 1_000
            if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                chatBuf += p.keyboardString()
            }
        }
        ts += 1_000
        let optBS = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)!
        optBS.flags.formUnion(.maskAlternate)
        optBS.timestamp = ts
        let optBSOut = tap.processEventForTesting(type: .keyDown, event: optBS)
        check(optBSOut != nil ? "ok" : "bad", "ok", "Option+Backspace passes through to target app")
        chatBuf = ""
        ts += 1_000
        if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("s", keyDown: true, timestamp: ts)) {
            chatBuf += p.keyboardString()
        }
        check(chatBuf, "s", "Option+Backspace resets engine buffer so 's' does not apply tone to deleted word")

        for ch in "dduow" {
            ts += 1_000
            _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts))
        }
        ts += 1_000
        let cmdBS = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)!
        cmdBS.flags.formUnion(.maskCommand)
        cmdBS.timestamp = ts
        _ = tap.processEventForTesting(type: .keyDown, event: cmdBS)
        chatBuf = ""
        ts += 1_000
        if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent("f", keyDown: true, timestamp: ts)) {
            chatBuf += p.keyboardString()
        }
        check(chatBuf, "f", "Cmd+Backspace resets engine buffer cleanly")

        var sawSpacerInSlack = false
        var webChatEmitted: [EventInjector.EmittedEvent] = []
        injector.compatSpacerOverrideForTesting = { _, _ in false }
        injector.eventSink = { ev in
            webChatEmitted.append(ev)
            if case .unicode(let u, true, _, _) = ev, u == [0x202F] {
                sawSpacerInSlack = true
            }
        }
        tap.activeBundleID = "com.google.Chrome"
        engine.reset()
        for ch in "hayx" {
            ts += 1_000
            _ = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts))
        }
        check(!sawSpacerInSlack && !webChatEmitted.isEmpty ? "ok" : "bad", "ok", "Browser AXWebArea chat skips U+202F narrow no-break space")
    }
}

do {
    var resolverCalls = 0
    let detector = RemoteInputDetector { pid in
        resolverCalls += 1
        switch pid {
        case 77_001:
            return ProcessInspectorMetadata(
                bundleID: "com.carriez.rustdesk",
                executablePath: "/Applications/RustDesk.app/Contents/MacOS/RustDesk"
            )
        case 77_002:
            return ProcessInspectorMetadata(
                bundleID: nil,
                executablePath: "/Applications/RustDesk.app/Contents/MacOS/service"
            )
        case 77_003:
            return ProcessInspectorMetadata(
                bundleID: "com.apple.WebKit.WebContent",
                executablePath: "/Users/dev/orca/workspaces/keyv/feat-rustdesk-remote-input/com.apple.WebKit.WebContent"
            )
        default:
            return ProcessInspectorMetadata(bundleID: "com.apple.Terminal", executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        }
    }

    let baseNs: UInt64 = 10_000_000_000
    check(detector.sourceKind(for: 0, nowNs: baseNs) == .local ? "ok" : "bad", "ok", "RemoteInputDetector pid 0 fast-paths to .local")
    check(detector.sourceKind(for: getpid(), nowNs: baseNs) == .local ? "ok" : "bad", "ok", "RemoteInputDetector self PID fast-paths to .local")
    check(String(resolverCalls), "0", "RemoteInputDetector zero syscalls for pid 0 and self PID")

    for i in 0..<1_000 {
        let kind = detector.sourceKind(for: 77_001, nowNs: baseNs + UInt64(i) * 1_000)
        if kind != .rustDesk {
            failures.append("RemoteInputDetector expected .rustDesk at iteration \(i)")
            break
        }
    }
    check(String(resolverCalls), "1", "RemoteInputDetector caches PID lookup across 1000 events")
    check(detector.sourceKind(for: 77_002, nowNs: baseNs) == .rustDesk ? "ok" : "bad", "ok", "RemoteInputDetector recognizes RustDesk root helper path")
    check(detector.sourceKind(for: 77_003, nowNs: baseNs) == .local ? "ok" : "bad", "ok", "RemoteInputDetector ignores workspace folder substring false positive")
    check(detector.sourceKind(for: 77_001, nowNs: baseNs + 61_000_000_000) == .rustDesk && resolverCalls == 4 ? "ok" : "bad", "ok", "RemoteInputDetector refreshes entry after cache TTL")

    check(RemoteInputDetector.classify(bundleID: "com.carriez.rustdesk") == .rustDesk ? "ok" : "bad", "ok", "classify RustDesk bundle")
    check(RemoteInputDetector.classify(bundleID: "com.philandro.anydesk") == .anyDesk ? "ok" : "bad", "ok", "classify AnyDesk bundle")
    check(RemoteInputDetector.classify(bundleID: "com.teamviewer.TeamViewer") == .teamViewer ? "ok" : "bad", "ok", "classify TeamViewer bundle")
    check(RemoteInputDetector.classify(processName: "screensharingd") == .screenSharing ? "ok" : "bad", "ok", "classify screensharingd daemon")
    check(RemoteInputDetector.classify(processName: "ARDAgent") == .screenSharing ? "ok" : "bad", "ok", "classify ARDAgent")
    check(RemoteInputDetector.classify(bundleID: "tv.parsec.www") == .parsec ? "ok" : "bad", "ok", "classify Parsec")
    check(RemoteInputDetector.classify(bundleID: "com.p5sys.jump.connect") == .jumpDesktop ? "ok" : "bad", "ok", "classify Jump Desktop Connect")
    check(RemoteInputDetector.classify(processName: "remoting_me2me_host") == .chromeRemoteDesktop ? "ok" : "bad", "ok", "classify Chrome Remote Desktop")
    check(RemoteInputDetector.classify(processName: "sunshine") == .moonlightSunshine ? "ok" : "bad", "ok", "classify Sunshine")

    let rustDeskPID: pid_t = 77_001

    func makeRemoteUnicodeEvent(
        _ text: String,
        virtualKey: CGKeyCode = 0,
        keyDown: Bool = true,
        timestamp: UInt64,
        flags: CGEventFlags = [],
        pid: pid_t = rustDeskPID
    ) -> CGEvent {
        let src = CGEventSource(stateID: .hidSystemState)
        let ev = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: keyDown)!
        if !flags.isEmpty {
            ev.flags.formUnion(flags)
        }
        ev.timestamp = timestamp
        ev.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(pid))
        let units = Array(text.utf16)
        if !units.isEmpty {
            ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        return ev
    }

    func makeRemoteHarness(mode: RemoteDesktopMode, bundleID: String = "com.google.Chrome") -> (
        tap: TapController,
        injector: EventInjector,
        readScreen: () -> String,
        clearScreen: () -> Void,
        sendRemote: (_ text: String, _ virtualKey: CGKeyCode, _ timestamp: UInt64, _ flags: CGEventFlags) -> CGEvent?,
        sendLocal: (_ ch: Character, _ timestamp: UInt64) -> Void,
        emittedEvents: () -> [EventInjector.EmittedEvent]
    ) {
        let engine = ViEngine(method: .telex, orthography: .modern, allowWAsConsonant: true)
        engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
        let injector = EventInjector(compatFixEnabled: true)
        let tap = TapController(engine: engine, injector: injector, remoteDetector: detector)
        tap.remoteDesktopMode = mode
        tap.activeBundleID = bundleID
        tap.activePID = 5150
        tap.isSecureInputActive = false

        var screenBuf = ""
        var emitted: [EventInjector.EmittedEvent] = []

        let applyDelete = {
            if !screenBuf.isEmpty { screenBuf.removeLast() }
        }

        injector.eventSink = { item in
            emitted.append(item)
            switch item {
            case .virtualKey(let kc, true, _, _):
                if kc == 51 { applyDelete() }
                else if kc == 36 || kc == 76 { screenBuf += "<ENTER>" }
                else if kc == 48 { screenBuf += "<TAB>" }
            case .unicode(let u, true, _, _):
                screenBuf += String(decoding: u, as: UTF16.self)
            default:
                break
            }
        }

        let sendRemote = { (text: String, vk: CGKeyCode, ts: UInt64, flags: CGEventFlags) -> CGEvent? in
            let down = makeRemoteUnicodeEvent(text, virtualKey: vk, keyDown: true, timestamp: ts, flags: flags)
            let passed = tap.processEventForTesting(type: .keyDown, event: down)
            if let passed {
                let s = passed.keyboardString()
                if vk == 51 || s == "\u{0008}" || s == "\u{007F}" {
                    applyDelete()
                } else if vk == 36 || vk == 76 || s == "\r" || s == "\n" || s == "\r\n" {
                    screenBuf += "<ENTER>"
                } else if vk == 48 || s == "\t" {
                    screenBuf += "<TAB>"
                } else {
                    screenBuf += s
                }
            }
            let up = makeRemoteUnicodeEvent(text, virtualKey: vk, keyDown: false, timestamp: ts + 100, flags: flags)
            _ = tap.processEventForTesting(type: .keyUp, event: up)
            return passed
        }

        let sendLocal = { (ch: Character, ts: UInt64) in
            let down = makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)
            if let passed = tap.processEventForTesting(type: .keyDown, event: down) {
                screenBuf += passed.keyboardString()
            }
            let up = makeHardwareKeyEvent(ch, keyDown: false, timestamp: ts + 100)
            _ = tap.processEventForTesting(type: .keyUp, event: up)
        }

        return (
            tap,
            injector,
            { screenBuf },
            { screenBuf = ""; emitted.removeAll(); engine.reset() },
            sendRemote,
            sendLocal,
            { emitted }
        )
    }

    do {
        let h = makeRemoteHarness(mode: .smartAuto)
        var ts: UInt64 = 5_000_000_000
        _ = h.sendRemote("v", 0, ts, []); ts += 40_000_000
        _ = h.sendRemote("i", 0, ts, []); ts += 40_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 2_000_000
        _ = h.sendRemote("ệ", 0, ts, []); ts += 40_000_000
        _ = h.sendRemote("t", 0, ts, []); ts += 40_000_000
        _ = h.sendRemote("s", 0, ts, []); ts += 40_000_000
        check(h.readScreen(), "vệts", "SmartAuto mobile precomposed 'v','i',[BS],'ệ','t','s' never hijacks trailing 't' or 's'")

        _ = h.sendRemote(" ", 0, ts, []); ts += 40_000_000
        for ch in "hayx" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 40_000_000
        }
        check(h.readScreen(), "vệts hãy", "SmartAuto resumes Telex cleanly on next word after space")

        h.clearScreen()
        _ = h.sendRemote("t", 0, ts, []); ts += 30_000_000
        _ = h.sendRemote("e\u{0302}", 0, ts, []); ts += 30_000_000
        _ = h.sendRemote("t", 0, ts, []); ts += 30_000_000
        _ = h.sendRemote("s", 0, ts, []); ts += 30_000_000
        check(h.readScreen(), "te\u{0302}ts", "SmartAuto NFD combining vowel suppresses mid-word Telex hijack")
    }

    do {
        let h = makeRemoteHarness(mode: .smartAuto)
        var ts: UInt64 = 6_000_000_000
        let commitOut = h.sendRemote("xin chào", 0, ts, [])
        check(commitOut != nil ? "ok" : "bad", "ok", "Multi-UTF16 mobile word commit passes through untouched")
        ts += 20_000_000
        _ = h.sendRemote(" ", 0, ts, []); ts += 20_000_000
        for ch in "banj" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 20_000_000
        }
        check(h.readScreen(), "xin chào bạn", "Multi-UTF16 mobile word commit coexists with subsequent Telex")

        h.clearScreen()
        for ch in "tah" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 35_000_000
        }
        _ = h.sendRemote("", 51, ts, []); ts += 2_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 2_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 5_000_000
        for ch in "task" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 2_000_000
        }
        check(h.readScreen(), "task", "Mobile rapid Backspace burst (<15ms) resets engine and passes ASCII autocorrect untouched")

        h.clearScreen()
        for ch in "nhuw" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 15_000_000
        }
        _ = h.sendRemote("", 51, ts, []); ts += 2_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 2_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 5_000_000
        for ch in "soos" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 5_000_000
        }
        check(h.readScreen(), "số", "Rapid Backspace burst followed immediately by 'soos' composes 'số' instead of literal 'soos'")
    }

    do {
        let h = makeRemoteHarness(mode: .smartAuto)
        var ts: UInt64 = 7_000_000_000
        for ch in "banj" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 25_000_000
        }
        check(h.readScreen(), "bạn", "RustDesk Translate mode keyCode==0 with 'b' uses UnicodeString instead of kVK_ANSI_A")

        let nlPass = h.sendRemote("\n", 0, ts, [])
        ts += 100_000_000
        h.clearScreen()
        _ = h.sendRemote("b", 0, ts, []); ts += 25_000_000
        let untouchedNL = h.sendRemote("\n", 0, ts, [])
        check(untouchedNL != nil ? "ok" : "bad", "ok", "keyCode==0 '\\n' without active transform passes original CGEvent untouched")
        check(h.readScreen(), "b<ENTER>", "keyCode==0 '\\n' normalizes as Return delimiter")
        _ = nlPass

        h.clearScreen()
        for ch in "data" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 25_000_000
        }
        _ = h.sendRemote("\n", 0, ts, [])
        ts += 25_000_000
        check(h.readScreen(), "data<ENTER>", "keyCode==0 '\\n' triggers incomplete Vietnamese word restoration before Return")

        h.clearScreen()
        ts += 100_000_000
        for ch in "tieep" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 30_000_000
        }
        ts += 100_000_000
        let delPass = h.sendRemote("\u{007F}", 0, ts, [])
        check(delPass != nil ? "ok" : "bad", "ok", "keyCode==0 '\\u{7f}' passes original CGEvent when outside post-replace window")
        ts += 40_000_000
        _ = h.sendRemote("n", 0, ts, []); ts += 30_000_000
        _ = h.sendRemote("g", 0, ts, []); ts += 30_000_000
        _ = h.sendRemote("s", 0, ts, []); ts += 30_000_000
        check(h.readScreen(), "tiếng", "keyCode==0 '\\u{7f}' updates engine backspace state accurately")
    }

    do {
        let h = makeRemoteHarness(mode: .phoneKeyboardOnly)
        var ts: UInt64 = 8_000_000_000
        for ch in "hayx dduowcj " {
            _ = h.sendRemote(String(ch), keyCodeForASCII(ch), ts, [])
            ts += 10_000_000
        }
        check(h.readScreen(), "hayx dduowcj ", "phoneKeyboardOnly passes 100% of RustDesk keys untouched")

        for ch in "hayx dduowcj" {
            h.sendLocal(ch, ts)
            ts += 10_000_000
        }
        check(h.readScreen(), "hayx dduowcj hãy được", "phoneKeyboardOnly keeps local Mac hardware keyboard composing Vietnamese")
    }

    for mode in [RemoteDesktopMode.smartAuto, .alwaysKeyV] {
        let hRaw = makeRemoteHarness(mode: mode, bundleID: "com.google.Chrome")
        let burstInput = "hayx dduowcj case ddc "
        let baseBurstTs: UInt64 = 9_000_000_000
        var leakedZeroKeyUps = 0

        for ch in burstInput {
            let vk = keyCodeForASCII(ch)
            _ = hRaw.sendRemote(String(ch), vk, baseBurstTs, [.maskAlphaShift])
        }
        check(
            hRaw.readScreen(),
            "hãy được case đc ",
            "0ms packet-burst raw-keycode Telex in \(mode)"
        )
        let hadRemoteBrowserSpacer = hRaw.emittedEvents().contains { ev in
            if case .unicode(let u, true, _, _) = ev {
                return u == [0x202F]
            }
            return false
        }
        check(hadRemoteBrowserSpacer ? "bad" : "ok", "ok", "Remote burst in Chrome skips unnecessary U+202F spacer (\(mode))")

        let hZero = makeRemoteHarness(mode: mode, bundleID: "com.stablyai.orca")
        var pendingZeroUps = 0
        for ch in burstInput {
            let down = makeRemoteUnicodeEvent(
                String(ch),
                virtualKey: 0,
                keyDown: true,
                timestamp: baseBurstTs,
                flags: [.maskSecondaryFn, .maskNumericPad, .maskAlphaShift]
            )
            let passed = hZero.tap.processEventForTesting(type: .keyDown, event: down)
            if passed == nil {
                pendingZeroUps += 1
            } else if let passed {
                let up = makeRemoteUnicodeEvent(String(ch), virtualKey: 0, keyDown: false, timestamp: baseBurstTs)
                _ = hZero.tap.processEventForTesting(type: .keyUp, event: up)
                _ = passed
            }
        }
        for _ in 0..<pendingZeroUps {
            let up = makeRemoteUnicodeEvent("a", virtualKey: 0, keyDown: false, timestamp: baseBurstTs)
            if hZero.tap.processEventForTesting(type: .keyUp, event: up) != nil {
                leakedZeroKeyUps += 1
            }
        }
        check(String(leakedZeroKeyUps), "0", "0ms overlapping keyCode==0 burst swallows all consumed keyUps (\(mode))")

        let hZeroSeq = makeRemoteHarness(mode: mode, bundleID: "com.stablyai.orca")
        for ch in burstInput {
            _ = hZeroSeq.sendRemote(String(ch), 0, baseBurstTs, [.maskSecondaryFn, .maskNumericPad, .maskAlphaShift])
        }
        check(
            hZeroSeq.readScreen(),
            "hãy được case đc ",
            "0ms packet-burst keyCode==0 Telex with stuck remote flags stripped in \(mode)"
        )
        let leakedStuckFlags = hZeroSeq.emittedEvents().contains { ev in
            let flags: UInt64 = switch ev {
            case .virtualKey(_, _, let f, _), .unicode(_, _, let f, _): f
            }
            let mask = CGEventFlags.maskSecondaryFn.rawValue
                | CGEventFlags.maskNumericPad.rawValue
                | CGEventFlags.maskAlphaShift.rawValue
            return (flags & mask) != 0
        }
        check(leakedStuckFlags ? "bad" : "ok", "ok", "Synthetic & cloned events strip stuck remote modifier flags (\(mode))")
    }

    check(
        detector.sourceKind(
            for: 99_999,
            eventUserData: RemoteInputDetector.rustDeskEnigoUserData,
            nowNs: baseNs
        ) == .rustDesk ? "ok" : "bad",
        "ok",
        "RemoteInputDetector ENIGO_INPUT_EXTRA_VALUE (100) fallback identifies RustDesk root daemon"
    )

    for mode in RemoteDesktopMode.allCases {
        let h = makeRemoteHarness(mode: mode, bundleID: "ru.keepcoder.Telegram")
        let sendKeySequence = { (seq: String, startTs: UInt64) -> UInt64 in
            var cur = startTs
            for ch in seq {
                let ev = makeRemoteUnicodeEvent(String(ch), virtualKey: 0, keyDown: true, timestamp: cur)
                ev.setIntegerValueField(.eventSourceUserData, value: RemoteInputDetector.rustDeskEnigoUserData)
                if let passed = h.tap.processEventForTesting(type: .keyDown, event: ev) {
                    let s = passed.keyboardString()
                    _ = s
                }
                cur += 40_000
            }
            return cur
        }
        _ = sendKeySequence

        var ts: UInt64 = 12_000_000_000
        _ = h.sendRemote("d", 0, ts, []); ts += 60_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 100_000
        _ = h.sendRemote("", 51, ts, []); ts += 500_000
        _ = h.sendRemote("1", 0, ts, []); ts += 50_000
        _ = h.sendRemote("đ", 0, ts, []); ts += 80_000_000
        _ = h.sendRemote("u", 0, ts, []); ts += 80_000_000
        _ = h.sendRemote("o", 0, ts, []); ts += 80_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 100_000
        _ = h.sendRemote("", 51, ts, []); ts += 500_000
        _ = h.sendRemote("ư", 0, ts, []); ts += 50_000
        _ = h.sendRemote("ơ", 0, ts, []); ts += 80_000_000
        _ = h.sendRemote("c", 0, ts, []); ts += 80_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 100_000
        _ = h.sendRemote("", 51, ts, []); ts += 100_000
        _ = h.sendRemote("", 51, ts, []); ts += 500_000
        _ = h.sendRemote("ư", 0, ts, []); ts += 50_000
        _ = h.sendRemote("ợ", 0, ts, []); ts += 50_000
        _ = h.sendRemote("c", 0, ts, []); ts += 80_000_000
        check(
            h.readScreen(),
            "được",
            "RustDesk iOS VI EN '1' sentinel leak on dd->1đ produces clean 'được' in Telegram (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        for ch in "1được" {
            let down = makeRemoteUnicodeEvent(String(ch), virtualKey: 0, keyDown: true, timestamp: ts)
            down.setIntegerValueField(.eventSourceUserData, value: RemoteInputDetector.rustDeskEnigoUserData)
            if let passed = h.tap.processEventForTesting(type: .keyDown, event: down) {
                let s = passed.keyboardString()
                h.injector.eventSink?(.unicode(units: Array(s.utf16), keyDown: true, flags: 0, timestamp: ts))
            }
            ts += 40_000
        }
        check(
            h.readScreen(),
            "được",
            "RustDesk enigo::key_sequence('1được') keyDown-only grapheme stream strips sentinel '1' (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        _ = h.sendRemote("1được", 0, ts, [])
        check(
            h.readScreen(),
            "được",
            "RustDesk single-CGEvent '1được' strips sentinel '1' (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 1_000_000
        _ = h.sendRemote("1", 0, ts, []); ts += 50_000
        _ = h.sendRemote("d", 0, ts, []); ts += 90_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 500_000
        _ = h.sendRemote("đ", 0, ts, []); ts += 90_000_000
        _ = h.sendRemote("c", 0, ts, [])
        check(
            h.readScreen(),
            "đc",
            "RustDesk VK_BACK + '1d' ASCII sentinel leak strips '1' cleanly (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        for ch in "123 100đ" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 40_000
        }
        check(
            h.readScreen(),
            "123 100đ",
            "Intentional numbers '123 100đ' never lose '1' (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        for ch in "1abc234" {
            _ = h.sendRemote(String(ch), 0, ts, [])
            ts += 40_000
        }
        check(
            h.readScreen(),
            "1abc234",
            "Clipboard keystroke string '1abc234' without VK_BACK keeps '1' (\(mode))"
        )

        h.clearScreen()
        ts += 200_000_000
        _ = h.sendRemote("1", 0, ts, [])
        ts += 250_000_000
        _ = h.sendRemote("d", 0, ts, []); ts += 90_000_000
        _ = h.sendRemote("", 51, ts, []); ts += 500_000
        _ = h.sendRemote("đ", 0, ts, [])
        check(
            h.readScreen(),
            "1đ",
            "Human-paced '1' then 250ms later 'dd' ('1đ' = 1 đồng) preserves '1' (\(mode))"
        )
    }

    do {
        let hVIEN = makeRemoteHarness(mode: .smartAuto, bundleID: "ru.keepcoder.Telegram")
        var ts: UInt64 = 15_000_000_000
        _ = hVIEN.sendRemote("1", 0, ts, []); ts += 40_000
        for ch in "được " {
            _ = hVIEN.sendRemote(String(ch), 0, ts, []); ts += 40_000
        }
        ts += 100_000_000
        for ch in "tiếng việt hãy lên " {
            _ = hVIEN.sendRemote(String(ch), 0, ts, []); ts += 20_000_000
        }
        _ = hVIEN.sendRemote("c", 0, ts, []); ts += 30_000_000
        _ = hVIEN.sendRemote("a", 0, ts, []); ts += 30_000_000
        _ = hVIEN.sendRemote("", 51, ts, []); ts += 200_000
        _ = hVIEN.sendRemote("á", 0, ts, []); ts += 30_000_000
        _ = hVIEN.sendRemote("", 51, ts, []); ts += 200_000
        for ch in "ase " {
            _ = hVIEN.sendRemote(String(ch), 0, ts, []); ts += 50_000
        }
        _ = hVIEN.sendRemote("d", 0, ts, []); ts += 30_000_000
        _ = hVIEN.sendRemote("", 51, ts, []); ts += 200_000
        _ = hVIEN.sendRemote("đ", 0, ts, []); ts += 30_000_000
        _ = hVIEN.sendRemote("c", 0, ts, [])
        check(
            hVIEN.readScreen(),
            "được tiếng việt hãy lên case đc",
            "Full iOS VI EN sentence 'được tiếng việt hãy lên case đc' in SmartAuto"
        )

        let hEN = makeRemoteHarness(mode: .smartAuto, bundleID: "ru.keepcoder.Telegram")
        ts += 200_000_000
        for ch in "dduowcj tieengs vieetj hayx lene case ddc" {
            _ = hEN.sendRemote(String(ch), 0, ts, [])
            ts += 25_000_000
        }
        check(
            hEN.readScreen(),
            "được tiếng việt hãy lên case đc",
            "Full iOS EN Telex sentence 'được tiếng việt hãy lên case đc' in SmartAuto"
        )
    }

    do {
        func simulateTimedRollover(
            _ input: String,
            intervalNs: UInt64,
            bundleID: String = "com.stablyai.orca"
        ) -> (text: String, leakedKeyUps: Int) {
            let engine = ViEngine(method: .telex, orthography: .modern, allowWAsConsonant: true)
            engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
            let injector = EventInjector(compatFixEnabled: true)
            let tap = TapController(engine: engine, injector: injector, remoteDetector: detector)
            tap.activeBundleID = bundleID
            tap.activePID = 4242
            tap.isSecureInputActive = false

            var buffer = ""
            injector.eventSink = { item in
                switch item {
                case .virtualKey(let kc, true, _, _):
                    if kc == 51 && !buffer.isEmpty { buffer.removeLast() }
                case .unicode(let units, true, _, _):
                    buffer += String(decoding: units, as: UTF16.self)
                default:
                    break
                }
            }

            var ts: UInt64 = 20_000_000_000
            var pendingUps: [(Character, Bool)] = []
            var leaked = 0

            for (idx, ch) in input.enumerated() {
                while let sameIdx = pendingUps.firstIndex(where: { $0.0.lowercased() == ch.lowercased() }) {
                    let (upCh, consumed) = pendingUps.removeFirst()
                    let up = makeHardwareKeyEvent(upCh, keyDown: false, timestamp: ts)
                    let passedUp = tap.processEventForTesting(type: .keyUp, event: up)
                    if consumed && passedUp != nil { leaked += 1 }
                    if sameIdx == 0 { break }
                }
                ts += intervalNs
                let flags: CGEventFlags = ch.isUppercase ? .maskShift : []
                let down = makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts, flags: flags)
                let passed = tap.processEventForTesting(type: .keyDown, event: down)
                let wasConsumed = (passed == nil)
                if let passed {
                    buffer += passed.keyboardString()
                }
                pendingUps.append((ch, wasConsumed))

                if pendingUps.count >= 2 || idx == input.count - 1 {
                    while !pendingUps.isEmpty {
                        let (upCh, consumed) = pendingUps.removeFirst()
                        let up = makeHardwareKeyEvent(upCh, keyDown: false, timestamp: ts)
                        let passedUp = tap.processEventForTesting(type: .keyUp, event: up)
                        if consumed && passedUp != nil { leaked += 1 }
                    }
                }
            }

            return (buffer, leaked)
        }

        let sentences: [(String, String)] = [
            (
                "nhaapj nhanh cacs chuwx nhuw soos laij ra soos ",
                "nhập nhanh các chữ như số lại ra số "
            ),
            (
                "nhapja nhanh cacs chuwx nhuw soso laij ra soso ",
                "nhập nhanh các chữ như số lại ra số "
            ),
            (
                "soos boos coos toos phoos toots moots choots soots ddoots boons voons toons muoons cuoons ",
                "số bố cố tố phố tốt mốt chốt sốt đốt bốn vốn tốn muốn cuốn "
            ),
            (
                "soso boso coso toso phoso tosot mosot chosot sosot ddosot boson vonso ",
                "số bố cố tố phố tốt mốt chốt sốt đốt bốn vốn "
            ),
            (
                "dduowcj khoong banj owi hoom nay trowif ddepj quas ",
                "được không bạn ơi hôm nay trời đẹp quá "
            ),
            (
                "hayx kieemr tra kyx taats car cacs truowngf howpj gox nhanh ",
                "hãy kiểm tra kỹ tất cả các trường hợp gõ nhanh "
            ),
        ]

        for intervalMs in [UInt64(0), 3, 8, 15, 30] {
            let intervalNs = intervalMs * 1_000_000
            for (rawSentence, wantSentence) in sentences {
                let res = simulateTimedRollover(rawSentence, intervalNs: intervalNs)
                check(
                    res.text,
                    wantSentence,
                    "Fast rollover (\(intervalMs)ms/key) for \"\(wantSentence.prefix(24))...\""
                )
                check(
                    String(res.leakedKeyUps),
                    "0",
                    "Zero leaked keyUps at \(intervalMs)ms/key for \"\(wantSentence.prefix(18))...\""
                )
            }
        }

        do {
            let engine = ViEngine(method: .telex, orthography: .modern, allowWAsConsonant: true)
            engine.setOptions(autoCapitalize: false, repeatedRestore: true, spellCheck: true)
            let injector = EventInjector(compatFixEnabled: true)
            let tap = TapController(engine: engine, injector: injector, remoteDetector: detector)
            tap.activeBundleID = "com.stablyai.orca"
            tap.activePID = 4242
            tap.isSecureInputActive = false

            var field = ""
            injector.eventSink = { item in
                switch item {
                case .virtualKey(let kc, true, _, _):
                    if kc == 51 && !field.isEmpty { field.removeLast() }
                case .unicode(let u, true, _, _):
                    field += String(decoding: u, as: UTF16.self)
                default:
                    break
                }
            }

            var ts: UInt64 = 30_000_000_000
            let clickMouse = {
                let mouseSrc = CGEventSource(stateID: .hidSystemState)
                let click = CGEvent(
                    mouseEventSource: mouseSrc,
                    mouseType: .leftMouseDown,
                    mouseCursorPosition: .zero,
                    mouseButton: .left
                )!
                click.timestamp = ts
                _ = tap.processEventForTesting(type: .leftMouseDown, event: click)
                field = ""
                ts += 5_000_000
            }

            for ch in "rustdesk" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            clickMouse()
            for ch in "soos" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "số", "leftMouseDown after passthrough 'rustdesk' resets engine so 'soos' -> 'số'")

            field = ""
            for ch in "1duoc" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            clickMouse()
            for ch in "soos" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "số", "leftMouseDown after '1duoc' resets engine so 'soos' -> 'số'")

            field = ""
            for ch in "case" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            clickMouse()
            for ch in "dduowcj" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "được", "leftMouseDown after 'case' resets engine so 'dduowcj' -> 'được'")

            var simulatedSecure = true
            tap.secureInputProvider = { simulatedSecure }
            tap.refreshSecureInputState()
            check(tap.isSecureInputActive ? "true" : "false", "true", "Secure input latches true while AXSecureTextField active")
            field = ""
            for ch in "soos" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "soos", "Genuine AXSecureTextField passes raw password characters untouched")
            field = ""
            simulatedSecure = false
            for ch in "soos" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "số", "TapController live-recovers from stale isSecureInputActive without app switch so 'soos' -> 'số'")
            tap.secureInputProvider = nil
            tap.refreshSecureInputState()
            engine.reset()
            field = ""
            for ch in "soos" {
                if let p = tap.processEventForTesting(type: .keyDown, event: makeHardwareKeyEvent(ch, keyDown: true, timestamp: ts)) {
                    field += p.keyboardString()
                }
                ts += 5_000_000
            }
            check(field, "số", "Stuck global IsSecureEventInputEnabled without focused AXSecureTextField never breaks 'soos' -> 'số'")

            let hStuckRemote = makeRemoteHarness(mode: .smartAuto, bundleID: "com.stablyai.orca")
            for ch in "soos" {
                _ = hStuckRemote.sendRemote(String(ch), keyCodeForASCII(ch), ts, [.maskSecondaryFn, .maskNumericPad])
                ts += 5_000_000
            }
            check(hStuckRemote.readScreen(), "số", "Remote non-zero keyCode with stuck .maskSecondaryFn/.maskNumericPad still composes 'số'")
        }
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
    check(model.remoteDesktopMode == .smartAuto ? "ok" : "bad", "ok", "fresh install defaults remoteDesktopMode to .smartAuto")
    model.remoteDesktopMode = .phoneKeyboardOnly
    check(AppSettings.shared.remoteDesktopMode == .phoneKeyboardOnly ? "ok" : "bad", "ok", "SettingsModel persists .phoneKeyboardOnly")
    model.remoteDesktopMode = .alwaysKeyV
    check(AppSettings.shared.remoteDesktopMode == .alwaysKeyV ? "ok" : "bad", "ok", "SettingsModel persists .alwaysKeyV")
    model.remoteDesktopMode = .smartAuto
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
