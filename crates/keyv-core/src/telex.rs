//! Telex input transforms, clean-room implementation.
//!
//! Public-key conventions implemented:
//! - `dd` → đ (stroke on the immediately preceding plain d)
//! - duplicate vowel letter sets the circumflex (`aa` â, `ee` ê, `oo` ô)
//! - `w` sets breve/horn: after `a` → ă, after `o` → ơ, after `u` → ư;
//!   a lone leading `w` may expand to ư (config `allow_w_consonant`)
//! - `s f r x j` select tone: sắc huyền hỏi ngã nặng
//!
//! Invalid transforms fall back to typing the pressed key literally
//! (the session buffer tracks it so the word keeps building).

use crate::config::Config;
use crate::engine::{EngineAction, MAX_WORD_LEN};
use crate::tables::Tone;
use crate::word::{WordBuffer, apply_tone};

pub fn tone_of_key(lc: char) -> Option<Tone> {
    Some(match lc {
        's' => Tone::Sac,
        'f' => Tone::Huyen,
        'r' => Tone::Hoi,
        'x' => Tone::Nga,
        'j' => Tone::Nang,
        _ => return None,
    })
}

/// Process one alphabetic key in a Telex-family mode.
pub fn step(buf: &mut WordBuffer, cfg: &Config, ch: char) -> EngineAction {
    if buf.len() >= MAX_WORD_LEN {
        buf.clear();
    }
    let lc = ch.to_lowercase().next().unwrap_or(ch);

    // Repeating a transformation key restores literal typing (aaa -> aa,
    // ddd -> dd). Preserve the original character's case and tone.
    if cfg.repeated_restore
        && let Some(last) = buf.last().copied()
    {
        if lc == 'd' && last.stroke {
            buf.last_mut().unwrap().stroke = false;
            let chars = format!("{}{ch}", buf.render_last());
            buf.clear();
            return EngineAction::Replace { n: 1, chars };
        }
        if matches!(lc, 'a' | 'e' | 'o') && last.base_lc() == lc && last.hat {
            buf.last_mut().unwrap().hat = false;
            let chars = format!("{}{ch}", buf.render_last());
            buf.clear();
            return EngineAction::Replace { n: 1, chars };
        }
    }

    // `dd` → đ
    if lc == 'd' && buf.last_is_plain_d() {
        buf.set_last_stroke();
        return EngineAction::Replace {
            n: 1,
            chars: buf.render_last(),
        };
    }

    // tone keys — tone finalization does NOT close the session (Unikey-style:
    // words are separated by real separators; host resets on separators).
    if let Some(tone) = tone_of_key(lc) {
        // Unikey repeated-key restore: the SAME tone key pressed again on
        // a syllable that already carries that tone removes it AND types
        // the raw letter ("bar" → "bả" → "bar"). The session closes after
        // the restore so further letters start a fresh word.
        if cfg.repeated_restore
            && let Some(idx) = buf.last_with_tone(tone)
        {
            buf.clear_tone_and_implicit_hat_at(idx);
            let tail = buf.render_from(idx);
            let n = buf.len() - idx;
            buf.clear();
            return EngineAction::Replace {
                n: n as u8,
                chars: format!("{tail}{ch}"),
            };
        }
        return apply_tone(buf, tone, cfg.orthography, ch);
    }

    match lc {
        // duplicate vowel → circumflex
        'a' | 'e' | 'o' => {
            if buf.last_is_dup_circ_candidate(lc) {
                buf.set_last_hat();
                return EngineAction::Replace {
                    n: 1,
                    chars: buf.render_last(),
                };
            }
            buf.push(ch);
            EngineAction::Pass
        }
        'w' => apply_w(buf, cfg, ch),
        // `z` removes the last tone from the syllable (Unikey telex).
        'z' => {
            if let Some(idx) = buf.last_tone_idx() {
                buf.clear_tone_at(idx);
                let n = buf.len() - idx;
                return EngineAction::Replace {
                    n: n as u8,
                    chars: buf.render_from(idx),
                };
            }
            buf.push(ch);
            EngineAction::Pass
        }
        _ => {
            buf.push(ch);
            EngineAction::Pass
        }
    }
}

fn apply_w(buf: &mut WordBuffer, cfg: &Config, ch: char) -> EngineAction {
    if buf.is_empty() {
        if cfg.allow_w_consonant {
            buf.push(ch);
            return EngineAction::Pass;
        }
        // The buffer char must be analyzed as a vowel later (`wf` → `ừ`),
        // so store it as `u` with the horn flag; it renders as `ư`.
        buf.push(ch);
        if let Some(c) = buf.last_mut() {
            c.ch = if ch.is_uppercase() { 'U' } else { 'u' };
            c.horn = true;
        }
        buf.leading_w_expansion = true;
        let glyph = if ch.is_uppercase() { "Ư" } else { "ư" };
        return EngineAction::Replace {
            n: 0,
            chars: glyph.to_string(),
        };
    }

    let last = buf.last().copied().expect("non-empty checked");
    if cfg.repeated_restore && (last.horn || last.brev) {
        // ww escapes the shorthand ư entirely; uww escapes its horn only.
        let chars = if buf.len() == 1 && buf.leading_w_expansion {
            if last.is_upper() {
                "W".to_string()
            } else {
                "w".to_string()
            }
        } else {
            let c = buf.last_mut().unwrap();
            c.horn = false;
            c.brev = false;
            format!("{}{ch}", buf.render_last())
        };
        buf.clear();
        return EngineAction::Replace { n: 1, chars };
    }

    let eligible = match last.base_lc() {
        'a' => !last.hat && !last.brev,
        'o' => !last.horn,
        'u' => !last.horn,
        _ => false,
    };

    if eligible {
        match last.base_lc() {
            'a' => buf.set_last_brev(),
            'o' => buf.set_last_horn(),
            'u' => buf.set_last_horn(),
            _ => unreachable!("eligible matched a vowel"),
        }
        // `vowel_group` gives the horn precedence over the hat (ow → ơ even
        // if the o already carried a circumflex), so no flag fixing needed.
        EngineAction::Replace {
            n: 1,
            chars: buf.render_last(),
        }
    } else {
        buf.push(ch);
        EngineAction::Pass
    }
}
