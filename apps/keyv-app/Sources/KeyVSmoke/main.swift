import Foundation
import KeyVCore
import KeyVHostKit
import AppKit

// FFI wrapper smoke test (no XCTest on Command Line Tools) — mirrors the
// Rust engine semantics through the Swift ViEngine layer. Exit 0 = pass.
//
// Screen-sim contract (must match Rust tests/engine_tests.rs type_str):
// on Replace{n, s} erase min(n, len) trailing chars then append s.

var failures: [String] = []

private func screen(_ input: String, method: ViInputMethod, orthography: ViOrthography = .traditional, allowWAsConsonant: Bool = true) -> String {
    let engine = ViEngine(method: method, orthography: orthography, allowWAsConsonant: allowWAsConsonant)
    var cursor = ""
    for ch in input {
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
check(screen("muonj", method: .telex), "muộn", "auto-circumflex muonj")
check(screen("ddienf", method: .telex), "điền", "auto-circumflex ddiendf")

// Orthography: traditional tone on first vowel (òa), modern on second (oà)
check(screen("hoaf", method: .telex, orthography: .traditional), "h\u{00F2}a", "ortho traditional")
check(screen("hoaf", method: .telex, orthography: .modern), "ho\u{00E0}", "ortho modern")

// VNI
check(screen("d9", method: .vni), "đ", "vni d9")
check(screen("d9ang", method: .vni), "đang", "vni d9ang")
check(screen("u7", method: .vni), "ư", "vni u7")
check(screen("a1", method: .vni), "á", "vni a1")

// Off mode passes everything through
check(screen("d9", method: .off), "d9", "off passthrough")

// Tone/mark keys do NOT reset the session — VNI "ha20": huyền then strip
// by the live-tone key (`0`) → "ha" (separator-based reset only)
do {
    let engine = ViEngine(method: .vni, orthography: .traditional)
    var cursor = ""
    for ch in "ha20" {
        switch engine.process(ch) {
        case .pass: cursor.append(ch)
        case .replace(let b, let s): cursor.removeLast(min(b, cursor.count)); cursor += s
        }
    }
    check(cursor, "ha", "live tone strip (ha20)")
}

// Macro path via FFI: expansion rewrites the typed word; the engine must
// ask for len-1 backspaces (the final key char was never rendered)
do {
    let engine = ViEngine(method: .telex, orthography: .traditional, macroEnabled: true)
    engine.setMacro("hvbt", value: "nhé bạn")
    var cursor = ""
    for ch in "hvbt" {
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
    check(cursor, "nhé bạn", "macro FFI")
}

// Unikey repeated-key restore via FFI: "bar"+"r" → bar dùng phím 'r' lần 2;
// 'z' lần đầu bỏ dấu, lần 2 phát phím thường.
check(screen("barr", method: .telex), "bar", "repeated r restores bar")
check(screen("bass", method: .telex), "bas", "repeated s restores bas")
check(screen("baszz", method: .telex), "baz", "z strips tone then literal")
check(screen("ddienff", method: .telex), "đienf", "repeated f restores marks")

// Write Hoa chữ cái đầu câu (auto_capitalize set via FFI options)
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

// Host settings regressions use the smoke executable's defaults, never app.keyv.host.
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
}

if failures.isEmpty {
    print("KeyVSmoke: ALL PASS (engine + host settings regressions)")
} else {
    for f in failures { print("FAIL: \(f)") }
    exit(1)
}
