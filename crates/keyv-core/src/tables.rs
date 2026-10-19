//! Data tables: Vietnamese Unicode characters, tone marks, vowel classes.
//!
//! Hand-curated from public Unicode data (UnicodeData.txt) — data facts, not
//! code. This is part of a clean-room implementation (MIT/Apache-2.0) for the
//! KeyV project; no third-party input engine source is used or derived from.

/// Vietnamese tone marks (thanh điệu).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Tone {
    #[default]
    None,
    /// huyền (◌̀)
    Huyen,
    /// sắc (◌́)
    Sac,
    /// hỏi (◌̉)
    Hoi,
    /// ngã (◌̃)
    Nga,
    /// nặng (◌̣, below)
    Nang,
}

/// Index into the 5-slot tone tables below. Tone tables are ordered
/// [sắc, huyền, hỏi, ngã, nặng].
pub(crate) fn tone_slot(tone: Tone) -> usize {
    match tone {
        Tone::Sac => 0,
        Tone::Huyen => 1,
        Tone::Hoi => 2,
        Tone::Nga => 3,
        Tone::Nang => 4,
        Tone::None => 0, // unreachable in tone-table paths
    }
}

/// Plain `a` with each tone: [sắc, huyền, hỏi, ngã, nặng]
pub const A_TONES: [char; 5] = ['á', 'à', 'ả', 'ã', 'ạ'];
/// ă
pub const A_BREV_TONES: [char; 5] = ['ắ', 'ằ', 'ẳ', 'ẵ', 'ặ'];
/// â
pub const A_HAT_TONES: [char; 5] = ['ấ', 'ầ', 'ẩ', 'ẫ', 'ậ'];
pub const E_TONES: [char; 5] = ['é', 'è', 'ẻ', 'ẽ', 'ẹ'];
pub const E_HAT_TONES: [char; 5] = ['ế', 'ề', 'ể', 'ễ', 'ệ'];
pub const I_TONES: [char; 5] = ['í', 'ì', 'ỉ', 'ĩ', 'ị'];
pub const O_TONES: [char; 5] = ['ó', 'ò', 'ỏ', 'õ', 'ọ'];
pub const O_HAT_TONES: [char; 5] = ['ố', 'ồ', 'ổ', 'ỗ', 'ộ'];
pub const O_HORN_TONES: [char; 5] = ['ớ', 'ờ', 'ở', 'ỡ', 'ợ'];
pub const U_TONES: [char; 5] = ['ú', 'ù', 'ủ', 'ũ', 'ụ'];
pub const U_HORN_TONES: [char; 5] = ['ứ', 'ừ', 'ử', 'ữ', 'ự'];
pub const Y_TONES: [char; 5] = ['ý', 'ỳ', 'ỷ', 'ỹ', 'ỵ'];

/// Vowel identity after applying marks (breve/hat/horn variants resolve to a
/// distinct rendering group).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VG {
    A,
    Abrev,
    Ahat,
    E,
    Ehat,
    I,
    O,
    Ohat,
    Ohorn,
    U,
    Uhorn,
    Y,
}

/// Resolve a lowercase base letter plus its mark flags into a vowel group.
/// `o` + horn wins over hat (`ow` -> ơ even if `o` already had a hat), and
/// `u` + horn analogously.
pub fn vowel_group(lc: char, hat: bool, brev: bool, horn: bool) -> Option<VG> {
    match lc {
        'a' => Some(if brev {
            VG::Abrev
        } else if hat {
            VG::Ahat
        } else {
            VG::A
        }),
        'e' => Some(if hat { VG::Ehat } else { VG::E }),
        'o' => Some(if horn {
            VG::Ohorn
        } else if hat {
            VG::Ohat
        } else {
            VG::O
        }),
        'u' => Some(if horn { VG::Uhorn } else { VG::U }),
        'i' => Some(VG::I),
        'y' => Some(VG::Y),
        _ => None,
    }
}

/// Lower-case base glyph for a vowel group, without a tone.
pub fn vowel_base(g: VG) -> char {
    match g {
        VG::A | VG::Abrev | VG::Ahat => 'a',
        VG::E | VG::Ehat => 'e',
        VG::I => 'i',
        VG::O | VG::Ohat | VG::Ohorn => 'o',
        VG::U | VG::Uhorn => 'u',
        VG::Y => 'y',
    }
}

/// Render a vowel group with an optional tone into its final glyph,
/// using the Latin-Extended-Additional precomposed forms.
pub fn render_vowel(g: VG, tone: Tone, upper: bool) -> String {
    let base: char = match g {
        VG::A => 'a',
        VG::Abrev => 'ă',
        VG::Ahat => 'â',
        VG::E => 'e',
        VG::Ehat => 'ê',
        VG::I => 'i',
        VG::O => 'o',
        VG::Ohat => 'ô',
        VG::Ohorn => 'ơ',
        VG::U => 'u',
        VG::Uhorn => 'ư',
        VG::Y => 'y',
    };
    if tone == Tone::None {
        return if upper {
            base.to_uppercase().to_string()
        } else {
            base.to_string()
        };
    }
    let table: &[char; 5] = match g {
        VG::A => &A_TONES,
        VG::Abrev => &A_BREV_TONES,
        VG::Ahat => &A_HAT_TONES,
        VG::E => &E_TONES,
        VG::Ehat => &E_HAT_TONES,
        VG::I => &I_TONES,
        VG::O => &O_TONES,
        VG::Ohat => &O_HAT_TONES,
        VG::Ohorn => &O_HORN_TONES,
        VG::U => &U_TONES,
        VG::Uhorn => &U_HORN_TONES,
        VG::Y => &Y_TONES,
    };
    let ch = table[tone_slot(tone)];
    if upper {
        ch.to_uppercase().to_string()
    } else {
        ch.to_string()
    }
}

/// Map a raw base letter onto its plain form, for phonetic pair decisions
/// used during tone placement ('â' → 'a', 'ơ' → 'o', 'ư' → 'u', …).
pub fn canon_of(lc: char) -> char {
    match lc {
        'a' | 'e' | 'i' | 'o' | 'u' | 'y' => lc,
        _ => lc, // consonants map to themselves
    }
}

/// True if the lowercase letter is a Vietnamese vowel nucleus letter
/// (`a ă â e ê i o ô ơ u ư y` — all raw forms use the ASCII base letters).
pub fn is_vowel_base(lc: char) -> bool {
    matches!(lc, 'a' | 'e' | 'i' | 'o' | 'u' | 'y')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tone_arrays_are_sound() {
        assert_eq!(A_TONES[tone_slot(Tone::Sac)], 'á');
        assert_eq!(A_BREV_TONES[tone_slot(Tone::Nang)], 'ặ');
        assert_eq!(U_HORN_TONES[tone_slot(Tone::Huyen)], 'ừ');
        assert_eq!(Y_TONES[tone_slot(Tone::Nga)], 'ỹ');
    }

    #[test]
    fn uppercase_round_trip() {
        assert_eq!('ắ'.to_uppercase().to_string(), "Ắ");
        assert_eq!('ằ'.to_uppercase().to_string(), "Ằ");
        assert_eq!('ở'.to_uppercase().to_string(), "Ở");
    }

    #[test]
    fn vowel_group_resolution() {
        assert_eq!(vowel_group('o', true, false, true), Some(VG::Ohorn));
        assert_eq!(vowel_group('a', true, true, false), Some(VG::Abrev));
        assert_eq!(vowel_group('d', false, false, false), None);
    }
}
