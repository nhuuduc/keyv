use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Orthography, Typer};

const BS: char = '\u{0008}';

fn simulate(typer: &mut Typer, input: &str) -> String {
    let mut screen = String::new();
    for (step_idx, ch) in input.chars().enumerate() {
        if ch == BS {
            typer.backspace();
            screen.pop();
            continue;
        }
        let before = screen.clone();
        let action = typer.process_char(ch);
        match action {
            EngineAction::Pass => screen.push(ch),
            EngineAction::Replace { n, chars } => {
                let old_count = before.chars().count();
                assert!(
                    usize::from(n) <= old_count,
                    "over-delete at step={step_idx} ch={ch:?} n={n} before={before:?} input={input:?}"
                );
                for _ in 0..n {
                    screen.pop();
                }
                screen.push_str(&chars);
                if !(n == 0 && chars.is_empty()) {
                    let common = before
                        .chars()
                        .zip(screen.chars())
                        .take_while(|(a, b)| a == b)
                        .count();
                    let min_n = old_count - common;
                    assert_eq!(
                        usize::from(n),
                        min_n,
                        "non-minimal diff at step={step_idx} ch={ch:?} before={before:?} next={screen:?} input={input:?}"
                    );
                }
            }
        }
    }
    screen
}

fn default_app_cfg() -> Config {
    Config {
        method: InputMethod::Telex,
        orthography: Orthography::Modern,
        macro_enabled: false,
        allow_w_consonant: true,
        repeated_restore: true,
        auto_capitalize: false,
        spell_check: true,
    }
}

#[test]
fn natural_english_and_unikey_double_key_escape_invariants() {
    for orth in [Orthography::Traditional, Orthography::Modern] {
        let cfg = Config {
            orthography: orth,
            ..default_app_cfg()
        };

        for word in [
            "case",
            "base",
            "phase",
            "use",
            "core",
            "more",
            "here",
            "there",
            "these",
            "reset",
            "cheese",
            "keeper",
            "horse",
            "verse",
            "cursor",
            "user",
            "boxes",
            "virus",
            "boys",
            "guys",
            "buys",
            "busy",
            "pawn",
            "pass",
            "password",
            "passport",
            "tomorrow",
            "necessary",
            "downward",
            "arizona",
            "anagram",
            "barnard",
            "refuse",
            "major",
            "ajax",
            "turns",
            "loser",
            "quiets",
            "offline",
            "afflict",
            "coffee",
            "office",
            "offer",
            "session",
            "message",
            "borrow",
            "arrow",
            "sorry",
            "carry",
            "error",
            "daddy",
            "dandy",
        ] {
            let mut typer = Typer::new(cfg.clone(), MacroTable::new());
            assert_eq!(
                simulate(&mut typer, word),
                word,
                "4/5/6-letter English literal failed for {word:?} ({orth:?})"
            );
            assert_eq!(
                typer.current_word(),
                word,
                "current_word desync for {word:?}"
            );
        }

        for (escaped_keys, want) in [
            ("casse", "case"),
            ("casses", "cases"),
            ("basse", "base"),
            ("phasse", "phase"),
            ("morre", "more"),
            ("corre", "core"),
            ("herre", "here"),
            ("therre", "there"),
            ("saffe", "safe"),
            ("liffe", "life"),
            ("caffe", "cafe"),
            ("usse", "use"),
            ("usser", "user"),
            ("ussers", "users"),
            ("dadda", "dada"),
            ("dudde", "dude"),
            ("taxxi", "taxi"),
            ("tesst", "test"),
        ] {
            let mut typer = Typer::new(cfg.clone(), MacroTable::new());
            assert_eq!(
                simulate(&mut typer, escaped_keys),
                want,
                "double-key escape failed for {escaped_keys:?} ({orth:?})"
            );
            assert_eq!(
                typer.current_word(),
                want,
                "raw/current_word desync after escape for {escaped_keys:?}"
            );
        }

        let owner_sentence = "3 agent ddeer tesst toafn booj cacs casse ddi vaf ddc ko ";
        let expected_owner = "3 agent để test toàn bộ các case đi và đc ko ";
        let mut typer = Typer::new(cfg, MacroTable::new());
        assert_eq!(simulate(&mut typer, owner_sentence), expected_owner);
    }
}

#[test]
fn camel_case_contractions_and_z_zero_restoration() {
    let cfg = default_app_cfg();

    for ident in [
        "useRef",
        "useState",
        "useEffect",
        "onRow",
        "isState",
        "hasCase",
        "toSet",
        "doId",
        "dataData",
        "userSet",
        "asRef",
        "onClick",
        "getElementById",
    ] {
        let mut typer = Typer::new(cfg.clone(), MacroTable::new());
        assert_eq!(simulate(&mut typer, ident), ident, "camelCase {ident:?}");
    }

    for contraction in [
        "isn't ", "don't ", "can't ", "hasn't ", "doesn't ", "there's ", "here's ", "user's ",
        "won't ", "didn't ",
    ] {
        let mut typer = Typer::new(cfg.clone(), MacroTable::new());
        assert_eq!(
            simulate(&mut typer, contraction),
            contraction,
            "contraction {contraction:?}"
        );
    }

    let mut typer = Typer::new(cfg.clone(), MacroTable::new());
    assert_eq!(
        simulate(&mut typer, "'tieengs' 'hans'. "),
        "'tiếng' 'hán'. "
    );

    let cfg_vni = Config {
        method: InputMethod::Vni,
        ..cfg
    };
    let mut vni_typer = Typer::new(cfg_vni, MacroTable::new());
    assert_eq!(simulate(&mut vni_typer, "ha20x "), "ha20x ");
    assert_eq!(
        simulate(&mut vni_typer, "luu7 cuu71 huu74 "),
        "lưu cứu hữu "
    );
}

#[test]
fn vietnamese_shorthands_rare_rimes_and_backspace_sync() {
    let cfg = Config {
        orthography: Orthography::Traditional,
        ..default_app_cfg()
    };

    for (keys, want) in [
        ("ddc ", "đc "),
        ("ddk ", "đk "),
        ("ddt ", "đt "),
        ("ddg ", "đg "),
        ("ddh ", "đh "),
        ("ddv ", "đv "),
        ("ddb ", "đb "),
        ("ddr ", "đr "),
        ("dds ", "đs "),
        ("ddx ", "đx "),
        ("ddhs ", "đhs "),
        ("ddcm ", "đcm "),
        ("ddy ", "đy "),
        ("sddt ", "sđt "),
        ("gdd ", "gđ "),
        ("hdd ", "hđ "),
        ("qdd ", "qđ "),
        ("bdds ", "bđs "),
        ("vddv ", "vđv "),
        ("vndd ", "vnđ "),
        ("hddqt ", "hđqt "),
        ("ddhddn ", "đhđn "),
        ("dddc ", "ddc "),
        ("sdddt ", "sddt "),
        ("hddd ", "hdd "),
        ("dvd ", "dvd "),
        ("dnd ", "dnd "),
        ("dtd ", "dtd "),
        ("ddraw ", "ddraw "),
        ("sdda ", "sdda "),
        ("khueechs ", "khuếch "),
        ("ngueechj ", "nguệch "),
        ("huychs ", "huých "),
        ("ngoemr ", "ngoẻm "),
        ("queeuf ", "quều "),
        ("dduwongwf ", "đường "),
        ("huwou ", "hươu "),
        ("yens ", "yến "),
        ("quyens ", "quyến "),
        ("chuyenj ", "chuyện "),
        ("tuyets ", "tuyết "),
        ("nguyenx ", "nguyễn "),
        ("mooocs ", "moóc "),
        ("sooocs ", "soóc "),
        ("gooongf ", "goòng "),
        ("xooong ", "xoong "),
    ] {
        let mut typer = Typer::new(cfg.clone(), MacroTable::new());
        assert_eq!(simulate(&mut typer, keys), want, "keys={keys:?}");
    }

    for (seq, want) in [
        (format!("toas{BS}l"), "tosl"),
        (format!("dand{BS}l"), "ddal"),
        (format!("ddas{BS}og"), "ddog"),
        (format!("dduowngf{BS}{BS}cj"), "được"),
        (format!("tieengs{BS}{BS}p"), "tiếp"),
        (format!("coool{BS}r"), "coor"),
        (format!("dddc{BS}c"), "ddc"),
        (format!("sdddt{BS}t"), "sddt"),
    ] {
        let mut typer = Typer::new(cfg.clone(), MacroTable::new());
        assert_eq!(simulate(&mut typer, &seq), want, "seq={seq:?}");
    }

    let mut modern_typer = Typer::new(default_app_cfg(), MacroTable::new());
    assert_eq!(simulate(&mut modern_typer, &format!("toas{BS}l")), "tol");
}
