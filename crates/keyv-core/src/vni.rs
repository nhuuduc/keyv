//! VNI input transforms, clean-room implementation.
//!
//! Digit conventions (Unikey-compatible VNI layout):
//! - `1 2 3 4 5` → sắc huyền hỏi ngã nặng (tone placement per pair rules)
//! - `6` → circumflex on the rightmost markable vowel (`toi6` → tôi)
//! - `7` → horn (ơ ư ươ)
//! - `8` → breve (ă)
//! - `9` → stroke on a plain d (đ, adjacent `d9` or delayed `dang9`)
//! - `0` → strip the tone from the placement target
//!
//! On an inapplicable digit the engine restores it literally and the word
//! session restarts (matching Unikey VNI behavior).

use crate::config::Config;
use crate::engine::{EngineAction, MAX_WORD_LEN};
use crate::tables::Tone;
use crate::word::{
    WordBuffer, apply_tone, apply_uo_or_single_horn, last_markable, reanchor_existing_tone,
    rebalance_after_push,
};

pub fn step(buf: &mut WordBuffer, cfg: &Config, ch: char) -> EngineAction {
    if buf.len() >= MAX_WORD_LEN {
        buf.clear();
    }
    let lc = ch.to_lowercase().next().unwrap_or(ch);

    if lc.is_ascii_alphabetic() {
        let displayed_before = if cfg.spell_check {
            buf.render_all()
        } else {
            String::new()
        };
        buf.record_raw(ch);
        if buf.passthrough {
            buf.push(ch);
            return EngineAction::Pass;
        }
        buf.push(ch);
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            if cfg.repeated_restore && buf.has_any_transform() {
                return buf.restore_to_raw(&displayed_before);
            }
            buf.passthrough = true;
            return EngineAction::Pass;
        }
        return rebalance_after_push(buf, cfg.orthography);
    }

    let digit = match lc {
        '0'..='9' => lc,
        _ => {
            buf.clear();
            return EngineAction::Pass;
        }
    };

    if buf.passthrough {
        buf.clear();
        return EngineAction::Pass;
    }

    let syl = buf.analyze();
    // `9` strokes a plain `d` even when no vowel exists yet ("d9" → đ);
    // every other digit needs a vowel nucleus.
    if syl.nucleus.is_empty() && digit != '9' {
        buf.clear();
        return EngineAction::Pass;
    }

    match digit {
        '0'..='5' => {
            if digit == '0' {
                if let Some(idx) = buf.last_tone_idx() {
                    buf.clear_tone_and_implicit_hat_at(idx);
                    let n = (buf.len() - idx) as u8;
                    return EngineAction::Replace {
                        n,
                        chars: buf.render_from(idx),
                    };
                }
                buf.clear();
                EngineAction::Pass
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
                buf.record_raw(ch);
                apply_tone(buf, tone, cfg.orthography, ch)
            }
        }
        '6' | '7' | '8' => {
            let eligible_idx = |c: &crate::word::ViChar| -> bool {
                match digit {
                    '6' => {
                        matches!(c.base_lc(), 'a' | 'e' | 'o')
                            && (!c.hat || c.implicit_hat)
                            && !c.brev
                    }
                    '7' => matches!(c.base_lc(), 'o' | 'u') && !c.horn,
                    '8' => c.base_lc() == 'a' && !c.hat && !c.brev,
                    _ => false,
                }
            };
            let target_opt = if digit == '7'
                && syl.nucleus.len() == 3
                && buf.chars[syl.nucleus[0]].base_lc() == 'u'
                && buf.chars[syl.nucleus[1]].base_lc() == 'o'
                && buf.chars[syl.nucleus[2]].base_lc() == 'u'
                && (!buf.chars[syl.nucleus[0]].horn || !buf.chars[syl.nucleus[1]].horn)
            {
                Some(syl.nucleus[1])
            } else {
                last_markable(&buf.chars, &syl.nucleus, eligible_idx)
            };
            match target_opt {
                Some(idx) => {
                    buf.record_raw(ch);
                    let start = match digit {
                        '6' => {
                            buf.chars[idx].hat = true;
                            buf.chars[idx].implicit_hat = false;
                            buf.chars[idx].horn = false;
                            idx
                        }
                        '7' => apply_uo_or_single_horn(buf, &syl, idx),
                        '8' => {
                            buf.chars[idx].brev = true;
                            idx
                        }
                        _ => unreachable!(),
                    };
                    let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
                    let final_start = tone_shift.map_or(start, |s| s.min(start));
                    let n = buf.len() - final_start;
                    EngineAction::Replace {
                        n: n as u8,
                        chars: buf.render_from(final_start),
                    }
                }
                None => {
                    if cfg.repeated_restore {
                        let marked_match = syl.nucleus.iter().copied().find(|&i| {
                            let c = &buf.chars[i];
                            match digit {
                                '6' => c.hat && !c.implicit_hat,
                                '7' => c.horn,
                                '8' => c.brev,
                                _ => false,
                            }
                        });
                        if let Some(first_idx) = marked_match {
                            for &i in &syl.nucleus {
                                match digit {
                                    '6' => {
                                        buf.chars[i].hat = false;
                                        buf.chars[i].implicit_hat = false;
                                    }
                                    '7' => {
                                        buf.chars[i].horn = false;
                                        buf.chars[i].implicit_horn = false;
                                    }
                                    '8' => buf.chars[i].brev = false,
                                    _ => {}
                                }
                            }
                            let n = (buf.len() - first_idx) as u8;
                            let chars = format!("{}{ch}", buf.render_from(first_idx));
                            buf.clear();
                            return EngineAction::Replace { n, chars };
                        }
                    }
                    buf.clear();
                    EngineAction::Pass
                }
            }
        }
        '9' => {
            if buf.last_is_plain_d() {
                buf.record_raw(ch);
                buf.set_last_stroke();
                EngineAction::Replace {
                    n: 1,
                    chars: buf.render_last(),
                }
            } else if !buf.is_empty() && buf.chars[0].base_lc() == 'd' && !buf.chars[0].stroke {
                buf.record_raw(ch);
                buf.chars[0].stroke = true;
                EngineAction::Replace {
                    n: buf.len() as u8,
                    chars: buf.render_from(0),
                }
            } else if cfg.repeated_restore && !buf.is_empty() && buf.chars[0].stroke {
                buf.chars[0].stroke = false;
                let n = buf.len() as u8;
                let chars = format!("{}{ch}", buf.render_from(0));
                buf.clear();
                EngineAction::Replace { n, chars }
            } else if cfg.repeated_restore && buf.last().is_some_and(|c| c.stroke) {
                let idx = buf.len() - 1;
                buf.chars[idx].stroke = false;
                let chars = format!("{}{ch}", buf.render_from(idx));
                buf.clear();
                EngineAction::Replace { n: 1, chars }
            } else {
                buf.clear();
                EngineAction::Pass
            }
        }
        _ => unreachable!("digit matched all arms"),
    }
}
