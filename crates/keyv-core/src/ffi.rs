//! C ABI surface for the Swift host.
//!
//! Ownership rules
//! ===============
//! - `KeyVTyper*` lives until `keyv_typer_free`.
//! - `keyv_process_char` returns a heap-allocated `KeyVAction*` the caller
//!   must release via `keyv_action_free`.
//! - Strings returned by `keyv_action_chars` borrow the action and stay
//!   valid until `keyv_action_free`.
//!
//! Every `unsafe extern "C"` fn below is safe to call with the pointers
//! produced by this module only (see include/keyv.h for the caller contract).

#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString, c_char};
use std::ptr;

use crate::config::{Config, InputMethod, Orthography};
use crate::engine::{EngineAction, Typer};
use crate::macro_::MacroTable;

/// Enum tags for `KeyVAction.tag` / engine method params.
pub const KEYV_ACTION_PASS: i32 = 0;
pub const KEYV_ACTION_REPLACE: i32 = 1;
pub const KEYV_METHOD_OFF: i32 = 0;
pub const KEYV_METHOD_TELEX: i32 = 1;
pub const KEYV_METHOD_SIMPLE_TELEX: i32 = 2;
pub const KEYV_METHOD_VNI: i32 = 3;
pub const KEYV_ORTHO_TRADITIONAL: i32 = 0;
pub const KEYV_ORTHO_MODERN: i32 = 1;

/// Option bits for `keyv_typer_set_options`.
pub const KEYV_OPT_AUTO_CAPITALIZE: i32 = 1 << 0;
pub const KEYV_OPT_REPEATED_RESTORE: i32 = 1 << 1;

/// Opaque engine session (raw pointer across the ABI boundary).
pub struct KeyVTyper {
    typer: Typer,
}

/// Heap-allocated result of one keystroke.
#[repr(C)]
pub struct KeyVAction {
    /// `KEYV_ACTION_PASS` or `KEYV_ACTION_REPLACE`.
    pub tag: i32,
    /// Trailing displayed chars to erase before writing `utf8`.
    pub backspaces: u8,
    utf8: *mut c_char,
}

fn engine_action_to_raw_disown(action: EngineAction) -> *mut KeyVAction {
    match action {
        EngineAction::Pass => Box::into_raw(Box::new(KeyVAction {
            tag: KEYV_ACTION_PASS,
            backspaces: 0,
            utf8: ptr::null_mut(),
        })),
        EngineAction::Replace { n, chars } => {
            let utf8 = CString::new(chars).unwrap_or_default().into_raw();
            Box::into_raw(Box::new(KeyVAction {
                tag: KEYV_ACTION_REPLACE,
                backspaces: n,
                utf8,
            }))
        }
    }
}

fn orthography_from_i32(v: i32) -> Orthography {
    if v == KEYV_ORTHO_MODERN {
        Orthography::Modern
    } else {
        Orthography::Traditional
    }
}

fn method_from_i32(v: i32) -> InputMethod {
    match v {
        KEYV_METHOD_SIMPLE_TELEX => InputMethod::SimpleTelex,
        KEYV_METHOD_VNI => InputMethod::Vni,
        KEYV_METHOD_OFF => InputMethod::Off,
        _ => InputMethod::Telex,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn keyv_typer_new(
    method: i32,
    orthography: i32,
    macro_enabled: i32,
    allow_w_consonant: i32,
) -> *mut KeyVTyper {
    let cfg = Config {
        method: method_from_i32(method),
        orthography: orthography_from_i32(orthography),
        macro_enabled: macro_enabled != 0,
        allow_w_consonant: allow_w_consonant != 0,
        repeated_restore: true,
        auto_capitalize: false,
    };
    Box::into_raw(Box::new(KeyVTyper {
        typer: Typer::new(cfg, MacroTable::new()),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_free(typer: *mut KeyVTyper) {
    if !typer.is_null() {
        drop(unsafe { Box::from_raw(typer) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_reset(typer: *mut KeyVTyper) {
    if let Some(t) = unsafe { typer.as_mut() } {
        t.typer.reset();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_set_method(typer: *mut KeyVTyper, method: i32) {
    if let Some(t) = unsafe { typer.as_mut() } {
        let mut cfg = t.typer.config().clone();
        cfg.method = method_from_i32(method);
        t.typer.set_config(cfg);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_set_orthography(typer: *mut KeyVTyper, orthography: i32) {
    if let Some(t) = unsafe { typer.as_mut() } {
        let mut cfg = t.typer.config().clone();
        cfg.orthography = orthography_from_i32(orthography);
        t.typer.set_config(cfg);
    }
}

/// Hot-swap option bits (KEYV_OPT_*). Mirrors the Unikey/OpenKey toggles.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_set_options(typer: *mut KeyVTyper, flags: i32) {
    if let Some(t) = unsafe { typer.as_mut() } {
        let mut cfg = t.typer.config().clone();
        cfg.auto_capitalize = flags & KEYV_OPT_AUTO_CAPITALIZE != 0;
        cfg.repeated_restore = flags & KEYV_OPT_REPEATED_RESTORE != 0;
        t.typer.set_options_no_reset(cfg);
    }
}

/// Register one macro entry. Returns 0 on success, -1 on error (null args or
/// invalid UTF-8).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_typer_set_macro(
    typer: *mut KeyVTyper,
    key: *const c_char,
    value: *const c_char,
) -> i32 {
    if typer.is_null() || key.is_null() || value.is_null() {
        return -1;
    }
    let key = match unsafe { CStr::from_ptr(key) }.to_str() {
        Ok(key) => key,
        Err(_) => return -1,
    };
    let value = match unsafe { CStr::from_ptr(value) }.to_str() {
        Ok(value) => value,
        Err(_) => return -1,
    };
    let Some(t) = (unsafe { typer.as_mut() }) else {
        return -1;
    };
    t.typer.set_macro(key, value);
    0
}

/// Process one character key (Unicode scalar). Returns a heap-allocated
/// action owned by the caller; free with `keyv_action_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_process_char(
    typer: *mut KeyVTyper,
    codepoint: u32,
) -> *mut KeyVAction {
    let Some(t) = (unsafe { typer.as_mut() }) else {
        return engine_pass_action_raw();
    };
    let ch = match char::from_u32(codepoint) {
        Some(ch) => ch,
        None => return engine_pass_action_raw(),
    };
    engine_action_to_raw_disown(t.typer.process_char(ch))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_action_free(action: *mut KeyVAction) {
    if action.is_null() {
        return;
    }
    let boxed = unsafe { Box::from_raw(action) };
    if !boxed.utf8.is_null() {
        drop(unsafe { CString::from_raw(boxed.utf8) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_action_tag(action: *const KeyVAction) -> i32 {
    let Some(a) = (unsafe { action.as_ref() }) else {
        return KEYV_ACTION_PASS;
    };
    a.tag
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_action_backspaces(action: *const KeyVAction) -> u8 {
    let Some(a) = (unsafe { action.as_ref() }) else {
        return 0;
    };
    a.backspaces
}

/// Borrowed until `keyv_action_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn keyv_action_chars(action: *const KeyVAction) -> *const c_char {
    match unsafe { action.as_ref() } {
        Some(a) => a.utf8 as *const c_char,
        None => ptr::null(),
    }
}

#[inline]
fn engine_pass_action_raw() -> *mut KeyVAction {
    engine_action_to_raw_disown(EngineAction::Pass)
}
