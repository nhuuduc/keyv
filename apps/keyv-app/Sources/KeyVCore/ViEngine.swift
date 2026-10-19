import Foundation
import CKeyV

// MARK: - Engine enums (mirror keyv.h)

public enum ViInputMethod: Int, Sendable {
    case off = 0
    case telex = 1
    case simpleTelex = 2
    case vni = 3
}

public enum ViOrthography: Int, Sendable {
    case traditional = 0
    case modern = 1
}

// MARK: - Engine action (Swift-side mirror of KeyVAction)

public enum ViEngineAction {
    /// Event flows through untouched.
    case pass
    /// Event is consumed: erase `backspaces` chars then write `chars`.
    case replace(backspaces: Int, chars: String)
}

private enum KeyVABI {
    /// keyv.h anonymous enum constants, mirrored to dodge import glue.
    static let actionReplaceTag: Int32 = 1
    /// keyv.h option bits.
    static let optAutoCapitalize: Int32 = 1 << 0
    static let optRepeatedRestore: Int32 = 1 << 1
}

// MARK: - ViEngine (RAII wrapper over the Rust core)

/// Wraps one Rust `Typer` session. Not Send: use on the tap's runloop thread
/// (main), matching the FFI contract.
public final class ViEngine {
    private let raw: OpaquePointer

    public init(method: ViInputMethod,
                orthography: ViOrthography,
                macroEnabled: Bool = false,
                allowWAsConsonant: Bool = true) {
        raw = keyv_typer_new(
            Int32(method.rawValue),
            Int32(orthography.rawValue),
            macroEnabled ? 1 : 0,
            allowWAsConsonant ? 1 : 0
        )
    }

    deinit {
        keyv_typer_free(raw)
    }

    /// Feed one character; returns the engine's decision for the host layer.
    public func process(_ ch: Character) -> ViEngineAction {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return .pass
        }
        let action = keyv_process_char(raw, scalar.value)
        return Self.readAction(action)
    }

    private static func readAction(_ actionPtr: OpaquePointer?) -> ViEngineAction {
        guard let actionPtr else { return .pass }
        defer { keyv_action_free(actionPtr) }
        guard keyv_action_tag(actionPtr) == KeyVABI.actionReplaceTag else { return .pass }
        let backspaces = Int(keyv_action_backspaces(actionPtr))
        let chars = keyv_action_chars(actionPtr).map { String(cString: $0) } ?? ""
        return .replace(backspaces: backspaces, chars: chars)
    }

    public func reset() {
        keyv_typer_reset(raw)
    }

    public func setMethod(_ method: ViInputMethod) {
        keyv_typer_set_method(raw, Int32(method.rawValue))
        reset()
    }

    public func setOrthography(_ orthography: ViOrthography) {
        keyv_typer_set_orthography(raw, Int32(orthography.rawValue))
        reset()
    }

    /// Compose both option bits from stored state; called on settings change.
    public func setOptions(autoCapitalize: Bool, repeatedRestore: Bool) {
        var flags: Int32 = 0
        if autoCapitalize { flags |= KeyVABI.optAutoCapitalize }
        if repeatedRestore { flags |= KeyVABI.optRepeatedRestore }
        keyv_typer_set_options(raw, flags)
    }

    public func setMacro(_ key: String, value: String) {
        let result = key.withCString { keyPtr in
            value.withCString { valuePtr in
                keyv_typer_set_macro(raw, keyPtr, valuePtr)
            }
        }
        if result != 0 {
            NSLog("[KeyV] macro register failed for key \(key)")
        }
    }
}
