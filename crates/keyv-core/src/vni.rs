//! VNI input transforms, clean-room implementation.
//!
//! Digit conventions (Unikey-compatible VNI layout):
//! - `1 2 3 4 5` → sắc huyền hỏi ngã nặng (tone placement per pair rules)
//! - `6` → circumflex on the rightmost markable vowel (`toi6` → tôi)
//! - `7` → horn (ơ ư)
//! - `8` → breve (ă)
//! - `9` → stroke on a plain d (đ)
//! - `0` → strip the tone from the placement target
//!
//! On an inapplicable digit the engine restores it literally and the word
//! session restarts (matching Unikey VNI behavior).

use crate::config::Config;
use crate::engine::{EngineAction, MAX_WORD_LEN};
use crate::tables::Tone;
use crate::word::{WordBuffer, apply_tone, last_markable, set_tone_at};

pub fn step(buf: &mut WordBuffer, cfg: &Config, ch: char) -> EngineAction {
    if buf.len() >= MAX_WORD_LEN {
        buf.clear();
    }
    let lc = ch.to_lowercase().next().unwrap_or(ch);

    if lc.is_ascii_alphabetic() {
        buf.push(ch);
        return EngineAction::Pass;
    }

    let digit = match lc {
        '0'..='9' => lc,
        _ => {
            buf.clear();
            return EngineAction::Pass;
        }
    };

    let syl = buf.analyze();
    // `9` strokes a plain `d` even when no vowel exists yet ("d9" → đ);
    // every other digit needs a vowel nucleus.
    if syl.nucleus.is_empty() && digit != '9' {
        // nothing to modify: restore digit, reset session
        buf.clear();
        return EngineAction::Pass;
    }

    match digit {
        '0'..='5' => {
            if digit == '0' {
                // strip tone from the placement target; session continues
                let idx = crate::word::tone_target(&buf.chars, &syl, cfg.orthography).unwrap();
                set_tone_at(buf, idx, Tone::None)
            } else {
                let tone = match digit {
                    '1' => Tone::Sac,
                    '2' => Tone::Huyen,
                    '3' => Tone::Hoi,
                    '4' => Tone::Nga,
                    '5' => Tone::Nang,
                    _ => unreachable!(),
                };
                if cfg.repeated_restore
                    && let Some(idx) = buf.last_with_tone(tone)
                {
                    buf.clear_tone_and_implicit_hat_at(idx);
                    let n = (buf.len() - idx) as u8;
                    let chars = format!("{}{ch}", buf.render_from(idx));
                    buf.clear();
                    return EngineAction::Replace { n, chars };
                }
                apply_tone(buf, tone, cfg.orthography, ch)
            }
        }
        '6' | '7' | '8' => {
            let eligible_idx = |c: &crate::word::ViChar| -> bool {
                match digit {
                    '6' => matches!(c.base_lc(), 'a' | 'e' | 'o') && !c.hat && !c.brev,
                    '7' => matches!(c.base_lc(), 'o' | 'u') && !c.horn,
                    '8' => c.base_lc() == 'a' && !c.hat && !c.brev,
                    _ => false,
                }
            };
            match last_markable(&buf.chars, &syl.nucleus, eligible_idx) {
                Some(idx) => {
                    match digit {
                        '6' => buf.chars[idx].hat = true,
                        '7' => buf.chars[idx].horn = true,
                        '8' => buf.chars[idx].brev = true,
                        _ => unreachable!(),
                    }
                    let n = buf.len() - idx;
                    EngineAction::Replace {
                        n: n as u8,
                        chars: buf.render_from(idx),
                    }
                }
                None => {
                    buf.clear();
                    EngineAction::Pass
                }
            }
        }
        '9' => {
            if buf.last_is_plain_d() {
                buf.set_last_stroke();
                EngineAction::Replace {
                    n: 1,
                    chars: buf.render_last(),
                }
            } else {
                buf.clear();
                EngineAction::Pass
            }
        }
        _ => unreachable!("digit matched all arms"),
    }
}
