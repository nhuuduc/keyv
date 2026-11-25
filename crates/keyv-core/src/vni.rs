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
    DisplayedSnapshot, ViChar, WordBuffer, apply_tone, apply_uo_or_single_horn, last_markable,
    reanchor_existing_tone, rebalance_after_push,
};

pub fn step(buf: &mut WordBuffer, cfg: &Config, ch: char) -> EngineAction {
    if buf.len() >= MAX_WORD_LEN {
        buf.passthrough = true;
        buf.overflow_count += 1;
        return EngineAction::Pass;
    }

    let displayed = DisplayedSnapshot::capture(buf);
    let lc = ch.to_lowercase().next().unwrap_or(ch);

    if lc.is_ascii_alphabetic() {
        buf.record_raw(ch);
        if buf.passthrough {
            buf.push(ch);
            buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
            return EngineAction::Pass;
        }
        if cfg.spell_check
            && ch.is_ascii_uppercase()
            && buf.raw_keys.len() >= 3
            && buf.raw_keys[..buf.raw_keys.len() - 1]
                .iter()
                .any(|c| c.is_ascii_lowercase())
        {
            buf.push(ch);
            if buf.has_any_transform() {
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
            buf.passthrough = true;
            buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
            return EngineAction::Pass;
        }
        buf.push(ch);
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            if buf.has_any_transform() {
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
            buf.passthrough = true;
            buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
            return displayed.diff_to_buf(buf, Some(ch));
        }
        let _ = rebalance_after_push(buf, cfg.orthography);
        return displayed.diff_to_buf(buf, Some(ch));
    }

    let digit = match lc {
        '0'..='9' => lc,
        _ => {
            buf.clear();
            return EngineAction::Pass;
        }
    };

    if buf.passthrough {
        buf.record_raw(ch);
        buf.push(ch);
        return EngineAction::Pass;
    }

    let syl = buf.analyze();
    // `9` strokes a plain `d` even when no vowel exists yet ("d9" → đ);
    // every other digit needs a vowel nucleus.
    if syl.nucleus.is_empty() && digit != '9' {
        return fallback_vni_digit(buf, cfg, ch, &displayed);
    }

    match digit {
        '0'..='5' => {
            if digit == '0' {
                if let Some(idx) = buf.last_tone_idx() {
                    buf.record_raw(ch);
                    let coda: Vec<char> = buf.chars[syl.coda_start..]
                        .iter()
                        .map(ViChar::base_lc)
                        .collect();
                    if cfg.spell_check
                        && matches!(coda.as_slice(), ['c'] | ['c', 'h'] | ['p'] | ['t'])
                    {
                        return buf.restore_to_raw_from(&displayed, Some(ch));
                    }
                    buf.clear_tone_and_implicit_hat_at(idx);
                    if !cfg.spell_check || buf.has_explicit_mark() || syl.coda_start < buf.len() {
                        buf.sync_raw_keys_from_chars(cfg.method);
                    }
                    return displayed.diff_to_buf(buf, Some(ch));
                }
                fallback_vni_digit(buf, cfg, ch, &displayed)
            } else {
                let tone = match digit {
                    '1' => Tone::Sac,
                    '2' => Tone::Huyen,
                    '3' => Tone::Hoi,
                    '4' => Tone::Nga,
                    '5' => Tone::Nang,
                    _ => unreachable!(),
                };
                if let Some(existing_idx) = buf.last_tone_idx() {
                    let existing_tone = buf.chars[existing_idx].tone;
                    if existing_tone == tone && cfg.repeated_restore {
                        buf.record_raw(ch);
                        buf.clear_tone_and_implicit_hat_at(existing_idx);
                        let target = format!("{}{ch}", buf.render_all());
                        finish_vni_escape(buf, ch);
                        return displayed.diff_to_str(&target, Some(ch));
                    }
                    if existing_tone != tone && cfg.spell_check && !buf.has_explicit_mark() {
                        buf.record_raw(ch);
                        return buf.restore_to_raw_from(&displayed, Some(ch));
                    }
                }
                if cfg.spell_check && !buf.is_valid_vietnamese() {
                    return fallback_vni_digit(buf, cfg, ch, &displayed);
                }
                buf.record_raw(ch);
                let _ = apply_tone(buf, tone, cfg.orthography, ch);
                let invalid_stop_tone = {
                    let syl2 = buf.analyze();
                    let coda: Vec<char> = buf.chars[syl2.coda_start..]
                        .iter()
                        .map(ViChar::base_lc)
                        .collect();
                    matches!(coda.as_slice(), ['c'] | ['c', 'h'] | ['p'] | ['t'])
                        && !matches!(tone, Tone::Sac | Tone::Nang)
                };
                if cfg.spell_check && (invalid_stop_tone || !buf.is_valid_vietnamese()) {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
                displayed.diff_to_buf(buf, Some(ch))
            }
        }
        '6' | '7' | '8' => {
            let eligible_idx = |c: &ViChar| -> bool {
                match digit {
                    '6' => matches!(c.base_lc(), 'a' | 'e' | 'o') && (!c.hat || c.implicit_hat),
                    '7' => matches!(c.base_lc(), 'o' | 'u') && !c.horn,
                    '8' => c.base_lc() == 'a' && !c.brev,
                    _ => false,
                }
            };
            let target_opt = if digit == '7'
                && syl.nucleus.len() == 2
                && buf.chars[syl.nucleus[0]].base_lc() == 'u'
                && buf.chars[syl.nucleus[1]].base_lc() == 'u'
                && !buf.chars[syl.nucleus[1]].horn
            {
                if !buf.chars[syl.nucleus[0]].horn {
                    Some(syl.nucleus[0])
                } else {
                    None
                }
            } else if digit == '7'
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
                    match digit {
                        '6' => {
                            if buf.chars[idx].base_lc() == 'o'
                                && let Some(pos) = syl.nucleus.iter().position(|&i| i == idx)
                                && pos > 0
                            {
                                let prev_idx = syl.nucleus[pos - 1];
                                if buf.chars[prev_idx].base_lc() == 'u'
                                    && buf.chars[prev_idx].implicit_horn
                                {
                                    buf.chars[prev_idx].horn = false;
                                    buf.chars[prev_idx].implicit_horn = false;
                                }
                            }
                            buf.chars[idx].hat = true;
                            buf.chars[idx].implicit_hat = false;
                            buf.chars[idx].horn = false;
                            buf.chars[idx].implicit_horn = false;
                            buf.chars[idx].brev = false;
                        }
                        '7' => {
                            let _ = apply_uo_or_single_horn(buf, &syl, idx);
                        }
                        '8' => {
                            buf.chars[idx].brev = true;
                            buf.chars[idx].hat = false;
                            buf.chars[idx].implicit_hat = false;
                        }
                        _ => unreachable!(),
                    }
                    let _ = reanchor_existing_tone(buf, cfg.orthography);
                    if cfg.spell_check && !buf.is_valid_vietnamese() {
                        return buf.restore_to_raw_from(&displayed, Some(ch));
                    }
                    displayed.diff_to_buf(buf, Some(ch))
                }
                None => {
                    if cfg.repeated_restore {
                        let marked_match = syl.nucleus.iter().copied().any(|i| {
                            let c = &buf.chars[i];
                            match digit {
                                '6' => c.hat && !c.implicit_hat,
                                '7' => c.horn,
                                '8' => c.brev,
                                _ => false,
                            }
                        });
                        if marked_match {
                            buf.record_raw(ch);
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
                            let _ = reanchor_existing_tone(buf, cfg.orthography);
                            let target = format!("{}{ch}", buf.render_all());
                            finish_vni_escape(buf, ch);
                            return displayed.diff_to_str(&target, Some(ch));
                        }
                    }
                    fallback_vni_digit(buf, cfg, ch, &displayed)
                }
            }
        }
        '9' => {
            if buf.last_is_plain_d() {
                buf.record_raw(ch);
                buf.set_last_stroke();
                if cfg.spell_check && !buf.is_valid_vietnamese() {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
                displayed.diff_to_buf(buf, Some(ch))
            } else if !buf.is_empty()
                && buf.chars[0].base_lc() == 'd'
                && !buf.chars[0].stroke
                && (!cfg.spell_check || (!syl.nucleus.is_empty() && buf.is_valid_vietnamese()))
            {
                buf.record_raw(ch);
                buf.chars[0].stroke = true;
                if cfg.spell_check && !buf.is_valid_vietnamese() {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
                let _ = rebalance_after_push(buf, cfg.orthography);
                displayed.diff_to_buf(buf, Some(ch))
            } else if cfg.repeated_restore && buf.last().is_some_and(|c| c.stroke) {
                buf.record_raw(ch);
                let idx = buf.len() - 1;
                buf.chars[idx].stroke = false;
                let target = format!("{}{ch}", buf.render_all());
                finish_vni_escape(buf, ch);
                displayed.diff_to_str(&target, Some(ch))
            } else if cfg.repeated_restore
                && !buf.is_empty()
                && buf.chars[0].stroke
                && !syl.nucleus.is_empty()
            {
                buf.record_raw(ch);
                buf.chars[0].stroke = false;
                let target = format!("{}{ch}", buf.render_all());
                finish_vni_escape(buf, ch);
                displayed.diff_to_str(&target, Some(ch))
            } else {
                fallback_vni_digit(buf, cfg, ch, &displayed)
            }
        }
        _ => unreachable!("digit matched all arms"),
    }
}

fn finish_vni_escape(buf: &mut WordBuffer, last_ch: char) {
    let current = format!("{}{last_ch}", buf.render_all());
    buf.raw_keys = current.chars().collect();
    buf.chars = current.chars().map(ViChar::from_char).collect();
    buf.leading_w_expansion = false;
    buf.passthrough = true;
}

fn fallback_vni_digit(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    displayed: &DisplayedSnapshot,
) -> EngineAction {
    buf.record_raw(ch);
    if cfg.spell_check && buf.has_any_transform() {
        return buf.restore_to_raw_from(displayed, Some(ch));
    }
    buf.push(ch);
    buf.passthrough = true;
    buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
    EngineAction::Pass
}
