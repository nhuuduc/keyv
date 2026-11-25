use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Orthography, Tone, Typer};
use std::collections::BTreeMap;

const BS: char = '\u{0008}';

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mark {
    Plain,
    Hat,
    Brev,
    Horn,
}

#[derive(Clone, Copy, Debug)]
struct VowelSpec {
    base: char,
    mark: Mark,
}

impl VowelSpec {
    const fn new(base: char, mark: Mark) -> Self {
        Self { base, mark }
    }
}

#[derive(Clone, Debug)]
struct RimeSpec {
    name: &'static str,
    vowels: Vec<VowelSpec>,
    codas: &'static [&'static str],
    starts_i_e: bool,
    starts_y: bool,
    labialized_medial: bool,
}

#[derive(Clone, Debug)]
struct GeneratedSyllable {
    onset: &'static str,
    rime_name: &'static str,
    vowels: Vec<VowelSpec>,
    coda: &'static str,
    tone: Tone,
}

fn render_vspec(v: VowelSpec, tone: Tone, upper: bool) -> char {
    use keyv_core::tables::{VG, render_vowel_char, vowel_group};
    let g: VG = vowel_group(
        v.base,
        v.mark == Mark::Hat,
        v.mark == Mark::Brev,
        v.mark == Mark::Horn,
    )
    .expect("valid vowel spec");
    render_vowel_char(g, tone, upper)
}

fn expected_tone_vowel_index(vowels: &[VowelSpec], coda: &str, orth: Orthography) -> usize {
    let k = vowels.len();
    if k == 1 {
        return 0;
    }
    if let Some(pos) = vowels
        .iter()
        .position(|v| v.base == 'o' && v.mark == Mark::Horn)
    {
        return pos;
    }
    if let Some(pos) = vowels.iter().position(|v| v.mark != Mark::Plain) {
        return pos;
    }
    if k >= 3 {
        return 1;
    }
    if !coda.is_empty() {
        return 1;
    }
    match (vowels[0].base, vowels[1].base, orth) {
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
        | ('u', 'u', _) => 0,
        ('o', 'a', Orthography::Traditional)
        | ('o', 'e', Orthography::Traditional)
        | ('o', 'y', Orthography::Traditional)
        | ('u', 'y', Orthography::Traditional) => 0,
        _ => 1,
    }
}

impl GeneratedSyllable {
    fn render(&self, orth: Orthography, case_mode: CaseMode) -> String {
        let mut out = String::new();
        let onset_chars: Vec<char> = self.onset.chars().collect();
        for (idx, &ch) in onset_chars.iter().enumerate() {
            let up = match case_mode {
                CaseMode::Lower => false,
                CaseMode::Title => idx == 0,
                CaseMode::Upper => true,
            };
            if ch == 'đ' {
                out.push(if up { 'Đ' } else { 'đ' });
            } else if up {
                out.extend(ch.to_uppercase());
            } else {
                out.push(ch);
            }
        }

        if self.onset == "gi" && self.vowels.len() == 1 && self.vowels[0].base == 'i' {
            out.pop(); // pop the 'i'/'I' of "gi"
            let up_i = matches!(case_mode, CaseMode::Upper);
            out.push(render_vspec(self.vowels[0], self.tone, up_i));
        } else {
            let tone_idx = expected_tone_vowel_index(&self.vowels, self.coda, orth);
            for (v_idx, &v) in self.vowels.iter().enumerate() {
                let is_very_first_char = self.onset.is_empty() && v_idx == 0;
                let up = match case_mode {
                    CaseMode::Lower => false,
                    CaseMode::Title => is_very_first_char,
                    CaseMode::Upper => true,
                };
                let t = if v_idx == tone_idx {
                    self.tone
                } else {
                    Tone::None
                };
                out.push(render_vspec(v, t, up));
            }
        }

        for ch in self.coda.chars() {
            if matches!(case_mode, CaseMode::Upper) {
                out.extend(ch.to_uppercase());
            } else {
                out.push(ch);
            }
        }
        out
    }
}

#[derive(Clone, Copy, Debug)]
enum CaseMode {
    Lower,
    Title,
    Upper,
}

fn build_rimes() -> Vec<RimeSpec> {
    use Mark::*;
    let v = VowelSpec::new;
    vec![
        RimeSpec {
            name: "a",
            vowels: vec![v('a', Plain)],
            codas: &["", "m", "n", "ng", "nh", "p", "t", "c", "ch"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ă",
            vowels: vec![v('a', Brev)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "â",
            vowels: vec![v('a', Hat)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "e",
            vowels: vec![v('e', Plain)],
            codas: &["", "m", "n", "ng", "p", "t", "c"],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ê",
            vowels: vec![v('e', Hat)],
            codas: &["", "m", "n", "nh", "p", "t", "ch"],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "i",
            vowels: vec![v('i', Plain)],
            codas: &["", "m", "n", "nh", "p", "t", "ch"],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "y",
            vowels: vec![v('y', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: true,
            labialized_medial: false,
        },
        RimeSpec {
            name: "o",
            vowels: vec![v('o', Plain)],
            codas: &["", "m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ô",
            vowels: vec![v('o', Hat)],
            codas: &["", "m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ơ",
            vowels: vec![v('o', Horn)],
            codas: &["", "m", "n", "p", "t"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "u",
            vowels: vec![v('u', Plain)],
            codas: &["", "m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ư",
            vowels: vec![v('u', Horn)],
            codas: &["", "m", "n", "ng", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ai",
            vowels: vec![v('a', Plain), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ao",
            vowels: vec![v('a', Plain), v('o', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "au",
            vowels: vec![v('a', Plain), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ay",
            vowels: vec![v('a', Plain), v('y', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "âu",
            vowels: vec![v('a', Hat), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ây",
            vowels: vec![v('a', Hat), v('y', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "eo",
            vowels: vec![v('e', Plain), v('o', Plain)],
            codas: &[""],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "êu",
            vowels: vec![v('e', Hat), v('u', Plain)],
            codas: &[""],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ia",
            vowels: vec![v('i', Plain), v('a', Plain)],
            codas: &[""],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "iu",
            vowels: vec![v('i', Plain), v('u', Plain)],
            codas: &[""],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "oi",
            vowels: vec![v('o', Plain), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ôi",
            vowels: vec![v('o', Hat), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ơi",
            vowels: vec![v('o', Horn), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ua",
            vowels: vec![v('u', Plain), v('a', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ui",
            vowels: vec![v('u', Plain), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ưa",
            vowels: vec![v('u', Horn), v('a', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ưi",
            vowels: vec![v('u', Horn), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ưu",
            vowels: vec![v('u', Horn), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "iê",
            vowels: vec![v('i', Plain), v('e', Hat)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "yê",
            vowels: vec![v('y', Plain), v('e', Hat)],
            codas: &["m", "n", "ng", "t"],
            starts_i_e: false,
            starts_y: true,
            labialized_medial: false,
        },
        RimeSpec {
            name: "uô",
            vowels: vec![v('u', Plain), v('o', Hat)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ươ",
            vowels: vec![v('u', Horn), v('o', Horn)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "oa",
            vowels: vec![v('o', Plain), v('a', Plain)],
            codas: &["", "m", "n", "ng", "nh", "p", "t", "c", "ch"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "oă",
            vowels: vec![v('o', Plain), v('a', Brev)],
            codas: &["m", "n", "ng", "p", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "oe",
            vowels: vec![v('o', Plain), v('e', Plain)],
            codas: &["", "m", "n", "t"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uâ",
            vowels: vec![v('u', Plain), v('a', Hat)],
            codas: &["n", "ng", "t", "c"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uê",
            vowels: vec![v('u', Plain), v('e', Hat)],
            codas: &["", "n", "nh", "t", "ch"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uy",
            vowels: vec![v('u', Plain), v('y', Plain)],
            codas: &["", "n", "nh", "p", "t", "ch"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "iêu",
            vowels: vec![v('i', Plain), v('e', Hat), v('u', Plain)],
            codas: &[""],
            starts_i_e: true,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "yêu",
            vowels: vec![v('y', Plain), v('e', Hat), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: true,
            labialized_medial: false,
        },
        RimeSpec {
            name: "uôi",
            vowels: vec![v('u', Plain), v('o', Hat), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ươi",
            vowels: vec![v('u', Horn), v('o', Horn), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "ươu",
            vowels: vec![v('u', Horn), v('o', Horn), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: false,
        },
        RimeSpec {
            name: "oai",
            vowels: vec![v('o', Plain), v('a', Plain), v('i', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "oao",
            vowels: vec![v('o', Plain), v('a', Plain), v('o', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "oay",
            vowels: vec![v('o', Plain), v('a', Plain), v('y', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "oeo",
            vowels: vec![v('o', Plain), v('e', Plain), v('o', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uây",
            vowels: vec![v('u', Plain), v('a', Hat), v('y', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uya",
            vowels: vec![v('u', Plain), v('y', Plain), v('a', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uyu",
            vowels: vec![v('u', Plain), v('y', Plain), v('u', Plain)],
            codas: &[""],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
        RimeSpec {
            name: "uyê",
            vowels: vec![v('u', Plain), v('y', Plain), v('e', Hat)],
            codas: &["n", "t"],
            starts_i_e: false,
            starts_y: false,
            labialized_medial: true,
        },
    ]
}

fn onset_allows_rime(onset: &str, r: &RimeSpec, coda: &str) -> bool {
    if (r.name == "yê" || r.name == "yêu") && !onset.is_empty() && onset != "qu" {
        return false;
    }
    if r.name == "y"
        && !matches!(
            onset,
            "" | "h" | "k" | "l" | "m" | "n" | "qu" | "s" | "t" | "th" | "tr" | "v" | "x"
        )
    {
        return false;
    }
    if r.name == "oe"
        && !(matches!(
            onset,
            "" | "ch" | "h" | "kh" | "l" | "ng" | "nh" | "t" | "x"
        ) || (onset == "th" && coda == "t"))
    {
        return false;
    }
    if r.name == "oeo"
        && !matches!(
            onset,
            "" | "ch" | "h" | "kh" | "l" | "ng" | "nh" | "t" | "x"
        )
    {
        return false;
    }
    if onset == "g" && r.name.starts_with("uy") {
        return false;
    }
    if onset == "b" && r.name == "uy" && coda != "t" {
        return false;
    }
    match onset {
        "k" => r.starts_i_e || r.name == "y",
        "gh" | "ngh" => r.starts_i_e,
        "c" | "g" | "ng" => !r.starts_i_e && !r.starts_y,
        "gi" => {
            if r.labialized_medial || r.starts_y || matches!(r.name, "ia" | "iê" | "iêu" | "iu") {
                return false;
            }
            if r.name == "i" && matches!(coda, "nh" | "ch") {
                return false;
            }
            true
        }
        "qu" => {
            if r.labialized_medial {
                return false;
            }
            match r.name {
                "a" | "ă" | "â" | "ai" | "ao" | "au" | "ay" | "ây" | "âu" | "e" | "eo" | "ê"
                | "êu" | "i" | "ơ" => true,
                "ô" => coda == "c",
                "y" => true,
                "yê" => matches!(coda, "n" | "t"),
                _ => false,
            }
        }
        "p" => {
            (r.name == "i" && matches!(coda, "" | "n"))
                || (matches!(r.name, "a" | "ê" | "ô" | "ơ") && coda.is_empty())
        }
        _ => true,
    }
}

fn generate_all_vietnamese_syllables() -> Vec<GeneratedSyllable> {
    let onsets = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh",
        "nh", "p", "ph", "qu", "r", "s", "t", "th", "tr", "v", "x",
    ];
    let rimes = build_rimes();
    let all_tones = [
        Tone::None,
        Tone::Sac,
        Tone::Huyen,
        Tone::Hoi,
        Tone::Nga,
        Tone::Nang,
    ];
    let stop_tones = [Tone::Sac, Tone::Nang];

    let mut out = Vec::with_capacity(8000);

    for &onset in &onsets {
        for r in &rimes {
            for &coda in r.codas {
                if !onset_allows_rime(onset, r, coda) {
                    continue;
                }
                let is_stop = matches!(coda, "p" | "t" | "c" | "ch");
                let tones: &[Tone] = if onset == "p" {
                    &[Tone::None]
                } else if is_stop {
                    &stop_tones
                } else {
                    &all_tones
                };
                for &tone in tones {
                    out.push(GeneratedSyllable {
                        onset,
                        rime_name: r.name,
                        vowels: r.vowels.clone(),
                        coda,
                        tone,
                    });
                }
            }
        }
    }

    for &(coda, is_stop) in &[
        ("n", false),
        ("nh", false),
        ("t", true),
        ("ch", true),
        ("p", true),
    ] {
        let tones: &[Tone] = if is_stop { &stop_tones } else { &all_tones };
        for &tone in tones {
            out.push(GeneratedSyllable {
                onset: "qu",
                rime_name: "y_coda",
                vowels: vec![VowelSpec::new('y', Mark::Plain)],
                coda,
                tone,
            });
        }
    }

    for &(coda, is_stop) in &[("ng", false), ("c", true)] {
        let tones: &[Tone] = if is_stop { &stop_tones } else { &all_tones };
        for &tone in tones {
            out.push(GeneratedSyllable {
                onset: "gi",
                rime_name: "ê_gi",
                vowels: vec![VowelSpec::new('e', Mark::Hat)],
                coda,
                tone,
            });
        }
    }

    for &onset in &["h", "th"] {
        for &tone in &all_tones {
            out.push(GeneratedSyllable {
                onset,
                rime_name: "uơ",
                vowels: vec![
                    VowelSpec::new('u', Mark::Plain),
                    VowelSpec::new('o', Mark::Horn),
                ],
                coda: "",
                tone,
            });
        }
    }

    out
}

fn tone_telex_key(t: Tone) -> Option<char> {
    match t {
        Tone::None => None,
        Tone::Sac => Some('s'),
        Tone::Huyen => Some('f'),
        Tone::Hoi => Some('r'),
        Tone::Nga => Some('x'),
        Tone::Nang => Some('j'),
    }
}

fn tone_vni_key(t: Tone) -> Option<char> {
    match t {
        Tone::None => None,
        Tone::Sac => Some('1'),
        Tone::Huyen => Some('2'),
        Tone::Hoi => Some('3'),
        Tone::Nga => Some('4'),
        Tone::Nang => Some('5'),
    }
}

fn telex_orders_for(syl: &GeneratedSyllable, case_mode: CaseMode) -> Vec<(&'static str, String)> {
    let apply_case = |ch: char, is_first: bool| -> char {
        match case_mode {
            CaseMode::Lower => ch,
            CaseMode::Title => {
                if is_first {
                    ch.to_ascii_uppercase()
                } else {
                    ch
                }
            }
            CaseMode::Upper => ch.to_ascii_uppercase(),
        }
    };

    let is_gi_single_i = syl.onset == "gi" && syl.vowels.len() == 1 && syl.vowels[0].base == 'i';
    let is_uow = syl.vowels.len() >= 2
        && syl.vowels[0].base == 'u'
        && syl.vowels[0].mark == Mark::Horn
        && syl.vowels[1].base == 'o'
        && syl.vowels[1].mark == Mark::Horn;

    let mut imm_prefix = String::new();
    let mut char_pos = 0usize;
    if syl.onset == "đ" {
        imm_prefix.push(apply_case('d', true));
        imm_prefix.push(apply_case('d', false));
        char_pos += 1;
    } else {
        for ch in syl.onset.chars() {
            imm_prefix.push(apply_case(ch, char_pos == 0));
            char_pos += 1;
        }
    }

    if !is_gi_single_i {
        for (vi, v) in syl.vowels.iter().enumerate() {
            let first = char_pos == 0;
            imm_prefix.push(apply_case(v.base, first));
            char_pos += 1;
            if is_uow && vi == 0 {
                continue;
            }
            match v.mark {
                Mark::Plain => {}
                Mark::Hat => imm_prefix.push(apply_case(v.base, false)),
                Mark::Brev | Mark::Horn => imm_prefix.push(apply_case('w', false)),
            }
        }
    }

    let coda_str: String = syl.coda.chars().map(|c| apply_case(c, false)).collect();
    let t_ch = tone_telex_key(syl.tone).map(|c| apply_case(c, false));

    let mut orders = Vec::new();

    let mut std_end = imm_prefix.clone();
    std_end.push_str(&coda_str);
    if let Some(tc) = t_ch {
        std_end.push(tc);
    }
    orders.push(("telex_std_end", std_end));

    if !syl.coda.is_empty()
        && let Some(tc) = t_ch
    {
        let mut std_mid = imm_prefix.clone();
        std_mid.push(tc);
        std_mid.push_str(&coda_str);
        orders.push(("telex_std_mid", std_mid));
    }

    if is_uow {
        let mut uwow = String::new();
        let mut p = 0usize;
        if syl.onset == "đ" {
            uwow.push(apply_case('d', true));
            uwow.push(apply_case('d', false));
            p += 1;
        } else {
            for ch in syl.onset.chars() {
                uwow.push(apply_case(ch, p == 0));
                p += 1;
            }
        }
        for v in &syl.vowels {
            uwow.push(apply_case(v.base, p == 0));
            p += 1;
            if v.mark == Mark::Horn {
                uwow.push(apply_case('w', false));
            }
        }
        uwow.push_str(&coda_str);
        if let Some(tc) = t_ch {
            uwow.push(tc);
        }
        orders.push(("telex_uwow", uwow));
    }

    let mut plain_letters = String::new();
    let mut p = 0usize;
    if syl.onset == "đ" {
        plain_letters.push(apply_case('d', true));
        p += 1;
    } else {
        for ch in syl.onset.chars() {
            plain_letters.push(apply_case(ch, p == 0));
            p += 1;
        }
    }
    let mut mark_keys = String::new();
    if !is_gi_single_i {
        for (vi, v) in syl.vowels.iter().enumerate() {
            plain_letters.push(apply_case(v.base, p == 0));
            p += 1;
            if is_uow && vi == 0 {
                continue;
            }
            match v.mark {
                Mark::Plain => {}
                Mark::Hat => mark_keys.push(apply_case(v.base, false)),
                Mark::Brev | Mark::Horn => mark_keys.push(apply_case('w', false)),
            }
        }
    }
    plain_letters.push_str(&coda_str);

    let is_qu_eu = syl.onset == "qu" && syl.rime_name == "êu";
    if (!mark_keys.is_empty() || syl.onset == "đ" || t_ch.is_some()) && !is_qu_eu {
        let mut del1 = plain_letters.clone();
        del1.push_str(&mark_keys);
        if let Some(tc) = t_ch {
            del1.push(tc);
        }
        if syl.onset == "đ" {
            del1.push(apply_case('d', false));
        }
        orders.push(("telex_delayed_mark_then_tone", del1));

        if let Some(tc) = t_ch
            && !mark_keys.is_empty()
        {
            let mut del2 = plain_letters;
            del2.push(tc);
            del2.push_str(&mark_keys);
            if syl.onset == "đ" {
                del2.push(apply_case('d', false));
            }
            orders.push(("telex_delayed_tone_then_mark", del2));
        }
    }

    orders
}

fn vni_orders_for(syl: &GeneratedSyllable, case_mode: CaseMode) -> Vec<(&'static str, String)> {
    let apply_case = |ch: char, is_first: bool| -> char {
        match case_mode {
            CaseMode::Lower => ch,
            CaseMode::Title => {
                if is_first {
                    ch.to_ascii_uppercase()
                } else {
                    ch
                }
            }
            CaseMode::Upper => ch.to_ascii_uppercase(),
        }
    };
    let is_gi_single_i = syl.onset == "gi" && syl.vowels.len() == 1 && syl.vowels[0].base == 'i';
    let is_uow = syl.vowels.len() >= 2
        && syl.vowels[0].base == 'u'
        && syl.vowels[0].mark == Mark::Horn
        && syl.vowels[1].base == 'o'
        && syl.vowels[1].mark == Mark::Horn;

    let mut imm = String::new();
    let mut plain = String::new();
    let mut del_marks = String::new();
    let mut p = 0usize;

    if syl.onset == "đ" {
        imm.push(apply_case('d', true));
        imm.push('9');
        plain.push(apply_case('d', true));
        p += 1;
    } else {
        for ch in syl.onset.chars() {
            let c = apply_case(ch, p == 0);
            imm.push(c);
            plain.push(c);
            p += 1;
        }
    }

    if !is_gi_single_i {
        for (vi, v) in syl.vowels.iter().enumerate() {
            let c = apply_case(v.base, p == 0);
            imm.push(c);
            plain.push(c);
            p += 1;
            if is_uow && vi == 0 {
                continue;
            }
            match v.mark {
                Mark::Plain => {}
                Mark::Hat => {
                    imm.push('6');
                    del_marks.push('6');
                }
                Mark::Horn => {
                    imm.push('7');
                    del_marks.push('7');
                }
                Mark::Brev => {
                    imm.push('8');
                    del_marks.push('8');
                }
            }
        }
    }

    for ch in syl.coda.chars() {
        let c = apply_case(ch, false);
        imm.push(c);
        plain.push(c);
    }

    if let Some(td) = tone_vni_key(syl.tone) {
        imm.push(td);
    }

    let mut orders = vec![("vni_immediate", imm)];

    if syl.onset == "đ" || !del_marks.is_empty() {
        let mut del = plain;
        if syl.onset == "đ" {
            del.push('9');
        }
        del.push_str(&del_marks);
        if let Some(td) = tone_vni_key(syl.tone) {
            del.push(td);
        }
        orders.push(("vni_delayed", del));
    }

    orders
}

#[derive(Debug)]
struct StepAnomaly {
    kind: &'static str,
    detail: String,
}

fn simulate_typing(
    typer: &mut Typer,
    input: &str,
    check_word_sync: bool,
) -> (String, Vec<StepAnomaly>) {
    let mut screen = String::new();
    let mut anomalies = Vec::new();

    for (step_idx, ch) in input.chars().enumerate() {
        if ch == BS {
            typer.backspace();
            screen.pop();
            if check_word_sync {
                let trailing_word: String = screen
                    .rsplit(|c: char| c.is_whitespace() || matches!(c, '.' | ',' | '!' | '?' | '-'))
                    .next()
                    .unwrap_or("")
                    .to_string();
                let cw = typer.current_word();
                if cw != trailing_word {
                    anomalies.push(StepAnomaly {
                        kind: "word_sync_after_bs",
                        detail: format!(
                            "step={step_idx} BS input={input:?}: screen_word={trailing_word:?} != current_word={cw:?}"
                        ),
                    });
                }
            }
            continue;
        }

        let before = screen.clone();
        let action = typer.process_char(ch);
        match &action {
            EngineAction::Pass => screen.push(ch),
            EngineAction::Replace { n, chars } => {
                let old_count = before.chars().count();
                if usize::from(*n) > old_count {
                    anomalies.push(StepAnomaly {
                        kind: "over_delete",
                        detail: format!(
                            "step={step_idx} ch={ch:?} n={n} > old_count={old_count} before={before:?} input={input:?}"
                        ),
                    });
                }
                let pops = usize::from(*n).min(old_count);
                let mut next = before.clone();
                for _ in 0..pops {
                    next.pop();
                }
                next.push_str(chars);

                if !(*n == 0 && chars.is_empty()) {
                    let common = before
                        .chars()
                        .zip(next.chars())
                        .take_while(|(a, b)| a == b)
                        .count();
                    let min_n = old_count - common;
                    if usize::from(*n) != min_n {
                        anomalies.push(StepAnomaly {
                            kind: "non_minimal_diff",
                            detail: format!(
                                "step={step_idx} ch={ch:?} n={n} min_n={min_n} before={before:?} next={next:?} input={input:?}"
                            ),
                        });
                    }
                }
                screen = next;
            }
        }

        if check_word_sync && (ch.is_ascii_alphabetic() || ch == '_') {
            let trailing_word: String = screen
                .rsplit(|c: char| c.is_whitespace() || matches!(c, '.' | ',' | '!' | '?' | '-'))
                .next()
                .unwrap_or("")
                .to_string();
            let cw = typer.current_word();
            if cw != trailing_word {
                anomalies.push(StepAnomaly {
                    kind: "word_sync_after_key",
                    detail: format!(
                        "step={step_idx} ch={ch:?} input={input:?}: screen_word={trailing_word:?} != current_word={cw:?}"
                    ),
                });
            }
        }
    }

    (screen, anomalies)
}

#[test]
fn run_exhaustive_vietnamese_qa_audit() {
    let syllables = generate_all_vietnamese_syllables();
    println!(
        "=== GENERATED VIETNAMESE SYLLABLES: {} ===",
        syllables.len()
    );
    assert!(
        syllables.len() >= 6000,
        "Expected >= 6000 syllables, got {}",
        syllables.len()
    );

    let mut failures_by_cat: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut record_fail = |cat: &str, msg: String| {
        let list = failures_by_cat.entry(cat.to_string()).or_default();
        list.push(msg);
    };

    let mut total_telex_trials = 0usize;
    for orth in [Orthography::Traditional, Orthography::Modern] {
        for spell_check in [true, false] {
            let cfg = Config {
                method: InputMethod::Telex,
                orthography: orth,
                spell_check,
                repeated_restore: true,
                allow_w_consonant: true,
                ..Config::default()
            };
            for syl in &syllables {
                let want = format!("{} ", syl.render(orth, CaseMode::Lower));
                for (order_name, keys) in telex_orders_for(syl, CaseMode::Lower) {
                    if spell_check
                        && order_name == "telex_delayed_tone_then_mark"
                        && syl.coda.is_empty()
                        && syl.vowels.len() == 1
                    {
                        continue;
                    }
                    if spell_check
                        && order_name == "telex_std_mid"
                        && syl.onset == "b"
                        && syl.rime_name == "uy"
                    {
                        continue;
                    }
                    total_telex_trials += 1;
                    let keys_with_space = format!("{keys} ");
                    let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                    let (got, anomalies) = simulate_typing(&mut typer, &keys_with_space, true);
                    if got != want {
                        record_fail(
                            &format!("1_telex_{order_name}_orth={orth:?}_spell={spell_check}"),
                            format!(
                                "rime={} onset={:?} coda={:?} tone={:?} keys={keys_with_space:?} -> got={got:?}, want={want:?}",
                                syl.rime_name, syl.onset, syl.coda, syl.tone
                            ),
                        );
                    }
                    for a in anomalies {
                        record_fail(&format!("anomaly_{}", a.kind), a.detail);
                    }
                }
            }
        }
    }
    println!("=== TOTAL TELEX SYLLABLE TRIALS: {total_telex_trials} ===");

    {
        let cfg_default_app = Config {
            method: InputMethod::Telex,
            orthography: Orthography::Traditional,
            spell_check: true,
            repeated_restore: true,
            allow_w_consonant: true,
            ..Config::default()
        };
        let prompt_cases = [
            ("tieengs ", "tiếng "),
            ("tieesng ", "tiếng "),
            ("tiengse ", "tiếng "),
            ("tienges ", "tiếng "),
            ("dduwowcj ", "được "),
            ("dduowcj ", "được "),
            ("dduwocwj ", "được "),
            ("dduwongwf ", "đường "),
            ("duongwfd ", "đường "),
            ("nguowif ", "người "),
            ("nguwoiwf ", "người "),
            ("khuyur ", "khuỷu "),
            ("ngoaif ", "ngoài "),
            ("chuyeenr ", "chuyển "),
            ("chuyenre ", "chuyển "),
            ("chuyener ", "chuyển "),
            ("hoafn ", "hoàn "),
            ("quyeens ", "quyến "),
            ("quyens ", "quyến "),
            ("yens ", "yến "),
            ("giuawx ", "giữa "),
            ("giuwax ", "giữa "),
            ("gias ", "giá "),
            ("gief ", "giè "),
            ("gieem ", "giêm "),
            ("giem ", "giem "),
            ("giemf ", "gièm "),
            ("quas ", "quá "),
            ("quaf ", "quà "),
            ("quocs ", "quốc "),
            ("quoocs ", "quốc "),
            ("queeuf ", "quều "),
            ("queeus ", "quếu "),
            ("ngoemr ", "ngoẻm "),
            ("ngoerm ", "ngoẻm "),
            ("lene ", "lên "),
            ("tuoior ", "tuổi "),
            ("nhungwx ", "những "),
            ("muaw ", "mưa "),
            ("cuuws ", "cứu "),
            ("ruowuj ", "rượu "),
            ("ruoujw ", "rượu "),
            ("huowu ", "hươu "),
            ("huouw ", "hươu "),
            ("buowms ", "bướm "),
            ("buomws ", "bướm "),
            ("uowm ", "ươm "),
            ("uowps ", "ướp "),
            ("uowcs ", "ước "),
            ("uowts ", "ướt "),
            ("uown ", "ươn "),
            ("uowng ", "ương "),
            ("uowi ", "ươi "),
            ("uowu ", "ươu "),
            ("uw ", "ư "),
            ("ow ", "ơ "),
            ("xooong ", "xoong "),
            ("booong ", "boong "),
            ("mooocs ", "moóc "),
            ("sooocs ", "soóc "),
            ("gooongf ", "goòng "),
        ];
        for (keys, want) in prompt_cases {
            let mut typer = Typer::new(cfg_default_app.clone(), MacroTable::new());
            let (got, _) = simulate_typing(&mut typer, keys, false);
            if got != want {
                record_fail(
                    "2_specific_vietnamese_cases",
                    format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                );
            }
        }

        let cfg_w_vi = Config {
            allow_w_consonant: false,
            ..cfg_default_app.clone()
        };
        for (keys, want) in [
            ("w ", "ư "),
            ("ws ", "ứ "),
            ("wf ", "ừ "),
            ("wr ", "ử "),
            ("wx ", "ữ "),
            ("wj ", "ự "),
            ("nhw ", "như "),
            ("twj ", "tự "),
            ("thws ", "thứ "),
            ("ddwngf ", "đừng "),
            ("nwcs ", "nức "),
            ("nwocs ", "nước "),
            ("ddwongf ", "đường "),
        ] {
            let mut typer = Typer::new(cfg_w_vi.clone(), MacroTable::new());
            let (got, _) = simulate_typing(&mut typer, keys, false);
            if got != want {
                record_fail(
                    "2b_standalone_w_shorthand",
                    format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                );
            }
        }
    }

    {
        for spell_check in [true, false] {
            let cfg = Config {
                method: InputMethod::Telex,
                orthography: Orthography::Traditional,
                spell_check,
                repeated_restore: true,
                allow_w_consonant: true,
                ..Config::default()
            };
            let tone_replacement_cases = [
                ("toansf", "toàn"),
                ("toansz", "toan"),
                ("toasfjn", "toạn"),
                ("toaszn", "toan"),
                ("leensf", "lền"),
                ("leensfr", "lển"),
                ("leensfrx", "lễn"),
                ("leensfrxj", "lện"),
                ("leensfrxjz", "lên"),
                ("leesfrxjn", "lện"),
                ("leesfrxjzn", "lên"),
                ("dduowngfsrxjz", "đương"),
                ("hoafsz", "hoa"),
                ("hoafszn", "hoan"),
                ("ddienfs", "điến"),
                ("ddienfz", "đien"),
                ("muonjs", "muốn"),
                ("muonjz", "muon"),
            ];
            for (keys, want) in tone_replacement_cases {
                let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                let (got, anomalies) = simulate_typing(&mut typer, keys, true);
                if got != want {
                    record_fail(
                        &format!("3_tone_replace_z_spell={spell_check}"),
                        format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                    );
                }
                for a in anomalies {
                    record_fail(&format!("3_anomaly_{}", a.kind), a.detail);
                }
            }
        }
    }

    {
        for spell_check in [true, false] {
            let cfg = Config {
                method: InputMethod::Telex,
                orthography: Orthography::Traditional,
                spell_check,
                repeated_restore: true,
                allow_w_consonant: true,
                ..Config::default()
            };
            let escape_cases = [
                ("aaa", "aa"),
                ("eee", "ee"),
                ("ooo", "oo"),
                ("aww", "aw"),
                ("oww", "ow"),
                ("uww", "uw"),
                ("ddd", "dd"),
                ("ass", "as"),
                ("aff", "af"),
                ("arr", "ar"),
                ("axx", "ax"),
                ("ajj", "aj"),
                ("toool", "tool"),
                ("toools", "tools"),
                ("coooler", "cooler"),
                ("foooter", "footer"),
                ("boooking", "booking"),
                ("boookings", "bookings"),
                ("teeen", "teen"),
                ("teeenager", "teenager"),
                ("seeen", "seen"),
                ("seeeder", "seeder"),
                ("keeeper", "keeper"),
                ("neeeded", "needed"),
                ("freee", "free"),
                ("treee", "tree"),
                ("treees", "trees"),
                ("neeed", "need"),
                ("need", "need"),
                ("casse", "case"),
                ("casses", "cases"),
                ("basse", "base"),
                ("usse", "use"),
                ("usser", "user"),
                ("ussers", "users"),
                ("closse", "close"),
                ("housse", "house"),
                ("pausse", "pause"),
                ("morre", "more"),
                ("corre", "core"),
                ("carre", "care"),
                ("sharre", "share"),
                ("storre", "store"),
                ("herre", "here"),
                ("therre", "there"),
                ("firre", "fire"),
                ("surre", "sure"),
                ("purre", "pure"),
                ("saffe", "safe"),
                ("liffe", "life"),
                ("caffe", "cafe"),
                ("taxxi", "taxi"),
                ("dadda", "dada"),
                ("doddo", "dodo"),
                ("dedde", "dede"),
                ("diddi", "didi"),
            ];
            for (keys, want) in escape_cases {
                if spell_check
                    && matches!(
                        keys,
                        "foooter"
                            | "freee"
                            | "closse"
                            | "housse"
                            | "pausse"
                            | "sharre"
                            | "storre"
                            | "firre"
                            | "purre"
                    )
                {
                    continue;
                }
                if !spell_check && keys == "need" {
                    continue;
                }
                let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                let (got, anomalies) = simulate_typing(&mut typer, keys, true);
                if got != want {
                    record_fail(
                        &format!("4_escape_continuation_spell={spell_check}"),
                        format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                    );
                }
                for a in anomalies {
                    record_fail(
                        &format!("4_escape_sync_spell={spell_check}_{}", a.kind),
                        a.detail,
                    );
                }
            }
        }
    }

    {
        let cfg = Config {
            method: InputMethod::Telex,
            orthography: Orthography::Traditional,
            spell_check: true,
            repeated_restore: true,
            allow_w_consonant: true,
            ..Config::default()
        };
        for (i, syl) in syllables.iter().enumerate() {
            if i % 5 != 0 {
                continue;
            }
            for case_mode in [CaseMode::Title, CaseMode::Upper] {
                let want = format!("{} ", syl.render(Orthography::Traditional, case_mode));
                for (order_name, keys) in telex_orders_for(syl, case_mode) {
                    if order_name == "telex_delayed_tone_then_mark"
                        && syl.coda.is_empty()
                        && syl.vowels.len() == 1
                    {
                        continue;
                    }
                    let keys_sp = format!("{keys} ");
                    let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                    let (got, anomalies) = simulate_typing(&mut typer, &keys_sp, true);
                    if got != want {
                        record_fail(
                            &format!("5_caps_{case_mode:?}_{order_name}"),
                            format!("keys={keys_sp:?} -> got={got:?}, want={want:?}"),
                        );
                    }
                    for a in anomalies {
                        record_fail(&format!("5_caps_anomaly_{}", a.kind), a.detail);
                    }
                }
            }
        }

        for (keys, want) in [
            ("Vieetj ", "Việt "),
            ("DDuowngf ", "Đường "),
            ("Dduowngf ", "Đường "),
            ("Duongwfd ", "Đường "),
            ("Nguyeenx ", "Nguyễn "),
            ("Uowcs ", "Ước "),
            ("UWowcs ", "Ước "),
            ("Owr ", "Ở "),
            ("OWr ", "Ở "),
            ("VIEETJ NAM ", "VIỆT NAM "),
            ("DDUOWNGF ", "ĐƯỜNG "),
            ("HAYX ", "HÃY "),
            ("LEEN ", "LÊN "),
            ("TRUOWNGF ", "TRƯỜNG "),
        ] {
            let mut typer = Typer::new(cfg.clone(), MacroTable::new());
            let (got, _) = simulate_typing(&mut typer, keys, true);
            if got != want {
                record_fail(
                    "5b_explicit_caps",
                    format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                );
            }
        }

        let cfg_autocap = Config {
            auto_capitalize: true,
            ..cfg.clone()
        };
        for (keys, want) in [
            (
                "xin chaof. anh khoer khoong? toots lawms!",
                "Xin chào. Anh khỏe không? Tốt lắm!",
            ),
            (&format!("ddi{BS}{BS}viets"), "Viết"),
            ("uowcs mow. owr ddaay!", "Ước mơ. Ở đây!"),
        ] {
            let mut typer = Typer::new(cfg_autocap.clone(), MacroTable::new());
            let (got, anomalies) = simulate_typing(&mut typer, keys, true);
            if got != want {
                record_fail(
                    "5c_auto_capitalize",
                    format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                );
            }
            for a in anomalies {
                record_fail(&format!("5c_autocap_anomaly_{}", a.kind), a.detail);
            }
        }
    }

    {
        let cfg = Config {
            method: InputMethod::Telex,
            orthography: Orthography::Traditional,
            spell_check: true,
            repeated_restore: true,
            allow_w_consonant: true,
            ..Config::default()
        };

        for (i, syl) in syllables.iter().enumerate() {
            if i % 6 != 0 {
                continue;
            }
            let rendered = syl.render(Orthography::Traditional, CaseMode::Lower);
            let char_count = rendered.chars().count();
            let std_keys = &telex_orders_for(syl, CaseMode::Lower)[0].1;

            for bs_count in 1..=char_count {
                let mut seq = std_keys.clone();
                for _ in 0..bs_count {
                    seq.push(BS);
                }
                let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                let (got_after_bs, anomalies) = simulate_typing(&mut typer, &seq, true);
                let expected_prefix: String =
                    rendered.chars().take(char_count - bs_count).collect();
                if got_after_bs != expected_prefix {
                    record_fail(
                        "6a_backspace_prefix",
                        format!(
                            "keys={std_keys:?} bs={bs_count} -> got={got_after_bs:?}, want={expected_prefix:?}"
                        ),
                    );
                }
                for a in anomalies {
                    record_fail(&format!("6a_bs_anomaly_{}", a.kind), a.detail);
                }
            }
        }

        let bs_retype_cases = [
            (format!("tieengs{BS}{BS}p"), "tiếp"),
            (format!("tieengs{BS}{BS}c"), "tiếc"),
            (format!("dduowngf{BS}{BS}cj"), "được"),
            (format!("dduowngf{BS}{BS}{BS}{BS}i"), "đi"),
            (format!("dduowngf{BS}{BS}{BS}{BS}r"), "đr"),
            (format!("dduowngf{BS}{BS}{BS}{BS}aw "), "ddaw "),
            (format!("tieengs{BS}{BS}k"), "tieesk"),
            (format!("nguyeenx{BS}{BS}{BS}n"), "ngun"),
            (format!("toafn{BS}s"), "tóa"),
            (format!("huowng{BS}{BS}u"), "hươu"),
            (format!("seee{BS}e"), "sê"),
            (format!("casse{BS}e"), "case"),
        ];
        for (seq, want) in bs_retype_cases {
            let mut typer = Typer::new(cfg.clone(), MacroTable::new());
            let (got, anomalies) = simulate_typing(&mut typer, &seq, true);
            if got != want {
                record_fail(
                    "6b_backspace_retype_and_ghost_raw",
                    format!("seq={seq:?} -> got={got:?}, want={want:?}"),
                );
            }
            for a in anomalies {
                record_fail(&format!("6b_bs_retype_anomaly_{}", a.kind), a.detail);
            }
        }
    }

    {
        for spell_check in [true, false] {
            let cfg = Config {
                method: InputMethod::Vni,
                orthography: Orthography::Traditional,
                spell_check,
                repeated_restore: true,
                allow_w_consonant: true,
                ..Config::default()
            };
            for syl in &syllables {
                let want = format!("{} ", syl.render(Orthography::Traditional, CaseMode::Lower));
                for (order_name, keys) in vni_orders_for(syl, CaseMode::Lower) {
                    let keys_sp = format!("{keys} ");
                    let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                    let (got, anomalies) = simulate_typing(&mut typer, &keys_sp, false);
                    if got != want {
                        record_fail(
                            &format!("7_vni_{order_name}_spell={spell_check}"),
                            format!(
                                "rime={} onset={:?} coda={:?} tone={:?} keys={keys_sp:?} -> got={got:?}, want={want:?}",
                                syl.rime_name, syl.onset, syl.coda, syl.tone
                            ),
                        );
                    }
                    for a in anomalies {
                        record_fail(&format!("7_vni_anomaly_{}", a.kind), a.detail);
                    }
                }
            }

            let vni_tokens = [
                ("2026", "2026"),
                ("1000", "1000"),
                ("100.000", "100.000"),
                ("v1", "v1"),
                ("mp3", "mp3"),
                ("h2o", "h2o"),
                ("h2o2", "h2o2"),
                ("base64", "base64"),
                ("utf8", "utf8"),
                ("utf16", "utf16"),
                ("i18n", "i18n"),
                ("sha256", "sha256"),
                ("arm64", "arm64"),
                ("top10", "top10"),
                ("u23", "u23"),
            ];
            for (keys, want) in vni_tokens {
                if !spell_check
                    && matches!(
                        keys,
                        "base64" | "utf16" | "i18n" | "sha256" | "arm64" | "top10" | "u23"
                    )
                {
                    continue;
                }
                let mut typer = Typer::new(cfg.clone(), MacroTable::new());
                let (got, _) = simulate_typing(&mut typer, keys, false);
                if got != want {
                    record_fail(
                        &format!("7b_vni_tokens_spell={spell_check}"),
                        format!("keys={keys:?} -> got={got:?}, want={want:?}"),
                    );
                }
            }
        }
    }

    println!("\n================ QA AUDIT FAILURE SUMMARY ================");
    let mut total_fail_count = 0usize;
    for (cat, items) in &failures_by_cat {
        total_fail_count += items.len();
        println!("\n[{}] count = {}", cat, items.len());
        if cat.starts_with("1_telex_") || cat.starts_with("7_vni_vni_") {
            let mut by_rime: BTreeMap<String, (usize, String)> = BTreeMap::new();
            for item in items {
                let rime_key = item
                    .split(" keys=")
                    .next()
                    .unwrap_or(item)
                    .split(" onset=")
                    .next()
                    .unwrap_or(item)
                    .to_string();
                let coda_part = item
                    .split("coda=")
                    .nth(1)
                    .and_then(|s| s.split(' ').next())
                    .unwrap_or("");
                let group = format!("{rime_key} coda={coda_part}");
                let entry = by_rime.entry(group).or_insert_with(|| (0, item.clone()));
                entry.0 += 1;
            }
            for (group, (cnt, example)) in by_rime {
                println!("  * {group} -> {cnt} failures (e.g. {example})");
            }
        } else {
            for sample in items.iter().take(35) {
                println!("  - {sample}");
            }
            if items.len() > 35 {
                println!("  ... and {} more", items.len() - 35);
            }
        }
    }
    println!("\nTOTAL FAILURES ACROSS ALL CATEGORIES: {total_fail_count}");
    assert!(
        failures_by_cat.is_empty(),
        "Expected 0 failures in exhaustive Vietnamese QA audit, got {total_fail_count}"
    );
}

#[test]
fn run_permutations_mixed_caps_and_editing_edge_cases() {
    let mut issues: BTreeMap<&'static str, Vec<String>> = BTreeMap::new();
    let cfg_app = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        spell_check: true,
        repeated_restore: true,
        allow_w_consonant: true,
        ..Config::default()
    };

    let perm_cases = [
        ("dduowjc ", "được "),
        ("dduwowjc ", "được "),
        ("dduocjw ", "được "),
        ("duowcjd ", "được "),
        ("duocjwd ", "được "),
        ("dduowfng ", "đường "),
        ("dduwowfng ", "đường "),
        ("duowngfd ", "đường "),
        ("duongfwd ", "đường "),
        ("nguoifw ", "người "),
        ("nguowfi ", "người "),
        ("nguwowfi ", "người "),
        ("chuyeren ", "chuyển "),
        ("chuyreen ", "chuyển "),
        ("nguyexen ", "nguyễn "),
        ("nguyxeen ", "nguyễn "),
        ("tuyetse ", "tuyết "),
        ("tuyetes ", "tuyết "),
        ("tuyetje ", "tuyệt "),
        ("tuyetej ", "tuyệt "),
        ("hoacjw ", "hoặc "),
        ("hoawjc ", "hoặc "),
        ("hoajwc ", "hoặc "),
        ("xoansw ", "xoắn "),
        ("xoawsn ", "xoắn "),
        ("xoaswn ", "xoắn "),
        ("giuaxw ", "giữa "),
        ("giuxwa ", "giữa "),
        ("giuongfw ", "giường "),
        ("gieesng ", "giếng "),
        ("gifn ", "gìn "),
        ("ginf ", "gìn "),
        ("quocos ", "quốc "),
        ("quocso ", "quốc "),
        ("quoosc ", "quốc "),
        ("quayra ", "quẩy "),
        ("quayar ", "quẩy "),
        ("quarya ", "quẩy "),
        ("quanfw ", "quằn "),
        ("quawfn ", "quằn "),
        ("quafwn ", "quằn "),
        ("quyenfe ", "quyền "),
        ("quyefen ", "quyền "),
        ("ruowju ", "rượu "),
        ("ruojwu ", "rượu "),
        ("huwou ", "hươu "),
        ("huwouw ", "hươu "),
        ("buouws ", "bướu "),
        ("buousw ", "bướu "),
        ("khuyru ", "khuỷu "),
        ("ngoafi ", "ngoài "),
        ("ngoafo ", "ngoào "),
        ("ngoefo ", "ngoèo "),
        ("xoasy ", "xoáy "),
    ];
    for (keys, want) in perm_cases {
        let mut typer = Typer::new(cfg_app.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("A_fast_permutations")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let mixed_caps = [
        ("VIeetj ", "VIệt "),
        ("THuowng ", "THương "),
        ("TRuowngf ", "TRường "),
        ("NGuyeenx ", "NGuyễn "),
        ("CHuyeenr ", "CHuyển "),
        ("GIuowngf ", "GIường "),
        ("QUoocs ", "QUốc "),
        ("aA ", "â "),
        ("Aa ", "Â "),
        ("dD ", "đ "),
        ("Dd ", "Đ "),
        ("aS ", "á "),
        ("oW ", "ơ "),
        ("uW ", "ư "),
    ];
    for (keys, want) in mixed_caps {
        let mut typer = Typer::new(cfg_app.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, true);
        if got != want {
            issues
                .entry("B_mixed_caps")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let invalid_vi_boundary = [
        ("ties ", "ties "),
        ("lies ", "lies "),
        ("dies ", "dies "),
        ("pies ", "pies "),
        ("pier ", "pier "),
        ("tier ", "tier "),
        ("neus ", "neus "),
        ("reus ", "reus "),
        ("dada ", "dada "),
        ("dodo ", "dodo "),
        ("dede ", "dede "),
        ("dudu ", "dudu "),
        ("tuus ", "tuus "),
        ("muuf ", "muuf "),
        ("deeed ", "deed "),
        ("ddeenszz ", "đênz "),
        ("baszz ", "baz "),
        ("ddafcs ", "đác "),
    ];
    for (keys, want) in invalid_vi_boundary {
        let mut typer = Typer::new(cfg_app.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("C_boundary_and_tone_edge")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    {
        let mut macros = MacroTable::new();
        macros.insert("ko", "không");
        macros.insert("anh", "Anh Nguyễn");
        macros.insert("nh", "nhà");
        macros.insert("dc", "được");
        macros.insert("dch", "địa chỉ");
        let mut typer = Typer::new(
            Config {
                macro_enabled: true,
                ..cfg_app.clone()
            },
            macros,
        );
        for (keys, want) in [
            ("anhs ", "ánh "),
            ("nhaf ", "nhà "),
            ("korea ", "korea "),
            ("dch ", "địa chỉ "),
        ] {
            typer.reset();
            let (got, _) = simulate_typing(&mut typer, keys, false);
            if got != want {
                issues
                    .entry("D_macro_mid_word_collision")
                    .or_default()
                    .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
            }
        }
    }

    println!("\n================ PERMUTATIONS & EDGE CASES ================");
    for (cat, list) in &issues {
        println!("\n[{cat}] count = {}", list.len());
        for item in list {
            println!("  - {item}");
        }
    }
    assert!(
        issues.is_empty(),
        "Expected 0 failures in permutations & edge cases, got {:?}",
        issues.keys().collect::<Vec<_>>()
    );
}

#[test]
fn run_vietnamese_chat_shorthands_and_abbreviations() {
    let mut issues: BTreeMap<&'static str, Vec<String>> = BTreeMap::new();
    let cfg_telex = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        spell_check: true,
        repeated_restore: true,
        allow_w_consonant: true,
        ..Config::default()
    };
    let cfg_vni = Config {
        method: InputMethod::Vni,
        ..cfg_telex.clone()
    };

    let initial_d_shorthands = [
        ("dd ", "đ "),
        ("ddc ", "đc "),
        ("ddc?", "đc?"),
        ("ddc!", "đc!"),
        ("ddc.", "đc."),
        ("ddc,", "đc,"),
        ("ddk ", "đk "),
        ("ddt ", "đt "),
        ("ddg ", "đg "),
        ("ddh ", "đh "),
        ("ddv ", "đv "),
        ("ddb ", "đb "),
        ("ddn ", "đn "),
        ("ddl ", "đl "),
        ("ddm ", "đm "),
        ("ddcm ", "đcm "),
        ("ddcmm ", "đcmm "),
        ("ddhs ", "đhs "),
        ("dds ", "đs "),
        ("ddp ", "đp "),
        ("ddr ", "đr "),
        ("ddx ", "đx "),
        ("ddy ", "đy "),
        ("ddq ", "đq "),
        ("Ddc ", "Đc "),
        ("DDc ", "Đc "),
        ("DDC ", "ĐC "),
        ("DDHS ", "ĐHS "),
        ("DDR ", "ĐR "),
    ];
    for (keys, want) in initial_d_shorthands {
        let mut typer = Typer::new(cfg_telex.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("8a_initial_d_shorthands_telex")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let mid_d_shorthands = [
        ("sddt ", "sđt "),
        ("sddt:", "sđt:"),
        ("gdd ", "gđ "),
        ("hdd ", "hđ "),
        ("qdd ", "qđ "),
        ("bdds ", "bđs "),
        ("vddv ", "vđv "),
        ("cddv ", "cđv "),
        ("nddt ", "nđt "),
        ("tdd ", "tđ "),
        ("ldd ", "lđ "),
        ("mdd ", "mđ "),
        ("hddnd ", "hđnd "),
        ("hddqt ", "hđqt "),
        ("ddhbkhn ", "đhbkhn "),
        ("ddhqg ", "đhqg "),
        ("ddhddn ", "đhđn "),
        ("ddbdd ", "đbđ "),
        ("SDDT ", "SĐT "),
        ("Gdd ", "Gđ "),
        ("GDD ", "GĐ "),
        ("BDDS ", "BĐS "),
        ("HDDND ", "HĐND "),
        ("HDDQT ", "HĐQT "),
    ];
    for (keys, want) in mid_d_shorthands {
        let mut typer = Typer::new(cfg_telex.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("8b_mid_word_d_shorthands_telex")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let vni_d_shorthands = [
        ("d9c ", "đc "),
        ("d9k ", "đk "),
        ("d9t ", "đt "),
        ("d9r ", "đr "),
        ("d9hs ", "đhs "),
        ("sd9t ", "sđt "),
        ("gd9 ", "gđ "),
        ("hd9 ", "hđ "),
        ("bd9s ", "bđs "),
    ];
    for (keys, want) in vni_d_shorthands {
        let mut typer = Typer::new(cfg_vni.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("8c_d_shorthands_vni")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let plain_shorthands_and_english_dd = [
        ("bt ", "bt "),
        ("ko ", "ko "),
        ("k ", "k "),
        ("uk ", "uk "),
        ("uhm ", "uhm "),
        ("cx ", "cx "),
        ("nx ", "nx "),
        ("trc ", "trc "),
        ("ng ", "ng "),
        ("mn ", "mn "),
        ("nc ", "nc "),
        ("ns ", "ns "),
        ("nt ", "nt "),
        ("nv ", "nv "),
        ("ny ", "ny "),
        ("vk ", "vk "),
        ("ck ", "ck "),
        ("mk ", "mk "),
        ("ik ", "ik "),
        ("ak ", "ak "),
        ("ok ", "ok "),
        ("vs ", "vs "),
        ("ms ", "ms "),
        ("bh ", "bh "),
        ("bn ", "bn "),
        ("bnh ", "bnh "),
        ("j ", "j "),
        ("z ", "z "),
        ("dddc ", "ddc "),
        ("sdddt ", "sddt "),
        ("hddd ", "hdd "),
        ("ddca ", "ddca "),
        ("sdda ", "sdda "),
        ("add ", "add "),
        ("adds ", "adds "),
        ("added ", "added "),
        ("odd ", "odd "),
        ("odds ", "odds "),
        ("middle ", "middle "),
        ("hidden ", "hidden "),
        ("reddit ", "reddit "),
        ("padding ", "padding "),
        ("daddy ", "daddy "),
        ("buddy ", "buddy "),
        ("teddy ", "teddy "),
        ("sudden ", "sudden "),
        ("wedding ", "wedding "),
        ("address ", "address "),
        ("toddler ", "toddler "),
    ];
    for (keys, want) in plain_shorthands_and_english_dd {
        let mut typer = Typer::new(cfg_telex.clone(), MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, keys, false);
        if got != want {
            issues
                .entry("8d_plain_shorthands_and_english_dd")
                .or_default()
                .push(format!("keys={keys:?} -> got={got:?}, want={want:?}"));
        }
    }

    let chat_sentence = "ok mn owi, chieeuf nay ddc ko, cho mk xin sddt vaf ddc cuar gdd b nhes!";
    let expected_chat = "ok mn ơi, chiều nay đc ko, cho mk xin sđt và đc của gđ b nhé!";
    {
        let mut typer = Typer::new(cfg_telex, MacroTable::new());
        let (got, _) = simulate_typing(&mut typer, chat_sentence, false);
        if got != expected_chat {
            issues
                .entry("8e_real_chat_sentence")
                .or_default()
                .push(format!("got={got:?}\n    want={expected_chat:?}"));
        }
    }

    println!("\n================ VIETNAMESE CHAT SHORTHANDS QA ================");
    for (cat, list) in &issues {
        println!("\n[{cat}] count = {}", list.len());
        for item in list {
            println!("  - {item}");
        }
    }
    assert!(
        issues.is_empty(),
        "Expected 0 failures in Vietnamese chat shorthands QA, got {:?}",
        issues.keys().collect::<Vec<_>>()
    );
}
