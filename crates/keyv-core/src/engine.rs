//! KeyV engine core — pure one-direction FFI surface (Gotcha 2).
//!
//! `Typer::process_char(ch) -> EngineAction` is the only call needed per
//! keystroke. The engine holds no callback surface; the Swift host decides
//! how to realize `EngineAction` (CGEventPostToPid, AX-guarded logic, …).

use crate::config::{Config, InputMethod};
use crate::macro_::MacroTable;
use crate::word::WordBuffer;
use crate::{telex, vni};

/// Maximum tracked chars per word session (safety bound).
pub const MAX_WORD_LEN: usize = 16;

/// Engine decision for one pressed character key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineAction {
    /// Key was not consumed — the host types it literally (`Pass` also means
    /// "restore key" when an invalid modifier was detected in-engine).
    Pass,
    /// Key IS consumed. Remove the last `n` displayed chars, then output
    /// `chars`. `n = 0` inserts without removing anything.
    Replace { n: u8, chars: String },
}

/// Session state for one keyboard connection.
pub struct Typer {
    cfg: Config,
    macros: MacroTable,
    buf: WordBuffer,
    macro_probe: String,
    /// Next letter starts a sentence (after . ! ? newline).
    sentence_start: bool,
}

impl Typer {
    pub fn new(cfg: Config, macros: MacroTable) -> Self {
        Self {
            cfg,
            macros,
            buf: WordBuffer::default(),
            macro_probe: String::new(),
            sentence_start: true,
        }
    }

    pub fn config(&self) -> &Config {
        &self.cfg
    }

    /// Hot-swap config (mode switch, per-app profile change).
    pub fn set_config(&mut self, cfg: Config) {
        self.cfg = cfg;
        self.reset();
    }

    /// Swap behavioural options without killing the current word session.
    pub fn set_options_no_reset(&mut self, cfg: Config) {
        self.cfg = cfg;
    }

    /// Register/update one macro entry (host loads the macro table lazily).
    pub fn set_macro(&mut self, key: &str, value: &str) {
        self.macros.insert(key, value);
    }

    /// Clear session state (focus change, mouse click, app switch…).
    pub fn reset(&mut self) {
        self.buf.clear();
        self.macro_probe.clear();
    }

    /// Current tracked word, rendered — useful for overlay/debug UI.
    pub fn current_word(&self) -> String {
        self.buf.render_all()
    }

    /// Feed one character key. Non-alphabetic input passes through and
    /// implicitly closes the current word session.
    pub fn process_char(&mut self, ch: char) -> EngineAction {
        if matches!(self.cfg.method, InputMethod::Off) {
            self.reset();
            return EngineAction::Pass;
        }

        let lc = ch.to_lowercase().next().unwrap_or(ch);
        if !lc.is_ascii() {
            // Non-ASCII or precomposed input: pass through, reset session.
            self.reset();
            return EngineAction::Pass;
        }

        // Sentence terminators arm the next-letter capitalization; spaces
        // keep it armed (". hello" → ". Hello"), other separators disarm.
        if self.cfg.auto_capitalize {
            match lc {
                '.' | '!' | '?' | '\n' => self.sentence_start = true,
                ' ' | '\t' => {}
                _ if !lc.is_ascii_alphabetic() => self.sentence_start = false,
                _ => {}
            }
        }

        if lc.is_ascii_alphabetic() {
            // Sentence-start capitalization: the lowercase key is consumed
            // and re-emitted uppercase (Replace{0} — nothing to erase).
            if self.cfg.auto_capitalize
                && self.sentence_start
                && self.buf.is_empty()
                && self.macro_probe.is_empty()
                && ch.is_lowercase()
            {
                self.sentence_start = false;
                let upper = ch.to_uppercase().next().unwrap_or(ch);
                self.buf.push(upper);
                return EngineAction::Replace {
                    n: 0,
                    chars: upper.to_string(),
                };
            }
            if self.cfg.macro_enabled {
                let mut cand = self.macro_probe.clone();
                cand.push(lc);
                if let Some(value) = self.macros.exact(&cand).cloned() {
                    // Host accounting: every prior probe char was passed
                    // through and rendered; only the CURRENT char is
                    // host-side unrendered (this event is consumed). So the
                    // displayed region to erase is len-1, mirroring letter
                    // transforms (`dd` → n=1 for 2 typed chars).
                    let n = cand.chars().count().saturating_sub(1).min(u8::MAX as usize) as u8;
                    self.macro_probe.clear();
                    self.buf.clear();
                    return EngineAction::Replace { n, chars: value };
                }
                if self.macros.has_prefix(&cand) {
                    self.macro_probe = cand;
                    self.buf.push(ch);
                    return EngineAction::Pass;
                }
                self.macro_probe.clear();
                // fall through into the word engine
            }

            return match self.cfg.method {
                InputMethod::Telex | InputMethod::SimpleTelex => {
                    telex::step(&mut self.buf, &self.cfg, ch)
                }
                InputMethod::Vni => vni::step(&mut self.buf, &self.cfg, ch),
                InputMethod::Off => engine_pass(),
            };
        }

        // VNI digit modifiers operate on the live word session.
        if lc.is_ascii_digit() && matches!(self.cfg.method, InputMethod::Vni) {
            return vni::step(&mut self.buf, &self.cfg, ch);
        }

        // Digits/punctuation close the session and pass through.
        self.macro_probe.clear();
        self.buf.clear();
        EngineAction::Pass
    }
}

#[inline]
fn engine_pass() -> EngineAction {
    EngineAction::Pass
}
