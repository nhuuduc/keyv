//! End-to-end engine tests: a mini "screen simulator" replays key presses
//! into an output string, applying Pass/Replace semantics exactly like the
//! Swift host will (backspaces pop `n` chars, then append `chars`).

use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Orthography, Typer};

/// Replay characters through the engine into a simulated screen.
fn type_str(typer: &mut Typer, input: &str) -> String {
    let mut out = String::new();
    for ch in input.chars() {
        match typer.process_char(ch) {
            EngineAction::Pass => out.push(ch),
            EngineAction::Replace { n, chars } => {
                let pops = n.min(out.chars().count() as u8);
                for _ in 0..pops {
                    out.pop();
                }
                out.push_str(&chars);
            }
        }
    }
    out
}

fn typer_with(cfg: Config) -> Typer {
    Typer::new(cfg, MacroTable::new())
}

fn telex() -> Typer {
    typer_with(Config {
        method: InputMethod::Telex,
        ..Default::default()
    })
}

// --------------------------------------------------------------- Telex ---

#[test]
fn dd_stroke() {
    assert_eq!(type_str(&mut telex(), "dd"), "đ");
    assert_eq!(type_str(&mut telex(), "DD"), "Đ");
    // Repeating d restores the literal pair, as in UniKey.
    assert_eq!(type_str(&mut telex(), "ddd"), "dd");
}

#[test]
fn dd_full_word() {
    assert_eq!(type_str(&mut telex(), "ddawng"), "đăng");
    assert_eq!(type_str(&mut telex(), "dien"), "dien");
    assert_eq!(type_str(&mut telex(), "ddieeu"), "điêu"); // open rhyme, no tone
    assert_eq!(type_str(&mut telex(), "ddieeuf"), "điều");
    assert_eq!(type_str(&mut telex(), "ddienf"), "điền"); // auto-circ on closed rhyme
}

#[test]
fn tone_keys_on_single_vowel() {
    // s f r x j → sắc huyền hỏi ngã nặng
    assert_eq!(type_str(&mut telex(), "haf"), "hà");
    assert_eq!(type_str(&mut telex(), "has"), "há");
    assert_eq!(type_str(&mut telex(), "her"), "hẻ");
    assert_eq!(type_str(&mut telex(), "hex"), "hẽ");
    assert_eq!(type_str(&mut telex(), "hoj"), "họ");
    // tone key with no nucleus restores the letter literally
    assert_eq!(type_str(&mut telex(), "hs"), "hs");
}

#[test]
fn duplicate_circumflex() {
    assert_eq!(type_str(&mut telex(), "aa"), "â");
    assert_eq!(type_str(&mut telex(), "caa"), "câ");
    assert_eq!(type_str(&mut telex(), "see"), "sê");
    assert_eq!(type_str(&mut telex(), "hoor"), "hổ");
    // Repeating a restores literal aa.
    assert_eq!(type_str(&mut telex(), "caaa"), "caa");
}

#[test]
fn w_marks() {
    // aw → ă, ow → ơ, uw → ư
    assert_eq!(type_str(&mut telex(), "mawts"), "mắt");
    assert_eq!(type_str(&mut telex(), "cow"), "cơ");
    assert_eq!(type_str(&mut telex(), "cuw"), "cư");
    // tone after a transformed horn
    assert_eq!(type_str(&mut telex(), "cuwf"), "cừ");
    assert_eq!(type_str(&mut telex(), "cawf"), "cằ");
}

#[test]
fn tone_pair_placement_traditional() {
    // default config: Orthography::Traditional (kiểu cũ: òa, úy)
    let mut t = telex();
    assert_eq!(type_str(&mut t, "toaf"), "tòa");
    t.reset(); // words are separator-bound; reset between trials
    assert_eq!(type_str(&mut t, "uof"), "uò");
    // (u,a) with huyền: tone on the first vowel
    assert_eq!(type_str(&mut telex(), "muaf"), "mùa");
    // (i,a) with sắc: tone on i
    assert_eq!(type_str(&mut telex(), "mias"), "mía");
    // closed rhymes keep the tone on the second vowel, with auto-circumflex
    assert_eq!(type_str(&mut telex(), "muonj"), "muộn");
    // generic last-vowel pairs
    assert_eq!(type_str(&mut telex(), "maif"), "mài");
    assert_eq!(type_str(&mut telex(), "maof"), "mào");
    assert_eq!(type_str(&mut telex(), "ddeof"), "đèo");
}

#[test]
fn tone_pair_placement_modern() {
    // Modern orthography (kiểu mới: oà, uý)
    let mut t = typer_with(Config {
        orthography: Orthography::Modern,
        ..Default::default()
    });
    assert_eq!(type_str(&mut t, "toaf"), "toà");
    t.reset();
    assert_eq!(type_str(&mut t, "uyf"), "uỳ");
}

#[test]
fn uppercase_rendering() {
    assert_eq!(type_str(&mut telex(), "Haf"), "Hà");
    assert_eq!(type_str(&mut telex(), "AA"), "Â");
    assert_eq!(type_str(&mut telex(), "DDi"), "Đi");
}

#[test]
fn session_reset_on_non_letter() {
    // space closes the word; a fresh session starts after it
    assert_eq!(type_str(&mut telex(), "dd af"), "đ à");
    assert_eq!(type_str(&mut telex(), "haf f"), "hà f");
}

// ----------------------------------------------------------------- VNI ---

#[test]
fn vni_marks_and_tones() {
    let mut t = typer_with(Config {
        method: InputMethod::Vni,
        ..Config::default()
    });
    assert_eq!(type_str(&mut t, "to61"), "tố"); // 6=ô, 1=sắc
    t.reset();
    assert_eq!(type_str(&mut t, "toi6"), "tôi"); // 6 marks previous markable vowel
    t.reset();
    assert_eq!(type_str(&mut t, "ma82"), "mằ"); // 8=ă, 2=huyền
    t.reset();
    assert_eq!(type_str(&mut t, "muon5"), "muộn"); // 5 uses pair placement + auto-circ
    t.reset();
    // inapplicable digit restores literally and resets the session
    assert_eq!(type_str(&mut t, "b1"), "b1");
    t.reset();
    // 9 strokes a plain d
    assert_eq!(type_str(&mut t, "d9"), "đ");
}

#[test]
fn vni_strip_tone_with_zero() {
    let mut t = typer_with(Config {
        method: InputMethod::Vni,
        ..Config::default()
    });
    assert_eq!(type_str(&mut t, "ha20"), "ha");
}

// -------------------------------------------- SimpleTelex + Off + macro ---

#[test]
fn simple_telex_behaves_like_telex_p1() {
    let mut t = typer_with(Config {
        method: InputMethod::SimpleTelex,
        ..Config::default()
    });
    assert_eq!(type_str(&mut t, "ddawng"), "đăng");
}

#[test]
fn off_mode_passes_through() {
    let mut t = typer_with(Config {
        method: InputMethod::Off,
        ..Config::default()
    });
    assert_eq!(type_str(&mut t, "ddhsx"), "ddhsx");
}

#[test]
fn macro_expansion() {
    let mut macros = MacroTable::new();
    macros.insert("hvbt", "nhé bạn");
    let mut t = Typer::new(
        Config {
            macro_enabled: true,
            ..Default::default()
        },
        macros,
    );
    assert_eq!(type_str(&mut t, "hvbt."), "nhé bạn.");
}

#[test]
fn macro_abandoned_keeps_letters() {
    let mut macros = MacroTable::new();
    macros.insert("hvbt", "nhé bạn");
    let mut t = Typer::new(
        Config {
            macro_enabled: true,
            ..Default::default()
        },
        macros,
    );
    assert_eq!(type_str(&mut t, "hvbx"), "hvbx");
}

#[test]
fn w_consonant_toggle() {
    // allow_w_consonant = true (default): lone w passes literally
    assert_eq!(type_str(&mut telex(), "w"), "w");
    // false: lone leading w expands to ư
    let mut t = typer_with(Config {
        allow_w_consonant: false,
        ..Default::default()
    });
    assert_eq!(type_str(&mut t, "wf"), "ừ");
}

// ------------------------------------------------- Unikey repeated-key ---

#[test]
fn repeated_tone_key_restores_plain_word() {
    // "bar"+"r" → bar (hỏi lần 1 → bả, lần 2 → khôi phục bar)
    let mut t = telex();
    assert_eq!(type_str(&mut t, "barr"), "bar");
    // sắc tương tự
    let mut t = telex();
    assert_eq!(type_str(&mut t, "bass"), "bas");
}

#[test]
fn repeated_tone_key_marks_tail_restored() {
    // ddienf → điền; f lần 2 (trong cùng chuỗi gõ) → "đien" + chữ f
    let mut t = telex();
    assert_eq!(type_str(&mut t, "ddienff"), "đienf");
}

#[test]
fn repeated_restore_can_be_disabled() {
    let mut t = typer_with(Config {
        repeated_restore: false,
        ..Default::default()
    });
    assert_eq!(type_str(&mut t, "barr"), "bả");
}

#[test]
fn z_removes_last_tone() {
    // "bas" → bá; z lần 1 → bỏ dấu (phát "a"); z lần 2 → phím thường
    let mut t = telex();
    assert_eq!(type_str(&mut t, "baszz"), "baz");

    let mut t = telex();
    // đè huyền bằng nặng rồi z xóa
    let mut out = type_str(&mut t, "bafj");
    assert_eq!(out, "bạ");
    out.pop(); // mô phỏng screen: đè dấu nặng ăn chữ j (không hiển thị)
}

// --------------------------------------------------- auto-capitalize ----

#[test]
fn sentence_start_capitalization() {
    let mut t = typer_with(Config {
        auto_capitalize: true,
        ..Default::default()
    });
    // đầu session coi như bắt đầu câu
    let mut out = String::new();
    for ch in "b".chars() {
        match t.process_char(ch) {
            keyv_core::EngineAction::Pass => out.push(ch),
            keyv_core::EngineAction::Replace { n, chars } => {
                for _ in 0..n {
                    out.pop();
                }
                out.push_str(&chars);
            }
        }
    }
    assert_eq!(out, "B");

    let mut t = typer_with(Config {
        auto_capitalize: true,
        ..Default::default()
    });
    assert_eq!(type_str(&mut t, ". ba"), ". Ba");
    assert_eq!(type_str(&mut t, " nam"), " nam"); // câu không khép lại: vẫn thường

    let mut t = typer_with(Config {
        auto_capitalize: true,
        ..Default::default()
    });
    // phẩy không mở câu mới: chữ 'b' sau đó phải thường
    assert_eq!(type_str(&mut t, "a, b"), "A, b");
}
