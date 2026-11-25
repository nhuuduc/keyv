use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Orthography, Typer};

fn assert_minimal_stepwise(input: &str, want: &str, cfg: Config) {
    let mut typer = Typer::new(cfg, MacroTable::new());
    let mut screen = String::new();
    for (step_idx, ch) in input.chars().enumerate() {
        let before = screen.clone();
        let action = typer.process_char(ch);
        match &action {
            EngineAction::Pass => {
                screen.push(ch);
            }
            EngineAction::Replace { n, chars } => {
                let old_count = before.chars().count();
                assert!(
                    usize::from(*n) <= old_count,
                    "over-delete step={step_idx} ch={ch:?} n={n} before={before:?} input={input:?}"
                );
                let mut next = before.clone();
                for _ in 0..*n {
                    next.pop();
                }
                next.push_str(chars);

                let common_prefix = before
                    .chars()
                    .zip(next.chars())
                    .take_while(|(a, b)| a == b)
                    .count();
                let minimal_n = old_count - common_prefix;
                assert_eq!(
                    usize::from(*n),
                    minimal_n,
                    "non-minimal backspace count at step={step_idx} ch={ch:?} action={action:?} before={before:?} next={next:?} input={input:?}"
                );
                let minimal_suffix: String = next.chars().skip(common_prefix).collect();
                assert_eq!(
                    chars, &minimal_suffix,
                    "non-minimal suffix at step={step_idx} ch={ch:?} action={action:?} before={before:?} next={next:?} input={input:?}"
                );
                assert!(
                    !(minimal_n == 0
                        && next.chars().count() == old_count + 1
                        && minimal_suffix == ch.to_string()),
                    "should have been Pass instead of Replace(0, {ch:?}) at step={step_idx} input={input:?}"
                );
                screen = next;
            }
        }
    }
    assert_eq!(screen, want, "final mismatch for input={input:?}");
}

#[test]
fn fast_typing_hay_and_common_words_minimal_diff_both_orthographies() {
    for orth in [Orthography::Traditional, Orthography::Modern] {
        for spell_check in [false, true] {
            let cfg = Config {
                method: InputMethod::Telex,
                orthography: orth,
                spell_check,
                repeated_restore: true,
                allow_w_consonant: true,
                ..Config::default()
            };

            let mut t1 = Typer::new(cfg.clone(), MacroTable::new());
            assert_eq!(t1.process_char('h'), EngineAction::Pass);
            assert_eq!(t1.process_char('a'), EngineAction::Pass);
            assert_eq!(t1.process_char('y'), EngineAction::Pass);
            assert_eq!(
                t1.process_char('x'),
                EngineAction::Replace {
                    n: 2,
                    chars: "ãy".to_string()
                }
            );

            let mut t2 = Typer::new(cfg.clone(), MacroTable::new());
            assert_eq!(t2.process_char('h'), EngineAction::Pass);
            assert_eq!(t2.process_char('a'), EngineAction::Pass);
            assert_eq!(
                t2.process_char('x'),
                EngineAction::Replace {
                    n: 1,
                    chars: "ã".to_string()
                }
            );
            assert_eq!(t2.process_char('y'), EngineAction::Pass);

            for (keys, want) in [
                ("hayx", "hãy"),
                ("haxy", "hãy"),
                ("hayx ", "hãy "),
                ("haxy ", "hãy "),
                ("hays", "háy"),
                ("hasy", "háy"),
                ("toois", "tối"),
                ("toiso", "tối"),
                ("dduowcj", "được"),
                ("dduwowcj", "được"),
                ("dduocwj", "được"),
                ("duocwjd", "được"),
                ("nguowif", "người"),
                ("nguwowif", "người"),
                ("nguoiwf", "người"),
                ("tieengs", "tiếng"),
                ("tieesng", "tiếng"),
                ("tiengse", "tiếng"),
                ("vieetj", "việt"),
                ("vieejt", "việt"),
                ("nhanh", "nhanh"),
                ("khoong", "không"),
                ("khongo", "không"),
                ("khongf", "khòng"),
                ("ddang", "đang"),
                ("dangd", "đang"),
                ("chuyeenr", "chuyển"),
                ("chuyener", "chuyển"),
                ("nguyeenx", "nguyễn"),
                ("truowngf", "trường"),
                ("thuowng", "thương"),
                ("giuowngf", "giường"),
                ("quoocs", "quốc"),
                ("nghiax", "nghĩa"),
                ("nghixa", "nghĩa"),
                (
                    "hayx gox tieengs Vieetj thaatj nhanh vaf oonr ddinhj",
                    "hãy gõ tiếng Việt thật nhanh và ổn định",
                ),
            ] {
                assert_minimal_stepwise(keys, want, cfg.clone());
            }
        }
    }
}

#[test]
fn duplicate_tone_when_repeated_restore_disabled_emits_zero_backspaces() {
    let cfg = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Modern,
        allow_w_consonant: false,
        repeated_restore: false,
        spell_check: false,
        ..Config::default()
    };
    let mut typer = Typer::new(cfg.clone(), MacroTable::new());
    assert_eq!(typer.process_char('h'), EngineAction::Pass);
    assert_eq!(typer.process_char('a'), EngineAction::Pass);
    assert_eq!(typer.process_char('y'), EngineAction::Pass);
    assert_eq!(
        typer.process_char('x'),
        EngineAction::Replace {
            n: 2,
            chars: "ãy".to_string()
        }
    );
    assert_eq!(
        typer.process_char('x'),
        EngineAction::Replace {
            n: 0,
            chars: String::new()
        }
    );
    assert_minimal_stepwise("ddienfe", "điền", cfg);
}

#[test]
fn english_words_and_w_handling_in_telex_mode() {
    let cfg = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        allow_w_consonant: true,
        repeated_restore: true,
        spell_check: true,
        ..Config::default()
    };

    assert_minimal_stepwise("test", "tét", cfg.clone());
    assert_minimal_stepwise("tess", "tes", cfg.clone());
    assert_minimal_stepwise("tesst", "test", cfg.clone());

    for word in [
        "tests",
        "testing",
        "tester",
        "tested",
        "dested",
        "rests",
        "resting",
        "rester",
        "bests",
        "bested",
        "posts",
        "costs",
        "hosts",
        "lists",
        "casts",
        "lasts",
        "west",
        "next",
        "text",
        "left",
        "soft",
        "lift",
        "gift",
        "part",
        "cart",
        "sort",
        "port",
        "hurt",
        "chart",
        "march",
        "arch",
        "set",
        "get",
        "gets",
        "gems",
        "gene",
        "gesture",
        "cell",
        "center",
        "city",
        "cyber",
        "nginx",
        "let",
        "net",
        "met",
        "pet",
        "wet",
        "yet",
        "jet",
        "bet",
        "w",
        "W",
        "www",
        "web",
        "wifi",
        "win",
        "window",
        "work",
        "world",
        "with",
        "water",
        "wait",
        "watch",
        "write",
        "wrong",
        "worm",
        "worn",
        "two",
        "sweet",
        "tweet",
        "between",
        "power",
        "tower",
        "flower",
        "shower",
        "lower",
        "follow",
        "borrow",
        "arrow",
        "sorry",
        "carry",
        "error",
        "coffee",
        "office",
        "offer",
        "session",
        "message",
        "yellow",
        "show",
        "know",
        "grow",
        "flow",
        "slow",
        "draw",
        "view",
        "new",
        "few",
        "news",
        "review",
        "interview",
        "awesome",
        "away",
        "aware",
        "award",
        "0xcafe",
        "is_valid",
        "as_ref",
        "authenticationserviceproviderconfigurationmanager",
    ] {
        assert_minimal_stepwise(word, word, cfg.clone());
    }

    for (keys, want) in [
        ("raw ", "raw "),
        ("saw ", "saw "),
        ("law ", "law "),
        ("paw ", "paw "),
        ("jaw ", "jaw "),
        ("raw.", "raw."),
        ("saw,", "saw,"),
        ("rawng ", "răng "),
        ("sawts ", "sắt "),
        ("lawms ", "lắm "),
        ("awn ", "ăn "),
        ("dd ", "đ "),
    ] {
        assert_minimal_stepwise(keys, want, cfg.clone());
    }

    let cfg_no_repeat = Config {
        repeated_restore: false,
        ..cfg
    };
    for word in [
        "tests", "testing", "tester", "tested", "next", "text", "west", "web", "w",
    ] {
        assert_minimal_stepwise(word, word, cfg_no_repeat.clone());
    }
}

#[test]
fn vni_minimal_diff_and_spell_check_parity() {
    let cfg = Config {
        method: InputMethod::Vni,
        spell_check: true,
        repeated_restore: true,
        ..Config::default()
    };
    for (keys, want) in [
        ("muon56", "muộn"),
        ("d9ien26", "điền"),
        ("mia6", "mia6"),
        ("tau7", "tau7"),
        ("tai8", "tai8"),
        ("dabc9", "dabc9"),
        ("i18n", "i18n"),
        ("xcode16a1", "xcode16a1"),
    ] {
        assert_minimal_stepwise(keys, want, cfg.clone());
    }
}
