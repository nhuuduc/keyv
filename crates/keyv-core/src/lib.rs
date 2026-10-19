//! KeyV core
//! =========
//! Vietnamese input engine core library (Telex / VNI finite-state machine,
//! macro table, structured word model).
//!
//! Design contract (per project plan):
//! - Pure logic: zero macOS dependencies, no callbacks, no I/O.
//! - One-direction flow: host calls `process_char`, receives
//!   `EngineAction`, and implements the actual event posting.
//!   This keeps typing latency O(func-call) for the UniFFI embedding.
//! - Clean-room: implemented from public Unicode data and the publicly
//!   documented Telex/VNI key conventions; no GPL engine source involved.
//!
//! License: MIT OR Apache-2.0.

pub mod config;
pub mod engine;
pub mod ffi;
pub mod macro_;
pub mod tables;
pub mod telex;
pub mod vni;
pub mod word;

pub use config::{Config, InputMethod, Orthography};
pub use engine::{EngineAction, MAX_WORD_LEN, Typer};
pub use macro_::MacroTable;
pub use tables::Tone;
