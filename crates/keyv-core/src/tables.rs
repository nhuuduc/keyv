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
pub const A_TONES_UPPER: [char; 5] = ['Á', 'À', 'Ả', 'Ã', 'Ạ'];
/// ă
pub const A_BREV_TONES: [char; 5] = ['ắ', 'ằ', 'ẳ', 'ẵ', 'ặ'];
pub const A_BREV_TONES_UPPER: [char; 5] = ['Ắ', 'Ằ', 'Ẳ', 'Ẵ', 'Ặ'];
/// â
pub const A_HAT_TONES: [char; 5] = ['ấ', 'ầ', 'ẩ', 'ẫ', 'ậ'];
pub const A_HAT_TONES_UPPER: [char; 5] = ['Ấ', 'Ầ', 'Ẩ', 'Ẫ', 'Ậ'];
pub const E_TONES: [char; 5] = ['é', 'è', 'ẻ', 'ẽ', 'ẹ'];
pub const E_TONES_UPPER: [char; 5] = ['É', 'È', 'Ẻ', 'Ẽ', 'Ẹ'];
pub const E_HAT_TONES: [char; 5] = ['ế', 'ề', 'ể', 'ễ', 'ệ'];
pub const E_HAT_TONES_UPPER: [char; 5] = ['Ế', 'Ề', 'Ể', 'Ễ', 'Ệ'];
pub const I_TONES: [char; 5] = ['í', 'ì', 'ỉ', 'ĩ', 'ị'];
pub const I_TONES_UPPER: [char; 5] = ['Í', 'Ì', 'Ỉ', 'Ĩ', 'Ị'];
pub const O_TONES: [char; 5] = ['ó', 'ò', 'ỏ', 'õ', 'ọ'];
pub const O_TONES_UPPER: [char; 5] = ['Ó', 'Ò', 'Ỏ', 'Õ', 'Ọ'];
pub const O_HAT_TONES: [char; 5] = ['ố', 'ồ', 'ổ', 'ỗ', 'ộ'];
pub const O_HAT_TONES_UPPER: [char; 5] = ['Ố', 'Ồ', 'Ổ', 'Ỗ', 'Ộ'];
pub const O_HORN_TONES: [char; 5] = ['ớ', 'ờ', 'ở', 'ỡ', 'ợ'];
pub const O_HORN_TONES_UPPER: [char; 5] = ['Ớ', 'Ờ', 'Ở', 'Ỡ', 'Ợ'];
pub const U_TONES: [char; 5] = ['ú', 'ù', 'ủ', 'ũ', 'ụ'];
pub const U_TONES_UPPER: [char; 5] = ['Ú', 'Ù', 'Ủ', 'Ũ', 'Ụ'];
pub const U_HORN_TONES: [char; 5] = ['ứ', 'ừ', 'ử', 'ữ', 'ự'];
pub const U_HORN_TONES_UPPER: [char; 5] = ['Ứ', 'Ừ', 'Ử', 'Ữ', 'Ự'];
pub const Y_TONES: [char; 5] = ['ý', 'ỳ', 'ỷ', 'ỹ', 'ỵ'];
pub const Y_TONES_UPPER: [char; 5] = ['Ý', 'Ỳ', 'Ỷ', 'Ỹ', 'Ỵ'];

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

#[inline]
pub fn render_vowel_char(g: VG, tone: Tone, upper: bool) -> char {
    if tone == Tone::None {
        return match (g, upper) {
            (VG::A, false) => 'a',
            (VG::A, true) => 'A',
            (VG::Abrev, false) => 'ă',
            (VG::Abrev, true) => 'Ă',
            (VG::Ahat, false) => 'â',
            (VG::Ahat, true) => 'Â',
            (VG::E, false) => 'e',
            (VG::E, true) => 'E',
            (VG::Ehat, false) => 'ê',
            (VG::Ehat, true) => 'Ê',
            (VG::I, false) => 'i',
            (VG::I, true) => 'I',
            (VG::O, false) => 'o',
            (VG::O, true) => 'O',
            (VG::Ohat, false) => 'ô',
            (VG::Ohat, true) => 'Ô',
            (VG::Ohorn, false) => 'ơ',
            (VG::Ohorn, true) => 'Ơ',
            (VG::U, false) => 'u',
            (VG::U, true) => 'U',
            (VG::Uhorn, false) => 'ư',
            (VG::Uhorn, true) => 'Ư',
            (VG::Y, false) => 'y',
            (VG::Y, true) => 'Y',
        };
    }
    let slot = tone_slot(tone);
    if upper {
        match g {
            VG::A => A_TONES_UPPER[slot],
            VG::Abrev => A_BREV_TONES_UPPER[slot],
            VG::Ahat => A_HAT_TONES_UPPER[slot],
            VG::E => E_TONES_UPPER[slot],
            VG::Ehat => E_HAT_TONES_UPPER[slot],
            VG::I => I_TONES_UPPER[slot],
            VG::O => O_TONES_UPPER[slot],
            VG::Ohat => O_HAT_TONES_UPPER[slot],
            VG::Ohorn => O_HORN_TONES_UPPER[slot],
            VG::U => U_TONES_UPPER[slot],
            VG::Uhorn => U_HORN_TONES_UPPER[slot],
            VG::Y => Y_TONES_UPPER[slot],
        }
    } else {
        match g {
            VG::A => A_TONES[slot],
            VG::Abrev => A_BREV_TONES[slot],
            VG::Ahat => A_HAT_TONES[slot],
            VG::E => E_TONES[slot],
            VG::Ehat => E_HAT_TONES[slot],
            VG::I => I_TONES[slot],
            VG::O => O_TONES[slot],
            VG::Ohat => O_HAT_TONES[slot],
            VG::Ohorn => O_HORN_TONES[slot],
            VG::U => U_TONES[slot],
            VG::Uhorn => U_HORN_TONES[slot],
            VG::Y => Y_TONES[slot],
        }
    }
}

/// Render a vowel group with an optional tone into its final glyph,
/// using the Latin-Extended-Additional precomposed forms.
pub fn render_vowel(g: VG, tone: Tone, upper: bool) -> String {
    render_vowel_char(g, tone, upper).to_string()
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

pub fn is_valid_vi_initial(initial: &[char], stroke_first: bool) -> bool {
    if stroke_first {
        return initial == ['d'];
    }
    match initial {
        [] => true,
        [c] => matches!(
            *c,
            'b' | 'c'
                | 'd'
                | 'g'
                | 'h'
                | 'k'
                | 'l'
                | 'm'
                | 'n'
                | 'p'
                | 'q'
                | 'r'
                | 's'
                | 't'
                | 'v'
                | 'x'
        ),
        [a, b] => matches!(
            (*a, *b),
            ('c', 'h')
                | ('g', 'h')
                | ('g', 'i')
                | ('k', 'h')
                | ('n', 'g')
                | ('n', 'h')
                | ('p', 'h')
                | ('q', 'u')
                | ('t', 'h')
                | ('t', 'r')
        ),
        ['n', 'g', 'h'] => true,
        _ => false,
    }
}

pub fn is_valid_vi_coda(coda: &[char]) -> bool {
    match coda {
        [] => true,
        [c] => matches!(*c, 'c' | 'm' | 'n' | 'p' | 't'),
        [a, b] => matches!((*a, *b), ('c', 'h') | ('n', 'g') | ('n', 'h')),
        _ => false,
    }
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
        for g in [
            VG::A,
            VG::Abrev,
            VG::Ahat,
            VG::E,
            VG::Ehat,
            VG::I,
            VG::O,
            VG::Ohat,
            VG::Ohorn,
            VG::U,
            VG::Uhorn,
            VG::Y,
        ] {
            for t in [
                Tone::None,
                Tone::Sac,
                Tone::Huyen,
                Tone::Hoi,
                Tone::Nga,
                Tone::Nang,
            ] {
                let lo = render_vowel_char(g, t, false);
                let hi = render_vowel_char(g, t, true);
                assert_eq!(lo.to_uppercase().to_string(), hi.to_string());
            }
        }
    }

    #[test]
    fn vowel_group_resolution() {
        assert_eq!(vowel_group('o', true, false, true), Some(VG::Ohorn));
        assert_eq!(vowel_group('a', true, true, false), Some(VG::Abrev));
        assert_eq!(vowel_group('d', false, false, false), None);
    }
}
