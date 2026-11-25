//! KeyV engine core — pure one-direction FFI surface (Gotcha 2).
//!
//! `Typer::process_char(ch) -> EngineAction` is the only call needed per
//! keystroke. The engine holds no callback surface; the Swift host decides
//! how to realize `EngineAction` (CGEventPostToPid, AX-guarded logic, …).

use crate::config::{Config, InputMethod};
use crate::macro_::MacroTable;
use crate::word::{DisplayedSnapshot, WordBuffer};
use crate::{telex, vni};

/// Maximum tracked chars per word session (safety bound).
pub const MAX_WORD_LEN: usize = 32;

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
    /// Next letter starts a sentence (after . ! ? newline).
    sentence_start: bool,
    macro_eligible: bool,
    auto_capitalized_first: bool,
}

impl Typer {
    pub fn new(cfg: Config, macros: MacroTable) -> Self {
        Self {
            cfg,
            macros,
            buf: WordBuffer::default(),
            sentence_start: true,
            macro_eligible: true,
            auto_capitalized_first: false,
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
        self.macro_eligible = true;
        self.auto_capitalized_first = false;
    }

    /// Synchronize session state when the user presses Backspace.
    pub fn backspace(&mut self) {
        self.buf.pop_backspace_for(self.cfg.method);
        if self.buf.is_empty() {
            self.macro_eligible = true;
            if self.auto_capitalized_first {
                self.sentence_start = true;
                self.auto_capitalized_first = false;
            }
        }
    }

    /// Current tracked word, rendered — useful for overlay/debug UI.
    pub fn current_word(&self) -> String {
        self.buf.render_all()
    }

    pub fn has_active_transform(&self) -> bool {
        !self.buf.is_empty() && self.buf.has_any_transform()
    }

    /// Feed one character key. Non-alphabetic input passes through and
    /// implicitly closes the current word session.
    pub fn process_char(&mut self, ch: char) -> EngineAction {
        if matches!(self.cfg.method, InputMethod::Off) {
            self.reset();
            return EngineAction::Pass;
        }

        if matches!(ch, '\u{0008}' | '\u{007f}') {
            self.backspace();
            return EngineAction::Pass;
        }

        if !ch.is_ascii() {
            self.reset();
            return EngineAction::Pass;
        }

        let lc = ch.to_ascii_lowercase();

        // Sentence terminators arm the next-letter capitalization; spaces
        // keep it armed (". hello" → ". Hello"), other separators disarm.
        if self.cfg.auto_capitalize {
            match lc {
                '.' | '!' | '?' | '\n' | '\r' => self.sentence_start = true,
                ' ' | '\t' => {}
                _ if !lc.is_ascii_alphabetic() => self.sentence_start = false,
                _ => {}
            }
        }

        if lc.is_ascii_alphabetic() {
            if self.buf.trailing_apostrophe {
                self.buf.trailing_apostrophe = false;
                let displayed = DisplayedSnapshot::capture(&self.buf);
                self.buf.record_raw(ch);
                if self.buf.has_any_transform() {
                    return self.buf.restore_to_raw_from(&displayed, Some(ch));
                }
                if self.buf.len() < MAX_WORD_LEN {
                    self.buf.push(ch);
                } else {
                    self.buf.overflow_count += 1;
                }
                self.buf.passthrough = true;
                self.buf.raw_keys = self.buf.chars.iter().map(|c| c.ch).collect();
                return EngineAction::Pass;
            }

            let mut effective_ch = ch;
            let mut capitalized_first = false;
            if self.cfg.auto_capitalize
                && self.sentence_start
                && self.buf.is_empty()
                && ch.is_lowercase()
            {
                self.sentence_start = false;
                effective_ch = ch.to_uppercase().next().unwrap_or(ch);
                capitalized_first = true;
                self.auto_capitalized_first = true;
            } else if self.cfg.auto_capitalize && self.sentence_start {
                self.sentence_start = false;
            }

            let was_non_empty = !self.buf.is_empty();
            let action = match self.cfg.method {
                InputMethod::Telex | InputMethod::SimpleTelex => {
                    telex::step(&mut self.buf, &self.cfg, effective_ch)
                }
                InputMethod::Vni => vni::step(&mut self.buf, &self.cfg, effective_ch),
                InputMethod::Off => engine_pass(),
            };

            if was_non_empty && self.buf.is_empty() {
                self.macro_eligible = false;
                self.auto_capitalized_first = false;
            }

            if capitalized_first && matches!(action, EngineAction::Pass) {
                return EngineAction::Replace {
                    n: 0,
                    chars: effective_ch.to_string(),
                };
            }
            return action;
        }

        // VNI digit modifiers operate on the live word session.
        if lc.is_ascii_digit() && matches!(self.cfg.method, InputMethod::Vni) {
            let was_non_empty = !self.buf.is_empty();
            let action = vni::step(&mut self.buf, &self.cfg, ch);
            if was_non_empty && self.buf.is_empty() {
                self.macro_eligible = false;
                self.auto_capitalized_first = false;
            }
            return action;
        }

        if lc.is_ascii_digit() || ch == '_' {
            self.macro_eligible = false;
            self.auto_capitalized_first = false;
            self.buf.escaped_double_tone = crate::word::EscapedDoubleTone::None;
            self.buf.escaped_mark_raw_pending = false;
            let displayed = DisplayedSnapshot::capture(&self.buf);
            self.buf.record_raw(ch);
            if self.cfg.spell_check && self.buf.has_any_transform() {
                return self.buf.restore_to_raw_from(&displayed, Some(ch));
            }
            if self.buf.len() < MAX_WORD_LEN {
                self.buf.push(ch);
            } else {
                self.buf.overflow_count += 1;
            }
            self.buf.passthrough = true;
            self.buf.raw_keys = self.buf.chars.iter().map(|c| c.ch).collect();
            return EngineAction::Pass;
        }

        let had_word = !self.buf.is_empty();
        if self.buf.trailing_apostrophe {
            self.buf.clear();
            self.macro_eligible = ch != '\'';
            self.auto_capitalized_first = false;
            return EngineAction::Pass;
        }

        if self.cfg.macro_enabled
            && self.macro_eligible
            && !self.macros.is_empty()
            && !self.buf.is_empty()
        {
            let raw_cand: String = self
                .buf
                .raw_keys
                .iter()
                .map(|c| c.to_ascii_lowercase())
                .collect();
            if let Some(value) = self.macros.exact(&raw_cand).cloned() {
                let first_auto = self.auto_capitalized_first;
                let all_upper = !first_auto
                    && self.buf.raw_keys.len() >= 2
                    && self.buf.raw_keys.iter().all(|c| c.is_uppercase());
                let expanded = if all_upper {
                    value.to_uppercase()
                } else if first_auto {
                    capitalize_first_char(&value)
                } else {
                    value
                };
                let displayed = DisplayedSnapshot::capture(&self.buf);
                let target = format!("{expanded}{ch}");
                self.buf.clear();
                self.macro_eligible = ch != '\'';
                self.auto_capitalized_first = false;
                return displayed.diff_to_str(&target, Some(ch));
            }
        }

        if self.cfg.spell_check
            && !self.buf.passthrough
            && self.buf.has_any_transform()
            && !self.buf.is_complete_vietnamese()
        {
            let displayed = DisplayedSnapshot::capture(&self.buf);
            let target = format!("{}{ch}", self.buf.raw_string());
            self.buf.clear();
            self.macro_eligible = ch != '\'' || !had_word;
            self.auto_capitalized_first = false;
            return displayed.diff_to_str(&target, Some(ch));
        }

        if ch == '\'' && self.cfg.spell_check && had_word {
            self.buf.record_raw(ch);
            if self.buf.len() < MAX_WORD_LEN {
                self.buf.push(ch);
                self.buf.trailing_apostrophe = true;
            } else {
                self.buf.clear();
            }
            self.macro_eligible = false;
            self.auto_capitalized_first = false;
            return EngineAction::Pass;
        }

        self.buf.clear();
        self.macro_eligible = ch != '\'' || !had_word;
        self.auto_capitalized_first = false;
        EngineAction::Pass
    }
}

fn capitalize_first_char(s: &str) -> String {
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return String::new();
    };
    let mut out: String = first.to_uppercase().collect();
    out.extend(chars);
    out
}

#[inline]
fn engine_pass() -> EngineAction {
    EngineAction::Pass
}
