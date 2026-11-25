use keyv_core::ffi::{
    KEYV_ACTION_PASS, KEYV_ACTION_REPLACE, KEYV_METHOD_TELEX, KEYV_OPT_AUTO_CAPITALIZE,
    KEYV_OPT_REPEATED_RESTORE, KEYV_OPT_SPELL_CHECK, KEYV_ORTHO_TRADITIONAL,
    keyv_action_backspaces, keyv_action_chars, keyv_action_free, keyv_action_tag,
    keyv_process_backspace, keyv_process_char, keyv_typer_free, keyv_typer_new,
    keyv_typer_set_options,
};
use keyv_core::{Config, EngineAction, InputMethod, MacroTable, Orthography, Typer};
use std::ffi::CStr;

const BS: char = '\u{0008}';

fn replay_with_bs(input: &str, cfg: Config) -> String {
    let mut engine = Typer::new(cfg, MacroTable::new());
    replay_into(&mut engine, input)
}

fn replay_into(engine: &mut Typer, input: &str) -> String {
    let mut screen = String::new();
    for ch in input.chars() {
        if ch == BS {
            engine.backspace();
            screen.pop();
            continue;
        }
        match engine.process_char(ch) {
            EngineAction::Pass => screen.push(ch),
            EngineAction::Replace { n, chars } => {
                assert!(
                    usize::from(n) <= screen.chars().count(),
                    "over-delete n={n} on screen={screen:?} for input={input:?}"
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
fn uow_compound_vowel_all_typing_orders() {
    let cfg = Config::default();
    for (keys, want) in [
        ("dduowngf", "đường"),
        ("dduwowngf", "đường"),
        ("dduongwf", "đường"),
        ("dduongfw", "đường"),
        ("duongwfd", "đường"),
        ("nuowcs", "nước"),
        ("nuocws", "nước"),
        ("nguowif", "người"),
        ("nguoiwf", "người"),
        ("tuowis", "tưới"),
        ("tuoiws", "tưới"),
        ("ruowuj", "rượu"),
        ("ruouwj", "rượu"),
        ("huowu", "hươu"),
        ("huouw", "hươu"),
        ("uowcs", "ước"),
        ("uocws", "ước"),
        ("uowng", "ương"),
        ("muowif", "mười"),
        ("truowngf", "trường"),
        ("chuowng", "chương"),
        ("giuowngf", "giường"),
        ("giuongwf", "giường"),
        ("huow", "huơ"),
        ("huowng", "hương"),
        ("thuowr", "thuở"),
        ("thuowng", "thương"),
        ("thuowcs", "thước"),
        ("quow", "quơ"),
        ("quowr", "quở"),
        ("quows", "quớ"),
        ("DDUOWNGF", "ĐƯỜNG"),
        ("Dduowngf", "Đường"),
        ("Nuowcs", "Nước"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn uow_and_delayed_w_repeated_restore() {
    let cfg = Config::default();
    for (keys, want) in [
        ("dduoww", "đuow"),
        ("dduongww", "đuongw"),
        ("muaww", "muaw"),
        ("choiww", "choiw"),
        ("comww", "comw"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn tone_repositioning_when_syllable_grows() {
    let trad = Config::default();
    for (keys, want) in [
        ("toafn", "toàn"),
        ("hoasn", "hoán"),
        ("hoafng", "hoàng"),
        ("tuyst", "tuýt"),
        ("huychs", "huých"),
        ("gifa", "già"),
        ("qura", "quả"),
        ("taso", "táo"),
        ("hero", "hẻo"),
        ("tiseen", "tiến"),
        ("tieesn", "tiến"),
        ("muojn", "muộn"),
        ("ddiefn", "điền"),
        ("muonjw", "mượn"),
        ("ddienfz", "đien"),
        ("ddienfe", "điền"),
    ] {
        assert_eq!(replay_with_bs(keys, trad.clone()), want, "{keys}");
    }

    let modern = Config {
        orthography: Orthography::Modern,
        ..Config::default()
    };
    for (keys, want) in [
        ("toaf", "toà"),
        ("toafn", "toàn"),
        ("tusy", "tuý"),
        ("tuyst", "tuýt"),
        ("khoer", "khoẻ"),
    ] {
        assert_eq!(replay_with_bs(keys, modern.clone()), want, "{keys}");
    }
}

#[test]
fn triphthongs_and_marked_vowel_tone_targets() {
    let cfg = Config::default();
    for (keys, want) in [
        ("khuyur", "khuỷu"),
        ("ngoaif", "ngoài"),
        ("xoays", "xoáy"),
        ("ngoeof", "ngoèo"),
        ("ngoaof", "ngoào"),
        ("chuyeenr", "chuyển"),
        ("nguyeenx", "nguyễn"),
        ("tuyeejt", "tuyệt"),
        ("tuyeets", "tuyết"),
        ("cuoois", "cuối"),
        ("tuooir", "tuổi"),
        ("khuaays", "khuấy"),
        ("yeeus", "yếu"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn delayed_diacritics_and_english_safety() {
    let cfg = Config::default();
    for (keys, want) in [
        ("dad", "đa"),
        ("dadd", "dad"),
        ("did", "đi"),
        ("didd", "did"),
        ("dand", "đan"),
        ("dandd", "dand"),
        ("dend", "đen"),
        ("dendd", "dend"),
        ("daxd", "đã"),
        ("datsd", "đát"),
        ("datswd", "đắt"),
        ("datasd", "đất"),
        ("lene", "lên"),
        ("lenee", "lene"),
        ("tene", "tên"),
        ("bene", "bên"),
        ("ddene", "đên"),
        ("nene", "nên"),
        ("hene", "hên"),
        ("kene", "kên"),
        ("quene", "quên"),
        ("trene", "trên"),
        ("chene", "chên"),
        ("thene", "thên"),
        ("theme", "thêm"),
        ("ddeme", "đêm"),
        ("neme", "nêm"),
        ("meme", "mêm"),
        ("memee", "meme"),
        ("xepes", "xếp"),
        ("xepse", "xếp"),
        ("hetes", "hết"),
        ("hetse", "hết"),
        ("tetes", "tết"),
        ("metej", "mệt"),
        ("kenhe", "kênh"),
        ("benhej", "bệnh"),
        ("lenhej", "lệnh"),
        ("lense", "lến"),
        ("lenes", "lến"),
        ("dana", "dân"),
        ("nhana", "nhân"),
        ("thana", "thân"),
        ("chana", "chân"),
        ("trana", "trân"),
        ("phana", "phân"),
        ("cana", "cân"),
        ("tana", "tân"),
        ("lana", "lân"),
        ("mana", "mân"),
        ("quana", "quân"),
        ("tama", "tâm"),
        ("lama", "lâm"),
        ("nama", "nâm"),
        ("mama", "mâm"),
        ("mamaa", "mama"),
        ("nana", "nân"),
        ("nanaa", "nana"),
        ("tapaj", "tập"),
        ("capas", "cấp"),
        ("lapaj", "lập"),
        ("matas", "mất"),
        ("masta", "mất"),
        ("matsa", "mất"),
        ("ddatas", "đất"),
        ("tatas", "tất"),
        ("bataj", "bật"),
        ("nhatas", "nhất"),
        ("thataj", "thật"),
        ("chatas", "chất"),
        ("bacaj", "bậc"),
        ("canaf", "cần"),
        ("lanaf", "lần"),
        ("phanaf", "phần"),
        ("cono", "côn"),
        ("tono", "tôn"),
        ("bono", "bôn"),
        ("hono", "hôn"),
        ("mono", "môn"),
        ("monoo", "mono"),
        ("lono", "lôn"),
        ("chono", "chôn"),
        ("trono", "trôn"),
        ("thono", "thôn"),
        ("khono", "khôn"),
        ("nhono", "nhôn"),
        ("tomo", "tôm"),
        ("homo", "hôm"),
        ("nhomo", "nhôm"),
        ("hopoj", "hộp"),
        ("lopos", "lốp"),
        ("nopoj", "nộp"),
        ("totos", "tốt"),
        ("motoj", "một"),
        ("cotoj", "cột"),
        ("hocos", "hốc"),
        ("gocos", "gốc"),
        ("locoj", "lộc"),
        ("tocos", "tốc"),
        ("ddocoj", "độc"),
        ("cocos", "cốc"),
        ("data", "dât"),
        ("dataa", "data"),
        ("photo", "phôt"),
        ("photoo", "photo"),
        ("papa", "pâp"),
        ("papaa", "papa"),
        ("tiene", "tiên"),
        ("tienee", "tiene"),
        ("tiengse", "tiếng"),
        ("tienges", "tiếng"),
        ("muono", "muôn"),
        ("muonoo", "muono"),
        ("khongo", "không"),
        ("khongoo", "khongo"),
        ("tuoio", "tuôi"),
        ("tuoior", "tuổi"),
        ("tuoiro", "tuổi"),
        ("buoior", "buổi"),
        ("chuyene", "chuyên"),
        ("chuyener", "chuyển"),
        ("chuyenre", "chuyển"),
        ("khuaya", "khuây"),
        ("yeue", "yêu"),
        ("tieue", "tiêu"),
        ("tansa", "tấn"),
        ("ddamfa", "đầm"),
        ("datsa", "dất"),
        ("duongwf", "dường"),
        ("duongfw", "dường"),
        ("namw", "năm"),
        ("muaw", "mưa"),
        ("cuawr", "cửa"),
        ("guiwr", "gửi"),
        ("nguiwr", "ngửi"),
        ("cuuws", "cứu"),
        ("luuw", "lưu"),
        ("choiw", "chơi"),
        ("moiw", "mơi"),
        ("comw", "cơm"),
        ("honw", "hơn"),
        ("nhungwx", "những"),
        ("ddungwf", "đừng"),
        ("thucws", "thức"),
        ("manw", "măn"),
        ("hoacwj", "hoặc"),
        ("xoanws", "xoắn"),
        ("maaw", "mă"),
        ("mawa", "mâ"),
        ("manaw", "măn"),
        ("manwa", "mân"),
        ("moow", "mơ"),
        ("mowo", "mô"),
        ("monow", "mơn"),
        ("monwo", "môn"),
        ("todo", "todo"),
        ("haha", "haha"),
        ("mode", "mode"),
        ("code", "code"),
        ("node", "node"),
        ("note", "note"),
        ("home", "home"),
        ("done", "done"),
        ("time", "time"),
        ("name", "name"),
        ("make", "make"),
        ("take", "take"),
        ("file", "file"),
        ("line", "line"),
        ("type", "type"),
        ("page", "page"),
        ("queue", "queue"),
        ("logo", "logo"),
        ("solo", "solo"),
        ("delete", "delete"),
        ("level", "level"),
        ("panda", "panda"),
        ("java", "java"),
        ("auto", "auto"),
        ("into", "into"),
        ("onto", "onto"),
        ("view", "view"),
        ("new", "new"),
        ("dead", "dead"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn gi_and_qu_clusters() {
    let trad = Config::default();
    for (keys, want) in [
        ("gif", "gì"),
        ("ginf", "gìn"),
        ("gir", "gỉ"),
        ("gis", "gí"),
        ("giaf", "già"),
        ("gias", "giá"),
        ("giaos", "giáo"),
        ("giauf", "giàu"),
        ("giayf", "giày"),
        ("giaays", "giấy"),
        ("gieengs", "giếng"),
        ("gieets", "giết"),
        ("gioir", "giỏi"),
        ("giow", "giơ"),
        ("giowf", "giờ"),
        ("giowis", "giới"),
        ("giuwx", "giữ"),
        ("giuwax", "giữa"),
        ("giuawx", "giữa"),
        ("giups", "giúp"),
        ("nghiax", "nghĩa"),
        ("nghieeng", "nghiêng"),
        ("quar", "quả"),
        ("quas", "quá"),
        ("quoocs", "quốc"),
        ("quys", "quý"),
        ("quyr", "quỷ"),
        ("quynhf", "quỳnh"),
        ("quyeenf", "quyền"),
        ("quaayr", "quẩy"),
        ("quawnf", "quằn"),
        ("thuyr", "thủy"),
    ] {
        assert_eq!(replay_with_bs(keys, trad.clone()), want, "{keys}");
    }
}

#[test]
fn classic_telex_consonant_w_shorthand_vs_simple_telex() {
    let telex_shorthand = Config {
        method: InputMethod::Telex,
        allow_w_consonant: false,
        ..Config::default()
    };
    for (keys, want) in [
        ("nhw", "như"),
        ("thws", "thứ"),
        ("ddwngf", "đừng"),
        ("twj", "tự"),
    ] {
        assert_eq!(
            replay_with_bs(keys, telex_shorthand.clone()),
            want,
            "{keys}"
        );
    }

    let simple = Config {
        method: InputMethod::SimpleTelex,
        allow_w_consonant: false,
        ..Config::default()
    };
    for (keys, want) in [
        ("w", "w"),
        ("win", "win"),
        ("tw", "tw"),
        ("duowngf", "dường"),
    ] {
        assert_eq!(replay_with_bs(keys, simple.clone()), want, "{keys}");
    }
}

#[test]
fn spell_check_restores_english_words_and_keeps_vietnamese_paragraphs() {
    let cfg = Config {
        spell_check: true,
        repeated_restore: true,
        allow_w_consonant: true,
        ..Config::default()
    };

    for word in [
        "terminal", "server", "service", "version", "person", "market", "target", "folder",
        "docker", "github", "macos", "xcode", "chrome", "safari", "firefox", "electron", "unikey",
        "unicode", "Windows", "water", "world", "work", "word", "with", "string", "strings",
        "struct", "browser", "claude", "clear", "class", "click", "project", "process", "script",
        "points", "trains", "build", "camera", "zero", "where", "todo", "haha", "daddy", "dandy",
        "banana", "canada", "cocoa", "mode", "code", "node", "note", "home", "done", "time",
        "name", "make", "take", "file", "line", "type", "page", "base", "case", "queue", "gene",
        "data ", "data.", "data,", "photo ", "photo.", "papa ", "piece ", "niece ", "died ",
        "dude ",
    ] {
        assert_eq!(replay_with_bs(word, cfg.clone()), word, "{word}");
    }

    for (keys, want) in [
        ("lene", "lên"),
        ("lene ", "lên "),
        ("lenee", "lene"),
        ("tene", "tên"),
        ("tene ", "tên "),
        ("nhana", "nhân"),
        ("nhana ", "nhân "),
        ("dana", "dân"),
        ("cono", "côn"),
        ("mono", "môn"),
        ("mono ", "môn "),
        ("monoo", "mono"),
        ("hono", "hôn"),
        ("mama", "mâm"),
        ("mama ", "mâm "),
        ("mamaa", "mama"),
        ("meme", "mêm"),
        ("memee", "meme"),
        ("ddeme", "đêm"),
        ("theme", "thêm"),
        ("theme ", "thêm "),
        ("totos", "tốt"),
        ("motoj", "một"),
        ("matas", "mất"),
        ("ddatas", "đất"),
        ("nhatas", "nhất"),
        ("dand", "đan"),
        ("dand ", "đan "),
        ("dandd", "dand"),
        ("dend", "đen"),
        ("dad", "đa"),
        ("dadd", "dad"),
        ("did", "đi"),
        ("khongo", "không"),
        ("tiengse", "tiếng"),
        ("tienges", "tiếng"),
        ("tiene", "tiên"),
        ("muono", "muôn"),
        ("tuoior", "tuổi"),
        ("tuoiro", "tuổi"),
        ("chuyener", "chuyển"),
        ("chuyenre", "chuyển"),
        ("khuaya", "khuây"),
        ("yeue", "yêu"),
        ("tieue", "tiêu"),
        ("buoior", "buổi"),
        ("duongwfd", "đường"),
        ("dienfd", "điền"),
        ("dangd", "đang"),
        ("muaw", "mưa"),
        ("choiw", "chơi"),
        ("comw", "cơm"),
        ("nhungwx", "những"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }

    let sentence =
        "Coongj hoaf xax hooij chur nghiax Vieetj Nam - DDoocj laapj Tuwj do Hanhj phucs";
    let expected = "Cộng hòa xã hội chủ nghĩa Việt Nam - Độc lập Tự do Hạnh phúc";
    assert_eq!(replay_with_bs(sentence, cfg.clone()), expected);

    let mixed = "Minhf ddang code Swift vaf terminal treen macos voiws github";
    assert_eq!(
        replay_with_bs(mixed, cfg),
        "Mình đang code Swift và terminal trên macos với github"
    );
}

#[test]
fn backspace_preserves_live_syllable_composition() {
    let cfg = Config::default();
    let seq1 = format!("tieenh{BS}gs");
    assert_eq!(replay_with_bs(&seq1, cfg.clone()), "tiếng");

    let seq2 = format!("ds{BS}d");
    assert_eq!(replay_with_bs(&seq2, cfg.clone()), "đ");

    let seq3 = format!("hoi{BS}o");
    assert_eq!(replay_with_bs(&seq3, cfg.clone()), "hô");

    let seq4 = format!("dduowm{BS}ngf");
    assert_eq!(replay_with_bs(&seq4, cfg.clone()), "đường");

    let seq5 = format!("toafn{BS}ngs");
    assert_eq!(replay_with_bs(&seq5, cfg), "toáng");
}

#[test]
fn vni_delayed_stroke_compound_horn_and_repeats() {
    let cfg = Config {
        method: InputMethod::Vni,
        ..Config::default()
    };
    for (keys, want) in [
        ("duong972", "đường"),
        ("d9uong27", "đường"),
        ("d9uo7ng2", "đường"),
        ("nuoc71", "nước"),
        ("nguoi72", "người"),
        ("ruou75", "rượu"),
        ("huou7", "hươu"),
        ("thuo73", "thuở"),
        ("thuong7", "thương"),
        ("quo73", "quở"),
        ("to16", "tố"),
        ("muon50", "muon"),
        ("dang9", "đang"),
        ("dang99", "dang9"),
        ("d99", "d9"),
        ("a66", "a6"),
        ("u77", "u7"),
        ("a88", "a8"),
    ] {
        assert_eq!(replay_with_bs(keys, cfg.clone()), want, "{keys}");
    }
}

#[test]
fn macros_coexist_with_telex_and_respect_word_boundaries() {
    let mut macros = MacroTable::new();
    macros.insert("ddk", "đăng ký");
    macros.insert("vn", "Việt Nam");
    let mut typer = Typer::new(
        Config {
            macro_enabled: true,
            ..Config::default()
        },
        macros,
    );

    assert_eq!(replay_into(&mut typer, "ddawng "), "đăng ");
    assert_eq!(replay_into(&mut typer, "ddk "), "đăng ký ");
    assert_eq!(replay_into(&mut typer, "DDK "), "ĐĂNG KÝ ");
    assert_eq!(replay_into(&mut typer, "avn"), "avn");
}

#[test]
fn ffi_backspace_and_spellcheck_roundtrip() {
    unsafe {
        let typer = keyv_typer_new(KEYV_METHOD_TELEX, KEYV_ORTHO_TRADITIONAL, 0, 1);
        assert!(!typer.is_null());
        keyv_typer_set_options(
            typer,
            KEYV_OPT_REPEATED_RESTORE | KEYV_OPT_SPELL_CHECK | KEYV_OPT_AUTO_CAPITALIZE,
        );

        let mut screen = String::new();
        for ch in "terminal tieem\u{0008}ngs dock\u{0008}s".chars() {
            if ch == BS {
                keyv_process_backspace(typer);
                screen.pop();
                continue;
            }
            let act = keyv_process_char(typer, ch as u32);
            if act.is_null() {
                assert_eq!(keyv_action_tag(act), KEYV_ACTION_PASS);
                screen.push(ch);
            } else {
                assert_eq!(keyv_action_tag(act), KEYV_ACTION_REPLACE);
                let bs = keyv_action_backspaces(act);
                for _ in 0..bs {
                    screen.pop();
                }
                let ptr = keyv_action_chars(act);
                if !ptr.is_null() {
                    screen.push_str(CStr::from_ptr(ptr).to_str().unwrap());
                }
                keyv_action_free(act);
            }
        }
        assert_eq!(screen, "Terminal tiếng dóc");
        keyv_typer_free(typer);
    }
}
