//! Public UniKey Telex/VNI conventions, not a claim of full Windows parity.
//! Reference: https://www.unikey.org/support/ukmanual.html sections 3.2 and 3.6.
use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Typer};

fn replay(input: &str, cfg: Config) -> String {
    let mut engine = Typer::new(cfg, MacroTable::new());
    let mut screen = String::new();
    for ch in input.chars() {
        match engine.process_char(ch) {
            EngineAction::Pass => screen.push(ch),
            EngineAction::Replace { n, chars } => {
                assert!(
                    usize::from(n) <= screen.chars().count(),
                    "over-delete for {input}"
                );
                for _ in 0..n {
                    screen.pop();
                }
                screen.push_str(&chars);
            }
        }
    }
    screen
}

#[test]
fn english_w_when_literal_option_enabled() {
    for word in ["w", "win", "Win", "WIN", "wiki", "www", "win win"] {
        assert_eq!(replay(word, Config::default()), word, "{word}");
    }
}

#[test]
fn unikey_leading_w_escape() {
    let cfg = Config {
        allow_w_consonant: false,
        ..Config::default()
    };
    for (keys, want) in [
        ("w", "ư"),
        ("W", "Ư"),
        ("ww", "w"),
        ("WW", "W"),
        ("wwin", "win"),
        ("WWin", "Win"),
        ("WWindowws", "Windows"),
        ("Wf", "Ừ"),
    ] {
        assert_eq!(replay(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn repeated_marks_restore_literal_keys() {
    for (keys, want) in [
        ("aaa", "aa"),
        ("eee", "ee"),
        ("ooo", "oo"),
        ("ddd", "dd"),
        ("aww", "aw"),
        ("oww", "ow"),
        ("uww", "uw"),
        ("AAA", "AA"),
        ("DDD", "DD"),
        ("guitarr", "guitar"),
    ] {
        assert_eq!(replay(keys, Config::default()), want, "{keys}");
    }
}

#[test]
fn repeated_mark_restore_can_be_disabled() {
    let cfg = Config {
        repeated_restore: false,
        allow_w_consonant: false,
        ..Config::default()
    };
    for (keys, want) in [("aaa", "âa"), ("ddd", "đd"), ("ww", "ưw"), ("aww", "ăw")] {
        assert_eq!(replay(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn vietnamese_basics_and_all_tones_remain_supported() {
    for (keys, want) in [
        ("as", "á"),
        ("af", "à"),
        ("ar", "ả"),
        ("ax", "ã"),
        ("aj", "ạ"),
        ("aa", "â"),
        ("ee", "ê"),
        ("oo", "ô"),
        ("aw", "ă"),
        ("ow", "ơ"),
        ("uw", "ư"),
        ("dd", "đ"),
        ("tieengs Vieetj", "tiếng Việt"),
        ("dduwowngf", "đường"),
        ("toanfs", "toán"),
        ("ddawng", "đăng"),
    ] {
        assert_eq!(replay(keys, Config::default()), want, "{keys}");
    }
}

#[test]
fn repeated_vni_tones_restore_digits() {
    let cfg = Config {
        method: InputMethod::Vni,
        ..Config::default()
    };
    for (keys, want) in [
        ("e11", "e1"),
        ("a22", "a2"),
        ("o33", "o3"),
        ("u44", "u4"),
        ("i55", "i5"),
    ] {
        assert_eq!(replay(keys, cfg.clone()), want, "{keys}");
    }
}
