//! Engine configuration (shared surface for Swift host via UniFFI later).

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InputMethod {
    /// Telex: full engine with restore-on-invalid semantics.
    Telex,
    /// Simple Telex: transforms apply immediately, no invalid-key restore
    /// policies (P1: shares the Telex code path; diverges in later phases).
    SimpleTelex,
    /// VNI digit-based marks.
    Vni,
    /// Engine bypassed; Swift types everything literally.
    Off,
}

/// Tone-placement style over the shared vowel pairs (`oa oe oy uy`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Orthography {
    /// Kiểu cũ: òa, oẹ, úy (tone on the first vowel of the pair).
    #[default]
    Traditional,
    /// Kiểu mới: oà, oẹ, uý (tone on the second vowel of the pair).
    Modern,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub method: InputMethod,
    pub orthography: Orthography,
    /// Macro (gõ tắt) expansion enabled.
    pub macro_enabled: bool,
    /// When true, a standalone leading `w` is typed as a literal consonant
    /// instead of expanding to `ư` (mirrors OpenKey's
    /// "cho phép dùng f z w j làm phụ âm đầu").
    pub allow_w_consonant: bool,
    /// Unikey-style repeated-mark restore: pressing the SAME tone key
    /// while that tone is already applied removes it again ("bar" →
    /// "bả" → "bar"). Mirrors Unikey's ô-style double-tap behavior.
    pub repeated_restore: bool,
    /// Capitalize the first letter after a sentence terminator (. ! ?).
    pub auto_capitalize: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            method: InputMethod::Telex,
            orthography: Orthography::Traditional,
            macro_enabled: false,
            allow_w_consonant: true,
            repeated_restore: true,
            auto_capitalize: false,
        }
    }
}
