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
use crate::tables::{Tone, is_valid_vi_initial, is_vowel_base};
use crate::word::{
    DisplayedSnapshot, EscapedDoubleTone, ViChar, WordBuffer, apply_tone, apply_uo_or_single_horn,
    reanchor_existing_tone, rebalance_after_push,
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
        buf.passthrough = true;
        buf.overflow_count += 1;
        return EngineAction::Pass;
    }

    let displayed = DisplayedSnapshot::capture(buf);
    buf.record_raw(ch);
    let lc = ch.to_lowercase().next().unwrap_or(ch);

    if buf.passthrough {
        if buf.escaped_mark_raw_pending {
            buf.escaped_mark_raw_pending = false;
            return buf.restore_to_raw_from(&displayed, Some(ch));
        }
        match buf.escaped_double_tone {
            EscapedDoubleTone::None => {}
            EscapedDoubleTone::Pending('d') => {
                buf.escaped_double_tone = EscapedDoubleTone::None;
                if lc == 'y' {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
            }
            EscapedDoubleTone::Pending('f') => {
                if lc == 'e' {
                    buf.escaped_double_tone = EscapedDoubleTone::PendingAfterFE;
                    buf.push(ch);
                    return EngineAction::Pass;
                }
                buf.escaped_double_tone = EscapedDoubleTone::None;
                if is_vowel_base(lc) || matches!(lc, 'l' | 'r') {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
            }
            EscapedDoubleTone::Pending(_) => {
                buf.escaped_double_tone = EscapedDoubleTone::None;
                if lc != 'e' && is_vowel_base(lc) {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
            }
            EscapedDoubleTone::PendingAfterFE => {
                buf.escaped_double_tone = EscapedDoubleTone::None;
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
        }
        buf.push(ch);
        buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
        return EngineAction::Pass;
    }

    let was_stripped_by_z = buf.stripped_tone_by_z;
    buf.stripped_tone_by_z = false;
    if was_stripped_by_z && lc == 'z' {
        buf.push(ch);
        buf.passthrough = true;
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

    let prev_raw_lc = buf
        .raw_keys
        .len()
        .checked_sub(2)
        .and_then(|i| buf.raw_keys[i].to_lowercase().next());

    // Repeating a transformation key restores literal typing (aaa -> aa,
    // ddd -> dd). Preserve the original character's case and tone.
    if cfg.repeated_restore
        && (!cfg.spell_check || prev_raw_lc == Some(lc))
        && let Some(last) = buf.last().copied()
    {
        if lc == 'd' && last.stroke {
            buf.last_mut().unwrap().stroke = false;
            let target = format!("{}{ch}", buf.render_all());
            finish_escape(buf, ch);
            return displayed.diff_to_str(&target, Some(ch));
        }
        if matches!(lc, 'a' | 'e' | 'o') && last.base_lc() == lc && last.hat && !last.implicit_hat {
            if lc == 'o' && cfg.spell_check && last.tone == Tone::None {
                let syl = buf.analyze();
                if syl.initial_end > 0
                    && syl.nucleus.as_slice() == [buf.len() - 1]
                    && buf.is_valid_vietnamese()
                {
                    buf.last_mut().unwrap().hat = false;
                    buf.push(ch);
                    buf.escaped_oo = true;
                    buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
                    return displayed.diff_to_buf(buf, Some(ch));
                }
            }
            buf.last_mut().unwrap().hat = false;
            let target = format!("{}{ch}", buf.render_all());
            finish_escape(buf, ch);
            return displayed.diff_to_str(&target, Some(ch));
        }
    }

    if cfg.repeated_restore
        && (!cfg.spell_check || prev_raw_lc == Some('d'))
        && lc == 'd'
        && buf.len() >= 2
        && buf.chars[0].stroke
        && !buf.analyze().nucleus.is_empty()
        && !buf.last_is_plain_d()
        && matches!(cfg.method, InputMethod::Telex)
    {
        buf.chars[0].stroke = false;
        let had_other_explicit_mark = buf.has_explicit_mark();
        let target = format!("{}{ch}", buf.render_all());
        if cfg.spell_check && prev_raw_lc == Some('d') && !had_other_explicit_mark {
            buf.chars = target.chars().map(ViChar::from_char).collect();
            buf.leading_w_expansion = false;
            buf.passthrough = true;
            buf.escaped_double_tone = EscapedDoubleTone::Pending('d');
        } else if cfg.spell_check && had_other_explicit_mark {
            buf.chars = target.chars().map(ViChar::from_char).collect();
            buf.leading_w_expansion = false;
            buf.passthrough = true;
            buf.escaped_mark_raw_pending = true;
        } else {
            finish_escape(buf, ch);
        }
        return displayed.diff_to_str(&target, Some(ch));
    }

    // `dd` → đ
    if lc == 'd' && buf.last_is_plain_d() {
        buf.set_last_stroke();
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            buf.last_mut().unwrap().stroke = false;
            buf.push(ch);
            if buf.has_any_transform() {
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
            buf.passthrough = true;
            buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
            return displayed.diff_to_buf(buf, Some(ch));
        }
        return displayed.diff_to_buf(buf, Some(ch));
    }

    if lc == 'd'
        && matches!(cfg.method, InputMethod::Telex)
        && buf.len() >= 2
        && buf.chars[0].base_lc() == 'd'
        && !buf.chars[0].stroke
        && !buf.analyze().nucleus.is_empty()
        && buf.is_valid_vietnamese()
    {
        buf.chars[0].stroke = true;
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            buf.chars[0].stroke = false;
            return push_and_check_spell(buf, cfg, ch, &displayed);
        }
        let _ = rebalance_after_push(buf, cfg.orthography);
        return displayed.diff_to_buf(buf, Some(ch));
    }

    // tone keys — tone finalization does NOT close the session (Unikey-style:
    // words are separated by real separators; host resets on separators).
    if let Some(tone) = tone_of_key(lc) {
        if let Some(existing_idx) = buf.last_tone_idx() {
            let existing_tone = buf.chars[existing_idx].tone;
            let prev_is_tone = prev_raw_lc.and_then(tone_of_key).is_some();
            if !prev_is_tone
                && !buf.has_explicit_mark()
                && (cfg.spell_check || (existing_tone == tone && cfg.repeated_restore))
            {
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
            if existing_tone == tone && cfg.repeated_restore {
                buf.clear_tone_and_implicit_hat_at(existing_idx);
                let still_has_explicit_mark = buf.has_explicit_mark();
                let target = format!("{}{ch}", buf.render_all());
                if cfg.spell_check && !still_has_explicit_mark && matches!(lc, 's' | 'f' | 'r') {
                    buf.chars = target.chars().map(ViChar::from_char).collect();
                    buf.leading_w_expansion = false;
                    buf.passthrough = true;
                    buf.escaped_double_tone = EscapedDoubleTone::Pending(lc);
                } else if cfg.spell_check && still_has_explicit_mark {
                    buf.chars = target.chars().map(ViChar::from_char).collect();
                    buf.leading_w_expansion = false;
                    buf.passthrough = true;
                    buf.escaped_mark_raw_pending = true;
                } else {
                    finish_escape(buf, ch);
                }
                return displayed.diff_to_str(&target, Some(ch));
            }
        }
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return push_and_check_spell(buf, cfg, ch, &displayed);
        }
        let _ = apply_tone(buf, tone, cfg.orthography, ch);
        let invalid_stop_tone = {
            let syl = buf.analyze();
            let coda: Vec<char> = buf.chars[syl.coda_start..]
                .iter()
                .map(ViChar::base_lc)
                .collect();
            matches!(coda.as_slice(), ['c'] | ['c', 'h'] | ['p'] | ['t'])
                && !matches!(tone, Tone::Sac | Tone::Nang)
        };
        if cfg.spell_check && (invalid_stop_tone || !buf.is_valid_vietnamese()) {
            if buf.has_any_transform() {
                return buf.restore_to_raw_from(&displayed, Some(ch));
            }
            buf.passthrough = true;
        }
        return displayed.diff_to_buf(buf, Some(ch));
    }

    match lc {
        // duplicate vowel → circumflex (adjacent or delayed in valid Vietnamese syllable)
        'a' | 'e' | 'o' => {
            if lc == 'o' && buf.escaped_oo {
                buf.push(ch);
                buf.passthrough = true;
                buf.escaped_oo = false;
                buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
                return EngineAction::Pass;
            }
            let can_switch_last = buf.last().is_some_and(|last| {
                last.base_lc() == lc
                    && !last.stroke
                    && ((lc == 'a' && last.brev && !(cfg.spell_check && buf.len() == 1))
                        || (lc == 'o' && last.horn))
            });
            let prev_is_tone = prev_raw_lc.and_then(tone_of_key).is_some();
            let multi_vowel_after_tone = prev_is_tone && buf.analyze().nucleus.len() >= 2;
            let adj_dup = (!cfg.spell_check || prev_raw_lc == Some(lc) || multi_vowel_after_tone)
                && buf.last_is_dup_circ_candidate(lc);
            if adj_dup || can_switch_last {
                let mut trial = buf.clone();
                if lc == 'o'
                    && trial.len() >= 2
                    && trial.chars[trial.len() - 2].base_lc() == 'u'
                    && trial.chars[trial.len() - 2].implicit_horn
                {
                    let prev_idx = trial.len() - 2;
                    trial.chars[prev_idx].horn = false;
                    trial.chars[prev_idx].implicit_horn = false;
                }
                trial.set_last_hat();
                let _ = reanchor_existing_tone(&mut trial, cfg.orthography);
                if cfg.spell_check && !trial.is_valid_vietnamese() {
                    return buf.restore_to_raw_from(&displayed, Some(ch));
                }
                if !can_switch_last || trial.is_valid_vietnamese() {
                    *buf = trial;
                    return displayed.diff_to_buf(buf, Some(ch));
                }
            }
            if let Some(action) = try_delayed_circumflex(buf, cfg, ch, lc, prev_raw_lc, &displayed)
            {
                return action;
            }
            push_and_check_spell(buf, cfg, ch, &displayed)
        }
        'w' => apply_w(buf, cfg, ch, prev_raw_lc, &displayed),
        // `z` removes the last tone from the syllable (Unikey telex).
        'z' => {
            if let Some(idx) = buf.last_tone_idx() {
                buf.clear_tone_and_implicit_hat_at(idx);
                let syl = buf.analyze();
                if !cfg.spell_check || buf.has_explicit_mark() || syl.coda_start < buf.len() {
                    buf.sync_raw_keys_from_chars(cfg.method);
                }
                buf.stripped_tone_by_z = true;
                return displayed.diff_to_buf(buf, Some(ch));
            }
            push_and_check_spell(buf, cfg, ch, &displayed)
        }
        _ => push_and_check_spell(buf, cfg, ch, &displayed),
    }
}

fn finish_escape(buf: &mut WordBuffer, last_ch: char) {
    let current = format!("{}{last_ch}", buf.render_all());
    buf.raw_keys = current.chars().collect();
    buf.chars = current.chars().map(ViChar::from_char).collect();
    buf.leading_w_expansion = false;
    buf.passthrough = true;
    buf.escaped_double_tone = EscapedDoubleTone::None;
    buf.escaped_mark_raw_pending = false;
    buf.escaped_oo = false;
    buf.stripped_tone_by_z = false;
}

fn push_and_check_spell(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    displayed: &DisplayedSnapshot,
) -> EngineAction {
    let lc = ch.to_ascii_lowercase();
    let silent_e_after_toned_monophthong = if cfg.spell_check
        && lc == 'e'
        && !buf.has_explicit_mark()
        && buf.last_tone_idx().is_some()
    {
        let syl_before = buf.analyze();
        syl_before.nucleus.len() == 1
            && syl_before.coda_start == buf.len()
            && matches!(
                buf.chars[syl_before.nucleus[0]].base_lc(),
                'o' | 'i' | 'u' | 'y'
            )
    } else {
        false
    };
    buf.push(ch);
    if cfg.spell_check && (silent_e_after_toned_monophthong || !buf.is_valid_vietnamese()) {
        if buf.has_any_transform() {
            return buf.restore_to_raw_from(displayed, Some(ch));
        }
        buf.passthrough = true;
        buf.raw_keys = buf.chars.iter().map(|c| c.ch).collect();
        return displayed.diff_to_buf(buf, Some(ch));
    }
    let _ = rebalance_after_push(buf, cfg.orthography);
    displayed.diff_to_buf(buf, Some(ch))
}

fn try_delayed_circumflex(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    lc: char,
    prev_raw_lc: Option<char>,
    displayed: &DisplayedSnapshot,
) -> Option<EngineAction> {
    if !matches!(cfg.method, InputMethod::Telex) || buf.len() < 2 {
        return None;
    }
    let syl = buf.analyze();
    if syl.nucleus.is_empty() {
        return None;
    }

    if let Some(&hat_idx) = syl
        .nucleus
        .iter()
        .rev()
        .find(|&&i| buf.chars[i].base_lc() == lc && buf.chars[i].hat)
    {
        if buf.chars[hat_idx].implicit_hat {
            buf.chars[hat_idx].implicit_hat = false;
            return Some(displayed.diff_to_buf(buf, Some(ch)));
        }
        if cfg.repeated_restore && (!cfg.spell_check || prev_raw_lc == Some(lc)) {
            buf.chars[hat_idx].hat = false;
            let target = format!("{}{ch}", buf.render_all());
            finish_escape(buf, ch);
            return Some(displayed.diff_to_str(&target, Some(ch)));
        }
        return None;
    }

    if lc == 'e'
        && syl.initial_end == 2
        && buf.chars[0].base_lc() == 'q'
        && buf.chars[1].base_lc() == 'u'
        && syl.nucleus.len() == 2
        && buf.chars[syl.nucleus[0]].base_lc() == 'e'
        && buf.chars[syl.nucleus[1]].base_lc() == 'u'
    {
        return None;
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

    let cand_idx = syl.nucleus.iter().rev().copied().find(|&i| {
        let c = &buf.chars[i];
        c.base_lc() == lc && !c.hat
    })?;

    if cand_idx == buf.len() - 1 {
        return None;
    }

    let mut trial = buf.clone();
    if lc == 'o'
        && let Some(pos) = syl.nucleus.iter().position(|&idx| idx == cand_idx)
        && pos > 0
    {
        let prev_idx = syl.nucleus[pos - 1];
        if trial.chars[prev_idx].base_lc() == 'u' && trial.chars[prev_idx].implicit_horn {
            trial.chars[prev_idx].horn = false;
            trial.chars[prev_idx].implicit_horn = false;
        }
    }
    trial.chars[cand_idx].hat = true;
    trial.chars[cand_idx].implicit_hat = false;
    trial.chars[cand_idx].brev = false;
    trial.chars[cand_idx].horn = false;
    trial.chars[cand_idx].implicit_horn = false;
    if !trial.is_valid_vietnamese() {
        return None;
    }

    *buf = trial;
    let _ = reanchor_existing_tone(buf, cfg.orthography);
    Some(displayed.diff_to_buf(buf, Some(ch)))
}

fn apply_w(
    buf: &mut WordBuffer,
    cfg: &Config,
    ch: char,
    prev_raw_lc: Option<char>,
    displayed: &DisplayedSnapshot,
) -> EngineAction {
    let allow_shorthand_u = !cfg.allow_w_consonant && matches!(cfg.method, InputMethod::Telex);

    if buf.is_empty() {
        if !allow_shorthand_u {
            buf.push(ch);
            buf.passthrough = true;
            return EngineAction::Pass;
        }
        buf.push(ch);
        if let Some(c) = buf.last_mut() {
            c.ch = if ch.is_uppercase() { 'U' } else { 'u' };
            c.horn = true;
        }
        buf.leading_w_expansion = true;
        return displayed.diff_to_buf(buf, Some(ch));
    }

    let last = buf.last().copied().expect("non-empty checked");
    if cfg.repeated_restore
        && (!cfg.spell_check || prev_raw_lc == Some('w'))
        && (last.horn || last.brev)
    {
        if buf.len() == 1 && buf.leading_w_expansion {
            let w_ch = if last.is_upper() { 'W' } else { 'w' };
            let target = w_ch.to_string();
            buf.chars = vec![ViChar::from_char(w_ch)];
            buf.raw_keys = vec![w_ch];
            buf.leading_w_expansion = false;
            if cfg.spell_check {
                buf.passthrough = true;
            }
            return displayed.diff_to_str(&target, Some(ch));
        }

        let prev_idx = buf.len().saturating_sub(2);
        if last.base_lc() == 'o'
            && last.horn
            && buf.len() >= 2
            && buf.chars[prev_idx].base_lc() == 'u'
            && buf.chars[prev_idx].horn
        {
            buf.chars[prev_idx].horn = false;
            buf.chars[prev_idx].implicit_horn = false;
        }
        let c = buf.last_mut().unwrap();
        c.horn = false;
        c.implicit_horn = false;
        c.brev = false;
        let target = format!("{}{ch}", buf.render_all());
        finish_escape(buf, ch);
        return displayed.diff_to_str(&target, Some(ch));
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
                return push_and_check_spell(buf, cfg, ch, displayed);
            }
        }
        let _ = apply_uo_or_single_horn(buf, &syl, target_idx);
        let _ = reanchor_existing_tone(buf, cfg.orthography);
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return buf.restore_to_raw_from(displayed, Some(ch));
        }
        return displayed.diff_to_buf(buf, Some(ch));
    }

    let adjacent_eligible = match last.base_lc() {
        'a' if !last.brev => {
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
                return push_and_check_spell(buf, cfg, ch, displayed);
            }
        }
        let last_idx = buf.len() - 1;
        match last.base_lc() {
            'a' => buf.set_last_brev(),
            'o' | 'u' => {
                let _ = apply_uo_or_single_horn(buf, &syl, last_idx);
            }
            _ => unreachable!(),
        }
        let _ = reanchor_existing_tone(buf, cfg.orthography);
        if cfg.spell_check && !buf.is_valid_vietnamese() {
            return buf.restore_to_raw_from(displayed, Some(ch));
        }
        return displayed.diff_to_buf(buf, Some(ch));
    }

    if allow_shorthand_u && syl.nucleus.is_empty() {
        let lcs_init: Vec<char> = buf.chars.iter().map(ViChar::base_lc).collect();
        if is_valid_vi_initial(&lcs_init, buf.chars[0].stroke)
            && lcs_init != ['q']
            && lcs_init != ['p']
        {
            buf.push(ch);
            if let Some(c) = buf.last_mut() {
                c.ch = if ch.is_uppercase() { 'U' } else { 'u' };
                c.horn = true;
            }
            return displayed.diff_to_buf(buf, Some(ch));
        }
    }

    if matches!(cfg.method, InputMethod::Telex)
        && !syl.nucleus.is_empty()
        && let Some(action) = try_delayed_w(buf, cfg, &syl, ch, prev_raw_lc, displayed)
    {
        return action;
    }

    push_and_check_spell(buf, cfg, ch, displayed)
}

fn try_delayed_w(
    buf: &mut WordBuffer,
    cfg: &Config,
    syl: &crate::word::Syllable,
    ch: char,
    prev_raw_lc: Option<char>,
    displayed: &DisplayedSnapshot,
) -> Option<EngineAction> {
    let target = find_delayed_w_target(buf, syl);

    if target.is_none() {
        if prev_raw_lc != Some('w')
            && let Some(&o_idx) = syl
                .nucleus
                .iter()
                .find(|&&i| buf.chars[i].base_lc() == 'o' && buf.chars[i].implicit_horn)
        {
            buf.chars[o_idx].implicit_horn = false;
            return Some(displayed.diff_to_buf(buf, Some(ch)));
        }
        if cfg.repeated_restore
            && (!cfg.spell_check || prev_raw_lc == Some('w'))
            && syl
                .nucleus
                .iter()
                .any(|&i| buf.chars[i].horn || buf.chars[i].brev)
        {
            for &i in &syl.nucleus {
                buf.chars[i].horn = false;
                buf.chars[i].implicit_horn = false;
                buf.chars[i].brev = false;
            }
            let _ = reanchor_existing_tone(buf, cfg.orthography);
            let out = format!("{}{ch}", buf.render_all());
            finish_escape(buf, ch);
            return Some(displayed.diff_to_str(&out, Some(ch)));
        }
        return None;
    }

    if !buf.is_valid_vietnamese() {
        return None;
    }

    let target_idx = target?;
    let mut trial = buf.clone();
    if trial.chars[target_idx].base_lc() == 'a' {
        trial.chars[target_idx].brev = true;
        trial.chars[target_idx].hat = false;
        trial.chars[target_idx].implicit_hat = false;
    } else {
        let _ = apply_uo_or_single_horn(&mut trial, syl, target_idx);
    }
    if trial.chars == buf.chars || !trial.is_valid_vietnamese() {
        return None;
    }

    *buf = trial;
    let _ = reanchor_existing_tone(buf, cfg.orthography);
    Some(displayed.diff_to_buf(buf, Some(ch)))
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
            'a' if !c.brev => return Some(idx),
            'o' | 'u' if !c.horn => return Some(idx),
            _ => {}
        }
    }
    None
}
