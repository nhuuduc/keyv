//! Macro (gõ tắt) table — phrase expansion placeholders keyed by short
//! prefixes. Exact-match only; prefix-probing lets the engine hold back keys
//! while a macro could still fire (macro keys should therefore be
//! distinctive — do not prefix them with common digraphs like `dd`).

use std::collections::HashMap;

#[derive(Clone, Debug, Default)]
pub struct MacroTable {
    entries: HashMap<String, String>,
}

impl MacroTable {
    pub fn new() -> Self {
        Self {
            entries: HashMap::new(),
        }
    }

    /// Insert a macro (key is normalized to lowercase).
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.entries.insert(key.into().to_lowercase(), value.into());
    }

    pub fn exact(&self, key: &str) -> Option<&String> {
        self.entries.get(&key.to_lowercase())
    }

    pub fn has_prefix(&self, prefix: &str) -> bool {
        self.entries.keys().any(|k| k.starts_with(prefix))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}
