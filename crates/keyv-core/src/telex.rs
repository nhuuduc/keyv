//! Telex input transforms, clean-room implementation.
//!
//! Public-key conventions implemented:
//! - `dd` → đ (stroke on the immediately preceding or syllable-initial plain d)
//! - duplicate vowel letter sets the circumflex (`aa` â, `ee` ê, `oo` ô)
//! - `w` sets breve/horn: after `a` → ă, after `o` → ơ, after `u` → ư, `uo` → ươ;
//!   a lone leading `w` may expand to ư (config `allow_w_consonant`)
//! - `s f r x j` select tone: sắc huyền hỏi ngã nặng
//!
//! Invalid transforms fall back to typing the pressed key literally
//! (the session buffer tracks it so the word keeps building).

use crate::config::{Config, InputMethod};
use crate::engine::{EngineAction, MAX_WORD_LEN};
use crate::tables::{Tone, is_valid_vi_initial};
use crate::word::{
    ViChar, WordBuffer, apply_tone, apply_uo_or_single_horn, diff_action, reanchor_existing_tone,
    rebalance_after_push,
};

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

    let lc = ch.to_lowercase().next().unwrap_or(ch);

    // Repeating a transformation key restores literal typing (aaa -> aa,
    // ddd -> dd). Preserve the original character's case and tone.
    if cfg.repeated_restore
        && let Some(last) = buf.last().copied()
    {
        if lc == 'd' && last.stroke {
            buf.last_mut().unwrap().stroke = false;
            let chars = format!("{}{ch}", buf.render_last());
            finish_escape(buf, cfg, ch);
            return EngineAction::Replace { n: 1, chars };
        }
        if matches!(lc, 'a' | 'e' | 'o') && last.base_lc() == lc && last.hat && !last.implicit_hat {
            buf.last_mut().unwrap().hat = false;
            let chars = format!("{}{ch}", buf.render_last());
            finish_escape(buf, cfg, ch);
            return EngineAction::Replace { n: 1, chars };
        }
    }

    if cfg.repeated_restore
        && lc == 'd'
        && buf.len() >= 2
        && buf.chars[0].stroke
        && matches!(cfg.method, InputMethod::Telex)
    {
        buf.chars[0].stroke = false;
        let n = buf.len() as u8;
        let chars = format!("{}{ch}", buf.render_from(0));
        finish_escape(buf, cfg, ch);
        return EngineAction::Replace { n, chars };
    }

    // `dd` → đ
    if lc == 'd' && buf.last_is_plain_d() {
        buf.set_last_stroke();
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return if cfg.repeated_restore {
                buf.restore_to_raw(&displayed_before)
            } else {
                buf.last_mut().unwrap().stroke = false;
                buf.push(ch);
                buf.passthrough = true;
                EngineAction::Pass
            };
        }
        return EngineAction::Replace {
            n: 1,
            chars: buf.render_last(),
        };
    }

    if lc == 'd'
        && matches!(cfg.method, InputMethod::Telex)
        && buf.len() >= 2
        && buf.chars[0].base_lc() == 'd'
        && !buf.chars[0].stroke
        && (!cfg.spell_check || buf.has_any_transform() || buf.len() >= 4)
        && !buf.analyze().nucleus.is_empty()
        && buf.is_valid_vietnamese()
    {
        buf.chars[0].stroke = true;
        let n = buf.len() as u8;
        return EngineAction::Replace {
            n,
            chars: buf.render_from(0),
        };
    }

    // tone keys — tone finalization does NOT close the session (Unikey-style:
    // words are separated by real separators; host resets on separators).
    if let Some(tone) = tone_of_key(lc) {
        if cfg.repeated_restore
            && let Some(idx) = buf.last_with_tone(tone)
        {
            buf.clear_tone_and_implicit_hat_at(idx);
            let tail = buf.render_from(idx);
            let n = buf.len() - idx;
            finish_escape(buf, cfg, ch);
            return EngineAction::Replace {
                n: n as u8,
                chars: format!("{tail}{ch}"),
            };
        }
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return push_and_check_spell(buf, cfg, ch, &displayed_before);
        }
        return apply_tone(buf, tone, cfg.orthography, ch);
    }

    match lc {
        // duplicate vowel → circumflex (adjacent or delayed in valid Vietnamese syllable)
        'a' | 'e' | 'o' => {
            if buf.last_is_dup_circ_candidate(lc) {
                let was_implicit = buf.last().is_some_and(|c| c.implicit_hat);
                buf.set_last_hat();
                let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
                if cfg.spell_check && !buf.is_valid_vietnamese() {
                    return if cfg.repeated_restore {
                        buf.restore_to_raw(&displayed_before)
                    } else {
                        buf.passthrough = true;
                        buf.restore_to_raw(&displayed_before)
                    };
                }
                let last_idx = buf.len() - 1;
                let start = tone_shift.map_or(last_idx, |s| s.min(last_idx));
                if was_implicit && start == last_idx {
                    return EngineAction::Replace {
                        n: 0,
                        chars: String::new(),
                    };
                }
                return EngineAction::Replace {
                    n: (buf.len() - start) as u8,
                    chars: buf.render_from(start),
                };
            }
            if let Some(action) = try_delayed_circumflex(buf, cfg, ch, lc) {
                return action;
            }
            push_and_check_spell(buf, cfg, ch, &displayed_before)
        }
        'w' => apply_w(buf, cfg, ch, &displayed_before),
        // `z` removes the last tone from the syllable (Unikey telex).
        'z' => {
            if let Some(idx) = buf.last_tone_idx() {
                buf.clear_tone_and_implicit_hat_at(idx);
                let n = buf.len() - idx;
                return EngineAction::Replace {
                    n: n as u8,
                    chars: buf.render_from(idx),
                };
            }
            push_and_check_spell(buf, cfg, ch, &displayed_before)
        }
        _ => push_and_check_spell(buf, cfg, ch, &displayed_before),
    }
}

fn finish_escape(buf: &mut WordBuffer, cfg: &Config, last_ch: char) {
    if cfg.spell_check {
        buf.raw_keys.pop();
        let current = format!("{}{last_ch}", buf.render_all());
        buf.raw_keys = current.chars().collect();
        buf.chars = current.chars().map(ViChar::from_char).collect();
        buf.leading_w_expansion = false;
        buf.passthrough = true;
    } else {
        buf.clear();
    }
}

fn push_and_check_spell(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    displayed_before: &str,
) -> EngineAction {
    buf.push(ch);
    if cfg.spell_check && !buf.is_valid_vietnamese() {
        if cfg.repeated_restore && buf.has_any_transform() {
            return buf.restore_to_raw(displayed_before);
        }
        buf.passthrough = true;
        return EngineAction::Pass;
    }
    rebalance_after_push(buf, cfg.orthography)
}

fn try_delayed_circumflex(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    lc: char,
) -> Option<EngineAction> {
    if !matches!(cfg.method, InputMethod::Telex) || buf.len() < 2 {
        return None;
    }
    let syl = buf.analyze();
    if syl.nucleus.is_empty() {
        return None;
    }

    if cfg.repeated_restore
        && let Some(&hat_idx) = syl
            .nucleus
            .iter()
            .rev()
            .find(|&&i| buf.chars[i].base_lc() == lc && buf.chars[i].hat)
    {
        if buf.chars[hat_idx].implicit_hat {
            buf.chars[hat_idx].implicit_hat = false;
            return Some(EngineAction::Replace {
                n: 0,
                chars: String::new(),
            });
        }
        buf.chars[hat_idx].hat = false;
        let n = (buf.len() - hat_idx) as u8;
        let chars = format!("{}{ch}", buf.render_from(hat_idx));
        finish_escape(buf, cfg, ch);
        return Some(EngineAction::Replace { n, chars });
    }

    if lc == 'o' && syl.coda_start == buf.len() && syl.nucleus.len() == 2 {
        let a = buf.chars[syl.nucleus[0]].base_lc();
        let b = buf.chars[syl.nucleus[1]].base_lc();
        if matches!((a, b), ('o', 'a') | ('o', 'e')) {
            return None;
        }
    }

    if !buf.is_valid_vietnamese() {
        return None;
    }

    let lcs: Vec<char> = buf.chars.iter().map(ViChar::base_lc).collect();
    let initial = &lcs[..syl.initial_end];
    let coda = &lcs[syl.coda_start..];
    if initial == ['p'] {
        return None;
    }
    if matches!(coda, ['c'] | ['c', 'h'] | ['p'] | ['t']) && buf.last_tone_idx().is_none() {
        return None;
    }
    if syl.nucleus.len() == 1 && coda.len() == 1 && !buf.has_any_transform() {
        return None;
    }

    let cand_idx = syl.nucleus.iter().rev().copied().find(|&i| {
        let c = &buf.chars[i];
        c.base_lc() == lc && !c.hat && !c.brev && !c.horn
    })?;

    if cand_idx == buf.len() - 1 {
        return None;
    }

    let mut trial = buf.clone();
    trial.chars[cand_idx].hat = true;
    if !trial.is_valid_vietnamese() {
        return None;
    }

    buf.chars[cand_idx].hat = true;
    buf.chars[cand_idx].implicit_hat = false;
    let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
    let start = tone_shift.map_or(cand_idx, |s| s.min(cand_idx));
    Some(EngineAction::Replace {
        n: (buf.len() - start) as u8,
        chars: buf.render_from(start),
    })
}

fn apply_w(buf: &mut WordBuffer, cfg: &Config, ch: char, displayed_before: &str) -> EngineAction {
    let allow_shorthand_u = !cfg.allow_w_consonant && matches!(cfg.method, InputMethod::Telex);

    if buf.is_empty() {
        if !allow_shorthand_u {
            return push_and_check_spell(buf, cfg, ch, displayed_before);
        }
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
        let chars = if buf.len() == 1 && buf.leading_w_expansion {
            if last.is_upper() {
                "W".to_string()
            } else {
                "w".to_string()
            }
        } else {
            let mut start = buf.len() - 1;
            let prev_idx = buf.len().saturating_sub(2);
            if last.base_lc() == 'o'
                && last.horn
                && buf.len() >= 2
                && buf.chars[prev_idx].base_lc() == 'u'
                && buf.chars[prev_idx].horn
            {
                buf.chars[prev_idx].horn = false;
                buf.chars[prev_idx].implicit_horn = false;
                start = prev_idx;
            }
            let c = buf.last_mut().unwrap();
            c.horn = false;
            c.implicit_horn = false;
            c.brev = false;
            let n = (buf.len() - start) as u8;
            let out = format!("{}{ch}", buf.render_from(start));
            finish_escape(buf, cfg, ch);
            return EngineAction::Replace { n, chars: out };
        };
        finish_escape(buf, cfg, ch);
        return EngineAction::Replace { n: 1, chars };
    }

    let syl = buf.analyze();

    let compound_override_idx = if syl.nucleus.len() == 2
        && syl.coda_start == buf.len()
        && buf.chars[syl.nucleus[0]].base_lc() == 'u'
        && !buf.chars[syl.nucleus[0]].horn
        && matches!(buf.chars[syl.nucleus[1]].base_lc(), 'a' | 'u')
        && !buf.chars[syl.nucleus[1]].brev
        && !buf.chars[syl.nucleus[1]].hat
        && !buf.chars[syl.nucleus[1]].horn
    {
        Some(syl.nucleus[0])
    } else if syl.nucleus.len() == 3
        && syl.coda_start == buf.len()
        && buf.chars[syl.nucleus[0]].base_lc() == 'u'
        && buf.chars[syl.nucleus[1]].base_lc() == 'o'
        && buf.chars[syl.nucleus[2]].base_lc() == 'u'
        && (!buf.chars[syl.nucleus[0]].horn || !buf.chars[syl.nucleus[1]].horn)
    {
        Some(syl.nucleus[1])
    } else {
        None
    };

    if let Some(target_idx) = compound_override_idx {
        if cfg.spell_check {
            let lcs_init: Vec<char> = buf.chars[..syl.initial_end]
                .iter()
                .map(ViChar::base_lc)
                .collect();
            if !is_valid_vi_initial(&lcs_init, buf.chars[0].stroke) {
                return push_and_check_spell(buf, cfg, ch, displayed_before);
            }
        }
        let start = apply_uo_or_single_horn(buf, &syl, target_idx);
        let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
        let final_start = tone_shift.map_or(start, |s| s.min(start));
        return EngineAction::Replace {
            n: (buf.len() - final_start) as u8,
            chars: buf.render_from(final_start),
        };
    }

    let adjacent_eligible = match last.base_lc() {
        'a' if !last.hat && !last.brev => {
            syl.nucleus.len() <= 1
                || (syl.nucleus.len() == 2
                    && buf.chars[syl.nucleus[0]].base_lc() == 'o'
                    && !buf.chars[syl.nucleus[0]].horn
                    && !buf.chars[syl.nucleus[0]].hat)
        }
        'o' if !last.horn => {
            syl.nucleus.len() <= 1
                || (syl.nucleus.len() == 2 && buf.chars[syl.nucleus[0]].base_lc() == 'u')
        }
        'u' if !last.horn => syl.nucleus.len() <= 1,
        _ => false,
    };

    if adjacent_eligible {
        if cfg.spell_check {
            let lcs_init: Vec<char> = buf.chars[..syl.initial_end]
                .iter()
                .map(ViChar::base_lc)
                .collect();
            if !is_valid_vi_initial(&lcs_init, buf.chars[0].stroke) {
                return push_and_check_spell(buf, cfg, ch, displayed_before);
            }
        }
        let last_idx = buf.len() - 1;
        let start = match last.base_lc() {
            'a' => {
                buf.set_last_brev();
                last_idx
            }
            'o' | 'u' => apply_uo_or_single_horn(buf, &syl, last_idx),
            _ => unreachable!(),
        };
        let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
        let final_start = tone_shift.map_or(start, |s| s.min(start));
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return if cfg.repeated_restore {
                buf.restore_to_raw(displayed_before)
            } else {
                buf.passthrough = true;
                diff_action(displayed_before, &buf.raw_string())
            };
        }
        return EngineAction::Replace {
            n: (buf.len() - final_start) as u8,
            chars: buf.render_from(final_start),
        };
    }

    if allow_shorthand_u && syl.nucleus.is_empty() {
        let lcs_init: Vec<char> = buf.chars.iter().map(ViChar::base_lc).collect();
        if is_valid_vi_initial(&lcs_init, buf.chars[0].stroke) && lcs_init != ['q'] {
            buf.push(ch);
            if let Some(c) = buf.last_mut() {
                c.ch = if ch.is_uppercase() { 'U' } else { 'u' };
                c.horn = true;
            }
            let glyph = if ch.is_uppercase() { "Ư" } else { "ư" };
            return EngineAction::Replace {
                n: 0,
                chars: glyph.to_string(),
            };
        }
    }

    if matches!(cfg.method, InputMethod::Telex)
        && !syl.nucleus.is_empty()
        && let Some(action) = try_delayed_w(buf, cfg, &syl, ch)
    {
        return action;
    }

    push_and_check_spell(buf, cfg, ch, displayed_before)
}

fn try_delayed_w(
    buf: &mut WordBuffer,
    cfg: &Config,
    syl: &crate::word::Syllable,
    ch: char,
) -> Option<EngineAction> {
    let target = find_delayed_w_target(buf, syl);

    if target.is_none() {
        if cfg.repeated_restore
            && let Some(&first_marked) = syl
                .nucleus
                .iter()
                .find(|&&i| buf.chars[i].horn || buf.chars[i].brev)
        {
            for &i in &syl.nucleus {
                buf.chars[i].horn = false;
                buf.chars[i].implicit_horn = false;
                buf.chars[i].brev = false;
            }
            let n = (buf.len() - first_marked) as u8;
            let chars = format!("{}{ch}", buf.render_from(first_marked));
            finish_escape(buf, cfg, ch);
            return Some(EngineAction::Replace { n, chars });
        }
        return None;
    }

    if !buf.is_valid_vietnamese() {
        return None;
    }

    let target_idx = target?;
    let mut trial = buf.clone();
    let trial_start = if trial.chars[target_idx].base_lc() == 'a' {
        trial.chars[target_idx].brev = true;
        target_idx
    } else {
        apply_uo_or_single_horn(&mut trial, syl, target_idx)
    };
    if !trial.is_valid_vietnamese() {
        return None;
    }

    *buf = trial;
    let tone_shift = reanchor_existing_tone(buf, cfg.orthography);
    let start = tone_shift.map_or(trial_start, |s| s.min(trial_start));
    Some(EngineAction::Replace {
        n: (buf.len() - start) as u8,
        chars: buf.render_from(start),
    })
}

fn find_delayed_w_target(buf: &WordBuffer, syl: &crate::word::Syllable) -> Option<usize> {
    for win in syl.nucleus.windows(2) {
        let u_idx = win[0];
        let o_idx = win[1];
        if buf.chars[u_idx].base_lc() == 'u'
            && buf.chars[o_idx].base_lc() == 'o'
            && (!buf.chars[o_idx].horn || !buf.chars[u_idx].horn)
        {
            return Some(o_idx);
        }
    }
    if syl.nucleus.len() == 2 {
        let first = syl.nucleus[0];
        let second = syl.nucleus[1];
        if buf.chars[first].base_lc() == 'o'
            && buf.chars[second].base_lc() == 'a'
            && !buf.chars[second].hat
            && !buf.chars[second].brev
        {
            return Some(second);
        }
        if matches!(
            (buf.chars[first].base_lc(), buf.chars[second].base_lc()),
            ('u', 'a') | ('u', 'i') | ('u', 'u') | ('o', 'i')
        ) && !buf.chars[first].horn
            && !buf.chars[first].hat
        {
            return Some(first);
        }
    }
    if syl.nucleus.len() == 1 {
        let idx = syl.nucleus[0];
        let c = &buf.chars[idx];
        match c.base_lc() {
            'a' if !c.hat && !c.brev => return Some(idx),
            'o' | 'u' if !c.horn => return Some(idx),
            _ => {}
        }
    }
    None
}
