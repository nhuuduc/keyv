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

use crate::config::Orthography;
use crate::engine::EngineAction;
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
        }
    }

    /// Lowercase base letter of this char (flags ignored — raw typed letter).
    pub fn base_lc(&self) -> char {
        self.ch.to_lowercase().next().unwrap_or(self.ch)
    }

    pub fn is_upper(&self) -> bool {
        self.ch.is_uppercase()
    }
}

/// Syllable analysis of the session buffer: which buffer indices form the
/// vowel nucleus (after folding `gi`/`qu` medials into the initial).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Syllable {
    pub nucleus: Vec<usize>,
}

#[derive(Default, Clone, Debug)]
pub struct WordBuffer {
    /// Whether the first displayed horned u came from a standalone w key.
    pub leading_w_expansion: bool,
    pub chars: Vec<ViChar>,
}

impl WordBuffer {
    pub fn clear(&mut self) {
        self.chars.clear();
        self.leading_w_expansion = false;
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
            Some(c) => c.base_lc() == lc && !c.stroke && !c.hat && !c.brev && !c.horn,
            None => false,
        }
    }
    pub fn set_last_hat(&mut self) {
        if let Some(c) = self.last_mut() {
            c.hat = true;
        }
    }
    pub fn set_last_horn(&mut self) {
        if let Some(c) = self.last_mut() {
            c.horn = true;
        }
    }
    pub fn set_last_brev(&mut self) {
        if let Some(c) = self.last_mut() {
            c.brev = true;
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
        let gi_fold = start >= 1
            && start < n
            && lcs[start - 1] == 'g'
            && lcs[start] == 'i'
            && start + 1 < n
            && is_vowel_base(lcs[start + 1])
            && lcs[start + 1] != 'i';
        // Fold `qu` + vowel medials ("qua" → q,u + nucleus a) — but keep
        // standalone uo rhymes ("của", "buồn") where u belongs to the nucleus.
        let qu_fold = start >= 1
            && start < n
            && lcs[start - 1] == 'q'
            && lcs[start] == 'u'
            && start + 1 < n
            && is_vowel_base(lcs[start + 1])
            && lcs[start + 1] != 'u';

        if gi_fold || qu_fold {
            start += 1;
        }

        let nucleus = {
            let mut v = Vec::new();
            while start < n && is_vowel_base(lcs[start]) {
                v.push(start);
                start += 1;
            }
            v
        };

        Syllable { nucleus }
    }
}

/// Render one char into its final Vietnamese glyph.
fn render_char(c: &ViChar) -> String {
    if c.stroke {
        return if c.is_upper() {
            "Đ".to_string()
        } else {
            "đ".to_string()
        };
    }
    let lc = c.base_lc();
    match vowel_group(lc, c.hat, c.brev, c.horn) {
        Some(g) => render_vowel(g, c.tone, c.is_upper()),
        None => c.ch.to_string(),
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
    let idx = tone_target(&buf.chars, &syl, orth).expect("nucleus non-empty implies a target");
    if implicit_closing_hat(&buf.chars, &syl, idx) {
        buf.chars[idx].hat = true;
        buf.chars[idx].implicit_hat = true;
    }
    set_tone_at(buf, idx, tone)
}

/// Vietnamese orthography auto-mark rule for CLOSED rhymes: a diphthong
/// written with plain letters (`uon`, `ien`) takes its hat automatically on
/// the tone-bearing vowel as soon as a coda follows (`muonj` → muộn, `dienf`
/// → điền). Applies to the canonical pairs (u,o) and (i,e) when the tone
/// lands on the second vowel, that vowel is unmarked, and a coda consonant
/// follows the nucleus.
fn implicit_closing_hat(chars: &[ViChar], syl: &Syllable, idx: usize) -> bool {
    let k = syl.nucleus.len();
    if k < 2 || idx != syl.nucleus[k - 1] {
        return false;
    }
    let a = canon_of(chars[syl.nucleus[k - 2]].base_lc());
    let b = canon_of(chars[syl.nucleus[k - 1]].base_lc());
    if !matches!((a, b), ('u', 'o') | ('i', 'e')) {
        return false;
    }
    let c = &chars[idx];
    if c.horn || c.hat || c.brev {
        return false;
    }
    // coda consonant after the nucleus (analysis stops the nucleus run at the
    // first consonant, so a trailing char means coda)
    chars.len() > idx + 1
}

pub fn set_tone_at(buf: &mut WordBuffer, idx: usize, tone: Tone) -> EngineAction {
    // A syllable has one tone, even when a later vowel changes its target.
    let start = buf.last_tone_idx().map_or(idx, |old| old.min(idx));
    for c in &mut buf.chars {
        c.tone = Tone::None;
    }
    buf.chars[idx].tone = tone;
    let n = buf.len() - start;
    EngineAction::Replace {
        n: n as u8,
        chars: buf.render_from(start),
    }
}

/// Decide which nucleus index should carry a tone.
pub fn tone_target(chars: &[ViChar], syl: &Syllable, orth: Orthography) -> Option<usize> {
    let k = syl.nucleus.len();
    match k {
        0 => None,
        1 => Some(syl.nucleus[0]),
        _ => {
            let a = canon_of(chars[syl.nucleus[k - 2]].base_lc());
            let b = canon_of(chars[syl.nucleus[k - 1]].base_lc());
            // Closed oa/oe/uy syllables place the tone on the second vowel
            // in both styles: toan + s -> toán, not tóan.
            if matches!((a, b), ('o', 'a') | ('o', 'e') | ('u', 'y'))
                && chars.len() > syl.nucleus[k - 1] + 1
            {
                return Some(syl.nucleus[k - 1]);
            }
            Some(match (a, b, orth) {
                // tone on first vowel (see module docs for the pair list)
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
                | ('u', 'u', _) // ưu
                => syl.nucleus[k - 2],
                // style-dependent pairs (oa oe oy uy)
                ('o', 'a', Orthography::Traditional)
                | ('o', 'e', Orthography::Traditional)
                | ('o', 'y', Orthography::Traditional)
                | ('u', 'y', Orthography::Traditional) => syl.nucleus[k - 2],
                _ => syl.nucleus[k - 1],
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
