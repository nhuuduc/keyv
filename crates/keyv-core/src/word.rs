//! Structured per-character word model shared by all input methods.
//!
//! The session buffer only ever contains characters that are currently
//! displayed on screen (1 display char per `ViChar`), so "rewrite the last
//! n chars" map directly onto backspace counts in `EngineAction::Replace`.
//!
//! Tone placement follows the Vietnamese orthography pair rules described in
//! public reference material (pure phonetic facts, not engine code):
//! - rhyme nucleus pairs like `ai ao au ay âu ây êu eo iu oi ôi ơi ui ưi ưu
//!   ia ua ưa` carry the tone on the FIRST vowel
//! - `iê uê uô ươ yê` carry the tone on the SECOND vowel
//! - `oa oe oy uy` are style-dependent:
//!   - Traditional (kiểu cũ: òa, oẹ, úy) → first vowel
//!   - Modern (kiểu mới: oà, oẹ, uý) → second vowel
//! - anything else defaults to the last vowel

use crate::config::{InputMethod, Orthography};
use crate::engine::{EngineAction, MAX_WORD_LEN};
use crate::tables::*;

/// A single character of the currently displayed word, decomposed into
/// its base letter plus applied Vietnamese marks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ViChar {
    /// Raw base letter as typed (ASCII for keys, case preserved).
    pub ch: char,
    pub tone: Tone,
    /// circumflex (â ê ô)
    pub hat: bool,
    /// breve (ă)
    pub brev: bool,
    /// horn (ơ ư)
    pub horn: bool,
    /// bar through the stem (đ / Đ)
    pub stroke: bool,
    /// hat applied automatically (closed-rhyme rule), not typed by the user
    pub implicit_hat: bool,
    pub implicit_horn: bool,
}

impl ViChar {
    pub fn from_char(ch: char) -> Self {
        Self {
            ch,
            tone: Tone::None,
            hat: false,
            brev: false,
            horn: false,
            stroke: false,
            implicit_hat: false,
            implicit_horn: false,
        }
    }

    /// Lowercase base letter of this char (flags ignored — raw typed letter).
    pub fn base_lc(&self) -> char {
        self.ch.to_lowercase().next().unwrap_or(self.ch)
    }

    pub fn is_upper(&self) -> bool {
        self.ch.is_uppercase()
    }

    pub fn has_mark_or_tone(&self) -> bool {
        self.tone != Tone::None || self.hat || self.brev || self.horn || self.stroke
    }
}

/// Syllable analysis of the session buffer: which buffer indices form the
/// vowel nucleus (after folding `gi`/`qu` medials into the initial).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Syllable {
    pub initial_end: usize,
    pub nucleus: Vec<usize>,
    pub coda_start: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EscapedDoubleTone {
    #[default]
    None,
    Pending(char),
    PendingAfterFE,
}

#[derive(Default, Clone, Debug)]
pub struct WordBuffer {
    /// Whether the first displayed horned u came from a standalone w key.
    pub leading_w_expansion: bool,
    pub passthrough: bool,
    pub escaped_double_tone: EscapedDoubleTone,
    pub escaped_mark_raw_pending: bool,
    pub escaped_oo: bool,
    pub stripped_tone_by_z: bool,
    pub trailing_apostrophe: bool,
    pub overflow_count: usize,
    pub raw_keys: Vec<char>,
    pub chars: Vec<ViChar>,
}

#[derive(Clone, Copy, Debug)]
pub struct DisplayedSnapshot {
    chars: [char; MAX_WORD_LEN],
    len: usize,
}

impl DisplayedSnapshot {
    pub fn capture(buf: &WordBuffer) -> Self {
        let mut chars = ['\0'; MAX_WORD_LEN];
        let len = buf.chars.len().min(MAX_WORD_LEN);
        for (slot, vc) in chars.iter_mut().zip(buf.chars.iter().take(len)) {
            *slot = render_char(vc);
        }
        Self { chars, len }
    }

    pub fn as_slice(&self) -> &[char] {
        &self.chars[..self.len]
    }

    pub fn diff_to_str(&self, target: &str, passthrough_key: Option<char>) -> EngineAction {
        let old = self.as_slice();
        let mut prefix_chars = 0usize;
        let mut target_count = 0usize;
        let mut last_target_char = None;
        for tc in target.chars() {
            if prefix_chars == target_count && prefix_chars < old.len() && old[prefix_chars] == tc {
                prefix_chars += 1;
            }
            target_count += 1;
            last_target_char = Some(tc);
        }
        let n = (old.len() - prefix_chars).min(u8::MAX as usize) as u8;
        if n == 0 && target_count == old.len() {
            return EngineAction::Replace {
                n: 0,
                chars: String::new(),
            };
        }
        if n == 0 && target_count == old.len() + 1 && passthrough_key == last_target_char {
            return EngineAction::Pass;
        }
        let suffix: String = target.chars().skip(prefix_chars).collect();
        EngineAction::Replace { n, chars: suffix }
    }

    pub fn diff_to_buf(&self, buf: &WordBuffer, passthrough_key: Option<char>) -> EngineAction {
        let old = self.as_slice();
        let new_len = buf.chars.len();
        let mut prefix_chars = 0usize;
        while prefix_chars < old.len()
            && prefix_chars < new_len
            && old[prefix_chars] == render_char(&buf.chars[prefix_chars])
        {
            prefix_chars += 1;
        }
        let n = (old.len() - prefix_chars).min(u8::MAX as usize) as u8;
        if n == 0 && new_len == old.len() {
            return EngineAction::Replace {
                n: 0,
                chars: String::new(),
            };
        }
        if n == 0
            && new_len == old.len() + 1
            && passthrough_key == Some(render_char(&buf.chars[new_len - 1]))
        {
            return EngineAction::Pass;
        }
        EngineAction::Replace {
            n,
            chars: buf.render_from(prefix_chars),
        }
    }
}

impl WordBuffer {
    pub fn clear(&mut self) {
        self.chars.clear();
        self.raw_keys.clear();
        self.leading_w_expansion = false;
        self.passthrough = false;
        self.escaped_double_tone = EscapedDoubleTone::None;
        self.escaped_mark_raw_pending = false;
        self.escaped_oo = false;
        self.stripped_tone_by_z = false;
        self.trailing_apostrophe = false;
        self.overflow_count = 0;
    }
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }
    pub fn len(&self) -> usize {
        self.chars.len()
    }
    pub fn last(&self) -> Option<&ViChar> {
        self.chars.last()
    }
    pub fn last_mut(&mut self) -> Option<&mut ViChar> {
        self.chars.last_mut()
    }
    pub fn push(&mut self, ch: char) {
        self.chars.push(ViChar::from_char(ch));
    }
    pub fn record_raw(&mut self, ch: char) {
        self.raw_keys.push(ch);
    }
    pub fn pop_backspace(&mut self) {
        self.pop_backspace_for(InputMethod::Telex);
    }
    pub fn pop_backspace_for(&mut self, method: InputMethod) {
        if self.overflow_count > 0 {
            self.overflow_count -= 1;
            self.raw_keys.pop();
            return;
        }
        let popped = self.chars.pop();
        let popped_raw = self.raw_keys.pop();
        self.escaped_double_tone = EscapedDoubleTone::None;
        self.escaped_mark_raw_pending = false;
        self.escaped_oo = false;
        self.stripped_tone_by_z = false;
        self.trailing_apostrophe = false;
        if self.chars.is_empty() {
            self.clear();
        } else {
            let needs_resync = match (popped, popped_raw) {
                (Some(vc), Some(rk)) => vc.has_mark_or_tone() || vc.ch != rk,
                _ => true,
            };
            if self.passthrough {
                self.raw_keys = self.chars.iter().map(|c| c.ch).collect();
            } else if needs_resync
                || (!self.has_any_transform() && self.raw_keys.len() != self.chars.len())
            {
                self.sync_raw_keys_from_chars(method);
            }
            if self.passthrough && self.is_valid_vietnamese() {
                let syl = self.analyze();
                let lcs: Vec<char> = self.chars.iter().map(ViChar::base_lc).collect();
                let is_plain_oo = syl.nucleus.len() == 2
                    && lcs[syl.nucleus[0]] == 'o'
                    && lcs[syl.nucleus[1]] == 'o'
                    && !self.chars[syl.nucleus[0]].hat
                    && !self.chars[syl.nucleus[1]].hat;
                if syl.nucleus.is_empty() {
                    if is_valid_vi_initial(&lcs[..syl.initial_end], self.chars[0].stroke) {
                        self.passthrough = false;
                    }
                } else if !is_plain_oo {
                    self.passthrough = false;
                }
            }
        }
    }
    pub fn sync_raw_keys_from_chars(&mut self, method: InputMethod) {
        let mut out = Vec::with_capacity(self.chars.len() + 2);
        let is_vni = matches!(method, InputMethod::Vni);
        for (idx, vc) in self.chars.iter().enumerate() {
            if idx == 0 && self.leading_w_expansion && vc.base_lc() == 'u' && vc.horn {
                out.push(if vc.is_upper() { 'W' } else { 'w' });
            } else {
                out.push(vc.ch);
                if vc.stroke {
                    out.push(if is_vni { '9' } else { 'd' });
                }
                if vc.hat && !vc.implicit_hat {
                    out.push(if is_vni { '6' } else { vc.base_lc() });
                }
                if vc.brev {
                    out.push(if is_vni { '8' } else { 'w' });
                }
                if vc.horn && !vc.implicit_horn {
                    out.push(if is_vni { '7' } else { 'w' });
                }
            }
            match vc.tone {
                Tone::None => {}
                Tone::Sac => out.push(if is_vni { '1' } else { 's' }),
                Tone::Huyen => out.push(if is_vni { '2' } else { 'f' }),
                Tone::Hoi => out.push(if is_vni { '3' } else { 'r' }),
                Tone::Nga => out.push(if is_vni { '4' } else { 'x' }),
                Tone::Nang => out.push(if is_vni { '5' } else { 'j' }),
            }
        }
        self.raw_keys = out;
    }
    pub fn has_any_transform(&self) -> bool {
        if self.leading_w_expansion || self.chars.iter().any(ViChar::has_mark_or_tone) {
            return true;
        }
        !self.passthrough && self.chars.len() != self.raw_keys.len()
    }
    pub fn has_explicit_mark(&self) -> bool {
        self.leading_w_expansion
            || self
                .chars
                .iter()
                .any(|c| c.stroke || (c.hat && !c.implicit_hat) || c.brev || c.horn)
    }

    // ---- telex helpers -------------------------------------------------

    /// True when the last char is a plain `d`/`D` that can be stroked by `dd`.
    pub fn last_is_plain_d(&self) -> bool {
        self.last().is_some_and(|c| c.base_lc() == 'd' && !c.stroke)
    }
    pub fn set_last_stroke(&mut self) {
        if let Some(c) = self.last_mut() {
            c.stroke = true;
        }
    }

    /// `aa`/`ee`/`oo` circumflex: last char is the same plain vowel and has
    /// no conflicting marks yet.
    pub fn last_is_dup_circ_candidate(&self, lc: char) -> bool {
        match self.last() {
            Some(c) => {
                c.base_lc() == lc && !c.stroke && (!c.hat || c.implicit_hat) && !c.brev && !c.horn
            }
            None => false,
        }
    }
    pub fn set_last_hat(&mut self) {
        if let Some(c) = self.last_mut() {
            c.hat = true;
            c.implicit_hat = false;
            c.brev = false;
            c.horn = false;
            c.implicit_horn = false;
        }
    }
    pub fn set_last_horn(&mut self) {
        if let Some(c) = self.last_mut() {
            c.horn = true;
            c.implicit_horn = false;
        }
    }
    pub fn set_last_brev(&mut self) {
        if let Some(c) = self.last_mut() {
            c.brev = true;
            c.hat = false;
            c.implicit_hat = false;
        }
    }
    pub fn last_has_horn(&self) -> bool {
        self.last().is_some_and(|c| c.horn)
    }
    pub fn last_has_hat(&self) -> bool {
        self.last().is_some_and(|c| c.hat)
    }
    pub fn last_has_brev(&self) -> bool {
        self.last().is_some_and(|c| c.brev)
    }

    /// Rightmost displayed char whose tone equals `tone` (tones live on
    /// nucleus chars only) — used by the Unikey repeated-key restore.
    pub fn last_with_tone(&self, tone: Tone) -> Option<usize> {
        self.chars.iter().rposition(|c| c.tone == tone)
    }

    /// Rightmost nucleus (tone-bearing) index with any tone applied.
    pub fn last_tone_idx(&self) -> Option<usize> {
        self.chars.iter().rposition(|c| c.tone != Tone::None)
    }

    pub fn clear_tone_at(&mut self, idx: usize) {
        if let Some(c) = self.chars.get_mut(idx) {
            c.tone = Tone::None;
        }
    }

    /// Tone-removal support: drop the tone and any implicit auto-hat so the
    /// char renders back to its plain letter.
    pub fn clear_tone_and_implicit_hat_at(&mut self, idx: usize) {
        if let Some(c) = self.chars.get_mut(idx) {
            c.tone = Tone::None;
            if c.implicit_hat {
                c.hat = false;
                c.implicit_hat = false;
            }
        }
    }

    // ---- rendering -----------------------------------------------------

    pub fn render_from(&self, from: usize) -> String {
        self.chars[from..].iter().map(render_char).collect()
    }
    pub fn render_last(&self) -> String {
        self.render_from(self.chars.len().saturating_sub(1))
    }
    pub fn render_all(&self) -> String {
        self.chars.iter().map(render_char).collect()
    }
    pub fn raw_string(&self) -> String {
        self.raw_keys.iter().collect()
    }

    // ---- syllable analysis ----------------------------------------------

    pub fn analyze(&self) -> Syllable {
        let n = self.chars.len();
        let lcs: Vec<char> = self.chars.iter().map(|c| c.base_lc()).collect();

        // leading consonant run
        let mut i = 0usize;
        while i < n && !is_vowel_base(lcs[i]) {
            i += 1;
        }
        let mut start = i;

        // Fold `gi` + vowel (e.g. "gia" → initials g,i + nucleus a). Only
        // fold when a further vowel follows (never "gim"/"gii").
        let gi_fold = start == 1
            && start < n
            && lcs[0] == 'g'
            && lcs[1] == 'i'
            && start + 1 < n
            && is_vowel_base(lcs[start + 1])
            && lcs[start + 1] != 'i';
        // Fold `qu` + vowel medials ("qua" → q,u + nucleus a) — but keep
        // standalone uo rhymes ("của", "buồn") where u belongs to the nucleus.
        let qu_fold = start == 1
            && start < n
            && lcs[0] == 'q'
            && lcs[1] == 'u'
            && start + 1 < n
            && is_vowel_base(lcs[start + 1])
            && lcs[start + 1] != 'u';

        if gi_fold || qu_fold {
            start += 1;
        }

        let initial_end = start;
        let mut nucleus = Vec::new();
        while start < n && is_vowel_base(lcs[start]) {
            nucleus.push(start);
            start += 1;
        }

        Syllable {
            initial_end,
            nucleus,
            coda_start: start,
        }
    }

    pub fn is_valid_vietnamese(&self) -> bool {
        if self.chars.is_empty() {
            return true;
        }
        let syl = self.analyze();
        let lcs: Vec<char> = self.chars.iter().map(|c| c.base_lc()).collect();
        if syl.nucleus.is_empty() {
            return lcs.iter().all(|c| c.is_ascii_alphabetic());
        }
        let initial = &lcs[..syl.initial_end];
        let stroke_first = self.chars[0].stroke;
        if syl.initial_end > 1 && self.chars[1..syl.initial_end].iter().any(|c| c.stroke) {
            return false;
        }
        if !is_valid_vi_initial(initial, stroke_first) {
            return false;
        }
        if initial == ['p']
            && self
                .chars
                .iter()
                .any(|c| c.tone != Tone::None || c.brev || (c.horn && c.base_lc() == 'u'))
        {
            return false;
        }
        if initial == ['q'] && !syl.nucleus.is_empty() && lcs[syl.nucleus[0]] != 'u' {
            return false;
        }
        if initial == ['n', 'g', 'h']
            && !syl.nucleus.is_empty()
            && !matches!(lcs[syl.nucleus[0]], 'i' | 'e')
        {
            return false;
        }
        if initial == ['g', 'h']
            && !syl.nucleus.is_empty()
            && !matches!(lcs[syl.nucleus[0]], 'i' | 'e')
        {
            return false;
        }
        if initial == ['k']
            && !syl.nucleus.is_empty()
            && !matches!(lcs[syl.nucleus[0]], 'i' | 'e' | 'y')
        {
            return false;
        }
        if initial == ['c']
            && !syl.nucleus.is_empty()
            && matches!(lcs[syl.nucleus[0]], 'i' | 'e' | 'y')
        {
            return false;
        }
        if initial == ['g'] && !syl.nucleus.is_empty() && matches!(lcs[syl.nucleus[0]], 'e' | 'y') {
            return false;
        }
        if initial == ['n', 'g']
            && !syl.nucleus.is_empty()
            && matches!(lcs[syl.nucleus[0]], 'i' | 'e' | 'y')
        {
            return false;
        }

        let coda = &lcs[syl.coda_start..];
        if coda.iter().any(|&c| is_vowel_base(c)) {
            return false;
        }
        if self.chars[syl.coda_start..].iter().any(|c| c.stroke) {
            return false;
        }
        if !is_valid_vi_coda(coda) {
            return false;
        }
        if !self.has_explicit_mark()
            && matches!(coda, ['c'] | ['c', 'h'] | ['p'] | ['t'])
            && self
                .chars
                .iter()
                .any(|c| matches!(c.tone, Tone::Huyen | Tone::Hoi | Tone::Nga))
        {
            return false;
        }

        let groups: Vec<VG> = syl
            .nucleus
            .iter()
            .filter_map(|&idx| {
                let c = &self.chars[idx];
                vowel_group(c.base_lc(), c.hat, c.brev, c.horn)
            })
            .collect();
        if groups.len() != syl.nucleus.len() {
            return false;
        }
        if initial == ['q', 'u']
            && matches!(
                groups.as_slice(),
                [VG::I, VG::E] | [VG::I, VG::Ehat] | [VG::I, VG::A]
            )
        {
            return false;
        }
        if initial == ['g'] && groups.starts_with(&[VG::U, VG::Y]) {
            return false;
        }

        let has_coda = !coda.is_empty();
        if initial == ['b']
            && !has_coda
            && groups.as_slice() == [VG::U, VG::Y]
            && self.chars.iter().any(|c| c.tone != Tone::None)
        {
            return false;
        }
        match groups.as_slice() {
            [] => !has_coda,
            [VG::Y] => {
                if has_coda {
                    initial == ['q', 'u']
                        && matches!(
                            coda,
                            ['c'] | ['c', 'h'] | ['n'] | ['n', 'h'] | ['p'] | ['t']
                        )
                } else {
                    (stroke_first && initial == ['d'])
                        || (!stroke_first
                            && matches!(
                                initial,
                                [] | ['h']
                                    | ['k']
                                    | ['l']
                                    | ['m']
                                    | ['n']
                                    | ['q', 'u']
                                    | ['s']
                                    | ['t']
                                    | ['t', 'h']
                                    | ['t', 'r']
                                    | ['v']
                                    | ['x']
                            ))
                }
            }
            [g] => !(*g == VG::Abrev && matches!(coda, ['c', 'h'] | ['n', 'h'])),
            [a, b] => match (*a, *b) {
                (VG::A, VG::I)
                | (VG::A, VG::O)
                | (VG::A, VG::U)
                | (VG::A, VG::Y)
                | (VG::Ahat, VG::U)
                | (VG::Ahat, VG::Y)
                | (VG::E, VG::O)
                | (VG::E, VG::U)
                | (VG::Ehat, VG::U)
                | (VG::I, VG::A)
                | (VG::I, VG::U)
                | (VG::O, VG::I)
                | (VG::Ohat, VG::I)
                | (VG::Ohorn, VG::I)
                | (VG::U, VG::I)
                | (VG::U, VG::U)
                | (VG::Uhorn, VG::A)
                | (VG::Uhorn, VG::I)
                | (VG::Uhorn, VG::U) => !has_coda,
                (VG::I, VG::E) | (VG::I, VG::Ehat) => !matches!(coda, ['c', 'h'] | ['n', 'h']),
                (VG::Y, VG::E) | (VG::Y, VG::Ehat) => {
                    matches!(coda, [] | ['m'] | ['n'] | ['n', 'g'] | ['t'])
                }
                (VG::O, VG::A) | (VG::O, VG::Abrev) => true,
                (VG::O, VG::E) => {
                    !stroke_first
                        && matches!(
                            initial,
                            [] | ['c', 'h']
                                | ['h']
                                | ['k', 'h']
                                | ['l']
                                | ['n', 'g']
                                | ['n', 'h']
                                | ['t']
                                | ['t', 'h']
                                | ['x']
                        )
                        && matches!(coda, [] | ['m'] | ['n'] | ['t'])
                }
                (VG::O, VG::O) => matches!(coda, [] | ['c'] | ['n'] | ['n', 'g']),
                (VG::U, VG::A) | (VG::U, VG::Ahat) => !matches!(coda, ['c', 'h'] | ['n', 'h']),
                (VG::U, VG::E) | (VG::U, VG::Ehat) => {
                    matches!(coda, [] | ['c'] | ['c', 'h'] | ['n'] | ['n', 'h'] | ['t'])
                }
                (VG::Uhorn, VG::O) => !matches!(coda, ['c', 'h'] | ['n', 'h']),
                (VG::U, VG::O)
                | (VG::U, VG::Ohat)
                | (VG::U, VG::Ohorn)
                | (VG::Uhorn, VG::Ohorn) => !matches!(coda, ['c', 'h'] | ['n', 'h']),
                (VG::U, VG::Y) => {
                    matches!(
                        coda,
                        [] | ['c'] | ['c', 'h'] | ['n'] | ['n', 'h'] | ['p'] | ['t']
                    )
                }
                _ => false,
            },
            [a, b, c] => match (*a, *b, *c) {
                (VG::U, VG::Y, VG::E) | (VG::U, VG::Y, VG::Ehat) => {
                    matches!(coda, [] | ['n'] | ['t'])
                }
                (VG::O, VG::E, VG::O) => {
                    !stroke_first
                        && matches!(
                            initial,
                            [] | ['c', 'h']
                                | ['h']
                                | ['k', 'h']
                                | ['l']
                                | ['n', 'g']
                                | ['n', 'h']
                                | ['t']
                                | ['x']
                        )
                        && !has_coda
                }
                (VG::O, VG::A, VG::I)
                | (VG::O, VG::A, VG::O)
                | (VG::O, VG::A, VG::Y)
                | (VG::U, VG::A, VG::Y)
                | (VG::U, VG::Ahat, VG::Y)
                | (VG::U, VG::Y, VG::A)
                | (VG::U, VG::Y, VG::U)
                | (VG::I, VG::E, VG::U)
                | (VG::I, VG::Ehat, VG::U)
                | (VG::Y, VG::E, VG::U)
                | (VG::Y, VG::Ehat, VG::U)
                | (VG::U, VG::O, VG::I)
                | (VG::U, VG::Ohat, VG::I)
                | (VG::U, VG::Ohorn, VG::I)
                | (VG::Uhorn, VG::O, VG::I)
                | (VG::Uhorn, VG::Ohorn, VG::I)
                | (VG::U, VG::O, VG::U)
                | (VG::U, VG::Ohorn, VG::U)
                | (VG::Uhorn, VG::O, VG::U)
                | (VG::Uhorn, VG::Ohorn, VG::U) => !has_coda,
                _ => false,
            },
            _ => false,
        }
    }

    pub fn is_complete_vietnamese(&self) -> bool {
        if !self.is_valid_vietnamese() {
            return false;
        }
        let syl = self.analyze();
        if syl.nucleus.is_empty() {
            return true;
        }
        let lcs: Vec<char> = self.chars.iter().map(ViChar::base_lc).collect();
        let initial = &lcs[..syl.initial_end];
        let coda = &lcs[syl.coda_start..];
        if matches!(coda, ['c'] | ['c', 'h'] | ['p'] | ['t'])
            && !self
                .chars
                .iter()
                .any(|c| matches!(c.tone, Tone::Sac | Tone::Nang))
        {
            return false;
        }
        let groups: Vec<VG> = syl
            .nucleus
            .iter()
            .filter_map(|&idx| {
                let c = &self.chars[idx];
                vowel_group(c.base_lc(), c.hat, c.brev, c.horn)
            })
            .collect();
        let has_coda = !coda.is_empty();
        if initial == ['p']
            && ((has_coda && !(groups.as_slice() == [VG::I] && coda == ['n']))
                || groups.as_slice() == [VG::Ahat])
        {
            return false;
        }
        if initial == ['b'] && groups.as_slice() == [VG::U, VG::Y] && coda != ['t'] {
            return false;
        }
        if initial == ['t', 'h'] && groups.as_slice() == [VG::O, VG::E] && coda != ['t'] {
            return false;
        }
        if initial == ['q', 'u'] && groups.as_slice() == [VG::O] {
            return false;
        }
        if initial == ['q', 'u'] && has_coda && groups.as_slice() == [VG::Y] && coda == ['c'] {
            return false;
        }
        if matches!(groups.as_slice(), [VG::U, VG::Ehat] | [VG::U, VG::Y]) && coda == ['c'] {
            return false;
        }
        if groups.as_slice() == [VG::O, VG::O] && !matches!(coda, ['c'] | ['n', 'g']) {
            return false;
        }
        if has_coda && groups.as_slice() == [VG::U, VG::A] {
            return false;
        }
        if matches!(
            groups.as_slice(),
            [VG::U, VG::U]
                | [VG::E, VG::U]
                | [VG::U, VG::O]
                | [VG::Uhorn, VG::O]
                | [VG::I, VG::E]
                | [VG::Y, VG::E]
                | [VG::U, VG::E]
                | [VG::U, VG::Y, VG::E]
                | [VG::I, VG::E, VG::U]
                | [VG::Y, VG::E, VG::U]
                | [VG::U, VG::O, VG::I]
                | [VG::U, VG::Ohorn, VG::I]
                | [VG::Uhorn, VG::O, VG::I]
                | [VG::U, VG::O, VG::U]
                | [VG::U, VG::Ohorn, VG::U]
                | [VG::Uhorn, VG::O, VG::U]
                | [VG::U, VG::A, VG::Y]
        ) {
            return false;
        }
        if !has_coda
            && (matches!(
                groups.as_slice(),
                [VG::Abrev] | [VG::O, VG::Abrev] | [VG::O, VG::Ahat] | [VG::U, VG::Ahat]
            ) || (groups.as_slice() == [VG::Ahat]
                && (!initial.is_empty() || self.chars[0].tone != Tone::None)))
        {
            return false;
        }
        true
    }

    pub fn restore_to_raw(&mut self, displayed_before_push: &str) -> EngineAction {
        let target = self.raw_string();
        self.chars = self
            .raw_keys
            .iter()
            .copied()
            .map(ViChar::from_char)
            .collect();
        self.leading_w_expansion = false;
        self.passthrough = true;
        self.escaped_double_tone = EscapedDoubleTone::None;
        self.escaped_mark_raw_pending = false;
        self.escaped_oo = false;
        self.stripped_tone_by_z = false;
        self.trailing_apostrophe = false;
        diff_action(displayed_before_push, &target)
    }

    pub fn restore_to_raw_from(
        &mut self,
        displayed: &DisplayedSnapshot,
        passthrough_key: Option<char>,
    ) -> EngineAction {
        let target = self.raw_string();
        self.chars = self
            .raw_keys
            .iter()
            .copied()
            .map(ViChar::from_char)
            .collect();
        self.leading_w_expansion = false;
        self.passthrough = true;
        self.escaped_double_tone = EscapedDoubleTone::None;
        self.escaped_mark_raw_pending = false;
        self.escaped_oo = false;
        self.stripped_tone_by_z = false;
        self.trailing_apostrophe = false;
        displayed.diff_to_str(&target, passthrough_key)
    }
}

pub fn diff_action(displayed_before: &str, target: &str) -> EngineAction {
    let mut prefix_chars = 0usize;
    for (a, b) in displayed_before.chars().zip(target.chars()) {
        if a == b {
            prefix_chars += 1;
        } else {
            break;
        }
    }
    let old_count = displayed_before.chars().count();
    let target_count = target.chars().count();
    let n = (old_count - prefix_chars).min(u8::MAX as usize) as u8;
    if n == 0 && target_count == old_count {
        return EngineAction::Replace {
            n: 0,
            chars: String::new(),
        };
    }
    let suffix: String = target.chars().skip(prefix_chars).collect();
    EngineAction::Replace { n, chars: suffix }
}

/// Render one char into its final Vietnamese glyph.
pub fn render_char(c: &ViChar) -> char {
    if c.stroke {
        return if c.is_upper() { 'Đ' } else { 'đ' };
    }
    let lc = c.base_lc();
    match vowel_group(lc, c.hat, c.brev, c.horn) {
        Some(g) => render_vowel_char(g, c.tone, c.is_upper()),
        None => c.ch,
    }
}

/// Shared tone application: pick the placement per orthography rules, apply,
/// and return a suffix-rewrite action. `fallback_char` = the raw key to pass
/// through when there is no vowel to mark (engine restores the key).
pub fn apply_tone(
    buf: &mut WordBuffer,
    tone: Tone,
    orth: Orthography,
    fallback_char: char,
) -> EngineAction {
    let syl = buf.analyze();
    if syl.nucleus.is_empty() {
        buf.push(fallback_char);
        return EngineAction::Pass;
    }
    if buf.escaped_oo && syl.coda_start == buf.len() {
        buf.push(fallback_char);
        buf.passthrough = true;
        buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
        return EngineAction::Pass;
    }
    let idx = tone_target(&buf.chars, &syl, orth).expect("nucleus non-empty implies a target");
    if implicit_closing_hat(&buf.chars, &syl, idx) {
        buf.chars[idx].hat = true;
        buf.chars[idx].implicit_hat = true;
    }
    set_tone_at(buf, idx, tone)
}

pub fn rebalance_after_push(buf: &mut WordBuffer, orth: Orthography) -> EngineAction {
    let mut earliest_change: Option<usize> = None;
    let syl = buf.analyze();

    if syl.nucleus.len() >= 2 {
        let u_idx = syl.nucleus[0];
        let o_idx = syl.nucleus[1];
        if buf.chars[u_idx].base_lc() == 'u'
            && !buf.chars[u_idx].horn
            && buf.chars[o_idx].base_lc() == 'o'
            && buf.chars[o_idx].horn
            && (syl.nucleus.len() > 2 || buf.len() > o_idx + 1)
        {
            buf.chars[u_idx].horn = true;
            buf.chars[u_idx].implicit_horn = true;
            earliest_change = Some(u_idx);
        } else if buf.chars[u_idx].base_lc() == 'u'
            && buf.chars[u_idx].horn
            && buf.chars[o_idx].base_lc() == 'o'
            && !buf.chars[o_idx].horn
            && !buf.chars[o_idx].hat
            && (syl.nucleus.len() > 2 || buf.len() > o_idx + 1)
        {
            buf.chars[o_idx].horn = true;
            buf.chars[o_idx].implicit_horn = true;
            earliest_change = Some(o_idx);
        }
    }

    if let Some(old_idx) = buf.last_tone_idx() {
        let tone = buf.chars[old_idx].tone;
        if let Some(new_idx) = tone_target(&buf.chars, &syl, orth) {
            let needs_implicit_hat = implicit_closing_hat(&buf.chars, &syl, new_idx);
            if new_idx != old_idx || needs_implicit_hat {
                buf.clear_tone_and_implicit_hat_at(old_idx);
                if needs_implicit_hat {
                    buf.chars[new_idx].hat = true;
                    buf.chars[new_idx].implicit_hat = true;
                }
                buf.chars[new_idx].tone = tone;
                let changed = old_idx.min(new_idx);
                earliest_change = Some(earliest_change.map_or(changed, |e| e.min(changed)));
            }
        }
    }

    if let Some(start) = earliest_change {
        let n = (buf.len() - 1) - start;
        EngineAction::Replace {
            n: n as u8,
            chars: buf.render_from(start),
        }
    } else {
        EngineAction::Pass
    }
}

pub fn reanchor_existing_tone(buf: &mut WordBuffer, orth: Orthography) -> Option<usize> {
    let old_idx = buf.last_tone_idx()?;
    let tone = buf.chars[old_idx].tone;
    let syl = buf.analyze();
    let new_idx = tone_target(&buf.chars, &syl, orth)?;
    if new_idx == old_idx {
        return None;
    }
    buf.clear_tone_and_implicit_hat_at(old_idx);
    buf.chars[new_idx].tone = tone;
    Some(old_idx.min(new_idx))
}

pub fn apply_uo_or_single_horn(buf: &mut WordBuffer, syl: &Syllable, target_idx: usize) -> usize {
    if buf.chars[target_idx].base_lc() == 'o'
        && let Some(pos) = syl.nucleus.iter().position(|&i| i == target_idx)
        && pos > 0
    {
        let prev_idx = syl.nucleus[pos - 1];
        if buf.chars[prev_idx].base_lc() == 'u' {
            buf.chars[target_idx].horn = true;
            buf.chars[target_idx].hat = false;
            buf.chars[target_idx].implicit_hat = false;

            let lcs_initial: Vec<char> = buf.chars[..syl.initial_end]
                .iter()
                .map(ViChar::base_lc)
                .collect();
            let is_open_huo_thuo = (lcs_initial == ['h'] || lcs_initial == ['t', 'h'])
                && syl.nucleus.len() == 2
                && buf.len() == target_idx + 1
                && !buf.chars[prev_idx].horn;

            if !is_open_huo_thuo && !buf.chars[prev_idx].horn {
                buf.chars[prev_idx].horn = true;
                buf.chars[prev_idx].implicit_horn = true;
                return prev_idx;
            }
            return target_idx;
        }
    }

    buf.chars[target_idx].horn = true;
    buf.chars[target_idx].hat = false;
    buf.chars[target_idx].implicit_hat = false;
    target_idx
}

/// Vietnamese orthography auto-mark rule for CLOSED rhymes: a diphthong
/// written with plain letters (`uon`, `ien`) takes its hat automatically on
/// the tone-bearing vowel as soon as a coda follows (`muonj` → muộn, `dienf`
/// → điền). Applies to the canonical pairs (u,o) and (i,e) when the tone
/// lands on the second vowel, that vowel is unmarked, and a coda consonant
/// follows the nucleus.
fn implicit_closing_hat(chars: &[ViChar], syl: &Syllable, idx: usize) -> bool {
    let k = syl.nucleus.len();
    if k == 1
        && idx == syl.nucleus[0]
        && syl.initial_end == 2
        && chars[0].base_lc() == 'q'
        && chars[1].base_lc() == 'u'
        && chars[idx].base_lc() == 'o'
        && !chars[idx].hat
        && !chars[idx].horn
        && !chars[idx].brev
        && chars.len() == idx + 2
        && chars[idx + 1].base_lc() == 'c'
    {
        return true;
    }
    if k < 2 || idx != syl.nucleus[k - 1] {
        return false;
    }
    let prev = &chars[syl.nucleus[k - 2]];
    let curr = &chars[syl.nucleus[k - 1]];
    if prev.horn || prev.hat || prev.brev || curr.horn || curr.hat || curr.brev {
        return false;
    }
    let a = canon_of(prev.base_lc());
    let b = canon_of(curr.base_lc());
    if !matches!((a, b), ('u', 'o') | ('i', 'e') | ('y', 'e')) {
        return false;
    }
    chars.len() > idx + 1
}

pub fn set_tone_at(buf: &mut WordBuffer, idx: usize, tone: Tone) -> EngineAction {
    let displayed = DisplayedSnapshot::capture(buf);
    for i in 0..buf.chars.len() {
        if i != idx && buf.chars[i].tone != Tone::None {
            buf.clear_tone_and_implicit_hat_at(i);
        } else {
            buf.chars[i].tone = Tone::None;
        }
    }
    buf.chars[idx].tone = tone;
    displayed.diff_to_buf(buf, None)
}

/// Decide which nucleus index should carry a tone.
pub fn tone_target(chars: &[ViChar], syl: &Syllable, orth: Orthography) -> Option<usize> {
    let k = syl.nucleus.len();
    match k {
        0 => None,
        1 => Some(syl.nucleus[0]),
        _ => {
            if let Some(&o_horn_idx) = syl
                .nucleus
                .iter()
                .find(|&&idx| chars[idx].base_lc() == 'o' && chars[idx].horn)
            {
                return Some(o_horn_idx);
            }
            if let Some(&marked_idx) = syl
                .nucleus
                .iter()
                .find(|&&idx| chars[idx].hat || chars[idx].brev || chars[idx].horn)
            {
                return Some(marked_idx);
            }

            if k >= 3 {
                if k == 3 && chars.len() > syl.nucleus[2] + 1 {
                    return Some(syl.nucleus[2]);
                }
                return Some(syl.nucleus[1]);
            }

            let a = canon_of(chars[syl.nucleus[0]].base_lc());
            let b = canon_of(chars[syl.nucleus[1]].base_lc());
            // Closed 2-vowel syllables place the tone on the second vowel
            // in both styles: toan + s -> toán, not tóan.
            if chars.len() > syl.nucleus[1] + 1 {
                return Some(syl.nucleus[1]);
            }
            Some(match (a, b, orth) {
                ('a', 'i', _)
                | ('a', 'o', _)
                | ('a', 'u', _)
                | ('a', 'y', _)
                | ('e', 'o', _)
                | ('e', 'u', _)
                | ('i', 'a', _)
                | ('i', 'u', _)
                | ('o', 'i', _)
                | ('u', 'a', _)
                | ('u', 'i', _)
                | ('u', 'u', _) => syl.nucleus[0],
                ('o', 'a', Orthography::Traditional)
                | ('o', 'e', Orthography::Traditional)
                | ('o', 'y', Orthography::Traditional)
                | ('u', 'y', Orthography::Traditional) => syl.nucleus[0],
                _ => syl.nucleus[1],
            })
        }
    }
}

/// VNI-style mark op helper: find the last nucleus index eligible for a mark
/// (scans right→left so `toi6` marks the `o`, mirroring VNI semantics).
pub fn last_markable(
    chars: &[ViChar],
    nucleus: &[usize],
    eligible: impl Fn(&ViChar) -> bool,
) -> Option<usize> {
    nucleus
        .iter()
        .rev()
        .copied()
        .find(|&idx| eligible(&chars[idx]))
}
