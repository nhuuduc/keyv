//! Regression: macro-enabled Typer must not panic on normal typing.

use keyv_core::config::{Config, InputMethod, Orthography};
use keyv_core::engine::Typer;
use keyv_core::macro_::MacroTable;

#[test]
fn macro_enabled_typer_handles_plain_typing() {
    let cfg = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        macro_enabled: true,
        allow_w_consonant: true,
        repeated_restore: true,
        auto_capitalize: false,
    };
    let mut typer = Typer::new(cfg, MacroTable::new());
    typer.set_macro("hvbt", "nhé bạn");

    // Plain letters must pass through without panicking.
    for ch in "ha".chars() {
        let _ = typer.process_char(ch);
    }
}

#[test]
fn macro_expansion_fires_on_match() {
    let cfg = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        macro_enabled: true,
        allow_w_consonant: true,
        repeated_restore: true,
        auto_capitalize: false,
    };
    let mut typer = Typer::new(cfg, MacroTable::new());
    typer.set_macro("hvbt", "nhé bạn");

    let mut screen = String::new();
    for ch in "hvbt".chars() {
        match typer.process_char(ch) {
            keyv_core::engine::EngineAction::Pass => screen.push(ch),
            keyv_core::engine::EngineAction::Replace { n, chars } => {
                for _ in 0..n {
                    screen.pop();
                }
                screen.push_str(&chars);
            }
        }
    }
    assert_eq!(screen, "nhé bạn");
}

#[test]
fn macro_disabled_no_expansion() {
    let cfg = Config {
        method: InputMethod::Telex,
        orthography: Orthography::Traditional,
        macro_enabled: false,
        allow_w_consonant: true,
        repeated_restore: true,
        auto_capitalize: false,
    };
    let mut typer = Typer::new(cfg, MacroTable::new());
    typer.set_macro("hvbt", "nhé bạn");

    let mut screen = String::new();
    for ch in "hvbt".chars() {
        match typer.process_char(ch) {
            keyv_core::engine::EngineAction::Pass => screen.push(ch),
            keyv_core::engine::EngineAction::Replace { n, chars } => {
                for _ in 0..n {
                    screen.pop();
                }
                screen.push_str(&chars);
            }
        }
    }
    assert_eq!(screen, "hvbt");
}
