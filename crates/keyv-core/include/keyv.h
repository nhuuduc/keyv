/*
 * KeyV — C ABI for the Rust vi-engine core (crates/keyv-core/src/ffi.rs).
 * Keep this header in sync with ffi.rs signatures.
 */
#ifndef KEYV_H
#define KEYV_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KeyVTyper KeyVTyper;
typedef struct KeyVAction KeyVAction;

enum {
    KEYV_ACTION_PASS = 0,
    KEYV_ACTION_REPLACE = 1,
};

enum {
    KEYV_METHOD_OFF = 0,
    KEYV_METHOD_TELEX = 1,
    KEYV_METHOD_SIMPLE_TELEX = 2,
    KEYV_METHOD_VNI = 3,
};

enum {
    KEYV_ORTHO_TRADITIONAL = 0,
    KEYV_ORTHO_MODERN = 1,
};

/* Lifecycle */
KeyVTyper *keyv_typer_new(int32_t method,
                          int32_t orthography,
                          int32_t macro_enabled,
                          int32_t allow_w_consonant);
void keyv_typer_free(KeyVTyper *typer);
void keyv_typer_reset(KeyVTyper *typer);
void keyv_typer_set_method(KeyVTyper *typer, int32_t method);
void keyv_typer_set_orthography(KeyVTyper *typer, int32_t orthography);
/* Option bits (Unikey/OpenKey-style toggles). */
enum {
    KEYV_OPT_AUTO_CAPITALIZE = 1 << 0,  /* viết hoa chữ cái đầu câu */
    KEYV_OPT_REPEATED_RESTORE = 1 << 1, /* same tone key twice removes it */
};
void keyv_typer_set_options(KeyVTyper *typer, int32_t flags);
/* Returns 0 on success, -1 on error (null args / invalid UTF-8). */
int32_t keyv_typer_set_macro(KeyVTyper *typer, const char *key, const char *value);

/* Per-keystroke: returns a heap-allocated action owned by the caller. */
KeyVAction *keyv_process_char(KeyVTyper *typer, uint32_t codepoint);
void keyv_action_free(KeyVAction *action);

/* Action accessors (borrowed: strings die with keyv_action_free). */
int32_t keyv_action_tag(const KeyVAction *action);
uint8_t keyv_action_backspaces(const KeyVAction *action);
const char *keyv_action_chars(const KeyVAction *action);

#ifdef __cplusplus
}
#endif

#endif /* KEYV_H */
