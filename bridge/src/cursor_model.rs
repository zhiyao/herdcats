//! Readers for Cursor's `/model` picker, its parameter editor and the idle
//! footer. Cursor's flat `--list-models` ids do not match what `/model <id>`
//! accepts (a typed id is a fuzzy filter that may select a neighbour), so the
//! picker's own rows are the catalog and a model is chosen by moving to the row
//! whose label matches exactly. Everything here is pure and fail-closed.
use std::collections::HashSet;

/// The only CLI build whose screens were verified. The running session's own
/// version must equal it.
pub const TESTED_VERSION: &str = "2026.10.22-27dcf5f";
/// Rows the picker is allowed to report; more is an unrecognized layout.
pub const MAX_MODELS: usize = 96;
/// Width of the label column; parameters start one space after it.
const LABEL_WIDTH: usize = 24;

pub const EFFORTS: [(&str, &str); 8] = [
    ("none", "None"),
    ("minimal", "Minimal"),
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra High"),
    ("max", "Max"),
    ("ultra", "Ultra"),
];

pub fn effort_id(label: &str) -> Option<&'static str> {
    EFFORTS.iter().find(|(_, l)| *l == label).map(|(id, _)| *id)
}
pub fn effort_label(id: &str) -> Option<&'static str> {
    EFFORTS.iter().find(|(i, _)| *i == id).map(|(_, l)| *l)
}

/// `Claude Opus 5.5` -> `claude-opus-5-5`. Ids are derived from the picker
/// label only so they are safe to log and compare; they are never typed into
/// the terminal.
pub fn slug(label: &str) -> String {
    let mut out = String::new();
    for c in label.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_owned()
}

/// Version of the running `cursor-agent` from its foreground processes' command
/// lines (`.../cursor-agent/versions/<version>/index.js`). `Err` when none or
/// more than one distinct version is present: the binary on disk can be
/// replaced by an update while an older session keeps running.
pub fn session_version<'a>(command_lines: impl IntoIterator<Item = &'a str>) -> Result<String, &'static str> {
    let mut found: Vec<String> = Vec::new();
    for line in command_lines {
        let mut rest = line;
        while let Some(at) = rest.find("/cursor-agent/versions/") {
            let after = &rest[at + "/cursor-agent/versions/".len()..];
            let version = after.split('/').next().unwrap_or("");
            if valid_version(version) && !found.iter().any(|v| v == version) {
                found.push(version.to_owned());
            }
            rest = after;
        }
    }
    match found.as_slice() {
        [version] => Ok(version.clone()),
        _ => Err("cursor_version_unverified"),
    }
}

fn valid_version(version: &str) -> bool {
    let Some((date, build)) = version.split_once('-') else { return false };
    let parts: Vec<_> = date.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|p| !p.is_empty() && p.len() <= 4 && p.bytes().all(|b| b.is_ascii_digit()))
        && build.len() == 7
        && build.bytes().all(|b| b.is_ascii_hexdigit())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PickerRow {
    pub label: String,
    /// Parameter summary shown beside the label (`300K Medium`, `High`, ...).
    pub params: String,
    pub selected: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picker {
    /// Text typed into the filter, empty when none.
    pub filter: String,
    pub rows: Vec<PickerRow>,
    /// (first, last, total) of the visible window; `None` when not shown.
    pub window: Option<(usize, usize, usize)>,
    pub no_matches: bool,
}

impl Picker {
    pub fn cursor_label(&self) -> Option<&str> {
        let mut selected = self.rows.iter().filter(|r| r.selected);
        match (selected.next(), selected.next()) {
            (Some(row), None) => Some(row.label.as_str()),
            _ => None,
        }
    }
    /// Zero-based position of the cursor in the whole list, from the window.
    pub fn cursor_index(&self) -> Option<usize> {
        let (first, _, _) = self.window?;
        let offset = self.rows.iter().position(|r| r.selected)?;
        Some(first.checked_sub(1)? + offset)
    }
}

fn rows_of(screen: &str) -> Vec<&str> {
    let mut rows: Vec<_> = screen.lines().rev().take(120).collect();
    rows.reverse();
    rows
}

fn window(row: &str) -> Option<(usize, usize, usize)> {
    let (range, total) = row.trim().split_once(" of ")?;
    let (first, last) = range.split_once('-')?;
    Some((first.parse().ok()?, last.parse().ok()?, total.parse().ok()?))
}

/// Parse the picker drawn below the composer. `None` for any other screen.
pub fn parse_picker(screen: &str) -> Option<Picker> {
    let rows = rows_of(screen);
    let title = rows
        .iter()
        .rposition(|r| r.starts_with(" Available models") || r.starts_with(" Models matching"))?;
    let no_matches = rows[title..].iter().take(3).any(|r| r.contains("(no matches)"));
    let filter_at = (title + 1..rows.len()).find(|&i| rows[i].starts_with(" Filter:"))?;
    if filter_at > title + 3 {
        return None;
    }
    let filter = rows[filter_at].trim_start().strip_prefix("Filter:")?.trim().to_owned();
    let mut picker = Picker { filter, rows: Vec::new(), window: None, no_matches };
    let mut end = rows.len();
    for (i, row) in rows.iter().enumerate().skip(filter_at + 1) {
        if let Some(found) = window(row) {
            picker.window = Some(found);
            end = i;
            break;
        }
        // No window line is drawn when nothing matches.
        if row.trim_start().starts_with("Type to filter") {
            end = i;
            break;
        }
    }
    for row in &rows[filter_at + 1..end] {
        if row.trim().is_empty() {
            continue;
        }
        let (selected, body) = match (row.strip_prefix(" →  "), row.strip_prefix("    ")) {
            (Some(body), _) => (true, body),
            (None, Some(body)) if !body.starts_with(' ') => (false, body),
            _ => return None,
        };
        let body = body.trim_end();
        let body = body.strip_suffix(" (Tab to modify)").unwrap_or(body);
        let chars: Vec<char> = body.chars().collect();
        let (label, params) = if chars.len() <= LABEL_WIDTH {
            (body.trim_end().to_owned(), String::new())
        } else {
            // Parameters start one space after the fixed-width label column.
            if chars[LABEL_WIDTH] != ' ' {
                return None;
            }
            let label: String = chars[..LABEL_WIDTH].iter().collect();
            let params: String = chars[LABEL_WIDTH + 1..].iter().collect();
            (label.trim_end().to_owned(), params.trim().to_owned())
        };
        if label.is_empty() || picker.rows.len() >= MAX_MODELS {
            return None;
        }
        picker.rows.push(PickerRow { label, params, selected });
    }
    if picker.rows.is_empty() && !no_matches || picker.rows.iter().filter(|r| r.selected).count() > 1 {
        return None;
    }
    if let Some((first, last, total)) = picker.window
        && (first == 0 || last < first || last > total || last - first + 1 != picker.rows.len() || total > MAX_MODELS)
    {
        return None;
    }
    Some(picker)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ItemKind {
    /// One choice of a group; `true` for the selected one.
    Radio(bool),
    Check(bool),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorItem {
    pub group: Option<String>,
    pub text: String,
    pub kind: ItemKind,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Editor {
    pub label: String,
    pub items: Vec<EditorItem>,
    pub cursor: usize,
}

impl Editor {
    /// Items of the effort group: `Effort` (Claude, Grok) or `Reasoning` (GPT, Kimi).
    pub fn effort_items(&self) -> Vec<(usize, &EditorItem)> {
        self.items
            .iter()
            .enumerate()
            .filter(|(_, item)| matches!(item.group.as_deref(), Some("Effort" | "Reasoning")) && matches!(item.kind, ItemKind::Radio(_)))
            .collect()
    }
    pub fn efforts(&self) -> Option<Vec<(&'static str, &'static str)>> {
        let items = self.effort_items();
        let mut seen = HashSet::new();
        items
            .iter()
            .map(|(_, item)| {
                let id = effort_id(&item.text)?;
                seen.insert(id).then(|| (id, effort_label(id).unwrap_or("")))
            })
            .collect::<Option<Vec<_>>>()
            .filter(|efforts| !efforts.is_empty())
    }
    pub fn current_effort(&self) -> Option<&'static str> {
        let selected: Vec<_> = self
            .effort_items()
            .into_iter()
            .filter(|(_, item)| item.kind == ItemKind::Radio(true))
            .collect();
        match selected[..] {
            [(_, item)] => effort_id(&item.text),
            _ => None,
        }
    }
}

/// Parse the parameter editor (`<label> — Edit Parameters`).
pub fn parse_editor(screen: &str) -> Option<Editor> {
    let rows = rows_of(screen);
    let title = rows.iter().rposition(|r| r.contains(" — Edit Parameters"))?;
    let label = rows[title].trim_start().split(" — Edit Parameters").next()?.trim().to_owned();
    if label.is_empty() {
        return None;
    }
    let mut items = Vec::new();
    let mut cursor = None;
    let mut group: Option<String> = None;
    let mut closed = false;
    for row in &rows[title + 1..] {
        if row.trim().is_empty() {
            continue;
        }
        if row.trim_start().starts_with("↑/↓ to navigate") {
            closed = true;
            break;
        }
        let (selected, body) = match (row.strip_prefix("  → "), row.strip_prefix("    ")) {
            (Some(body), _) => (true, Some(body)),
            (None, Some(body)) if !body.starts_with(' ') => (false, Some(body)),
            _ => (false, None),
        };
        let item = body.and_then(|body| {
            let mut chars = body.chars();
            let glyph = chars.next()?;
            let text = chars.as_str().strip_prefix(' ')?.trim_end();
            let kind = match glyph {
                '●' => ItemKind::Radio(true),
                '○' => ItemKind::Radio(false),
                '◉' => ItemKind::Check(true),
                '◯' => ItemKind::Check(false),
                _ => return None,
            };
            let text = text.strip_suffix(" ✓").unwrap_or(text).trim();
            // Toggles (Thinking, Fast) stand apart from the radio groups above them.
            let item_group = if matches!(kind, ItemKind::Check(_)) { None } else { group.clone() };
            (!text.is_empty()).then(|| EditorItem { group: item_group, text: text.to_owned(), kind })
        });
        match item {
            Some(item) => {
                if selected && cursor.replace(items.len()).is_some() {
                    return None;
                }
                items.push(item);
            }
            None if row.starts_with("  ") && !row.starts_with("   ") && !selected => {
                group = Some(row.trim().to_owned());
            }
            None => return None,
        }
        if items.len() > 32 {
            return None;
        }
    }
    if !closed || items.is_empty() {
        return None;
    }
    // A group's radios must be consistent: at most one selected.
    let mut by_group: Vec<(Option<&str>, usize)> = Vec::new();
    for item in &items {
        if item.kind == ItemKind::Radio(true) {
            match by_group.iter_mut().find(|(g, _)| *g == item.group.as_deref()) {
                Some(entry) => entry.1 += 1,
                None => by_group.push((item.group.as_deref(), 1)),
            }
        }
    }
    if by_group.iter().any(|(_, count)| *count > 1) {
        return None;
    }
    Some(Editor { label, items, cursor: cursor? })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Footer {
    pub label: String,
    /// Effort id when the footer names exactly one; `None` otherwise.
    pub effort: Option<&'static str>,
}

fn param_token(token: &str) -> bool {
    let context = token.len() >= 2
        && (token.ends_with('K') || token.ends_with('M'))
        && token[..token.len() - 1].bytes().all(|b| b.is_ascii_digit() || b == b'.');
    context || matches!(token, "Fast" | "Thinking" | "No" | "Extra" | "·" | "MAX") || effort_id(token).is_some()
}

/// The model segment of the idle footer, matched against known labels. The
/// longest label that the footer starts with (followed by a space or the end)
/// wins, so `Claude Opus 5.5 ...` is never taken for `Claude Opus 5`. Extra
/// text from a custom statusline after the parameters is ignored; two
/// different efforts in the footer make the effort unknown.
pub fn parse_footer(text: &str, labels: &[String]) -> Option<Footer> {
    let text = text.trim();
    let label = labels
        .iter()
        .filter(|label| {
            text.strip_prefix(label.as_str())
                .is_some_and(|rest| rest.is_empty() || rest.starts_with(' '))
        })
        .max_by_key(|label| label.len())?;
    let rest = text[label.len()..].split_whitespace().collect::<Vec<_>>();
    let mut efforts: Vec<&'static str> = Vec::new();
    let mut i = 0;
    while i < rest.len() && param_token(rest[i]) {
        if rest[i] == "Extra" && rest.get(i + 1) == Some(&"High") {
            efforts.push("xhigh");
            i += 2;
            continue;
        }
        if rest[i] == "·" {
            break;
        }
        if let Some(id) = effort_id(rest[i]) {
            efforts.push(id);
        }
        i += 1;
    }
    efforts.dedup();
    Some(Footer { label: label.clone(), effort: if efforts.len() == 1 { Some(efforts[0]) } else { None } })
}

/// The footer line under the composer of an idle screen: the first footer row
/// that is not the mode line. Custom statuslines may print anything here.
pub fn footer_text(screen: &str) -> Option<String> {
    let rows = rows_of(screen);
    let bottom = rows.iter().rposition(|r| {
        let r = r.trim();
        r.chars().count() >= 8 && r.chars().all(|c| c == '▀')
    })?;
    rows[bottom + 1..]
        .iter()
        .map(|r| r.trim())
        .find(|r| !r.is_empty() && !r.ends_with("(shift+tab to cycle)") && !r.ends_with(" task") && !r.ends_with(" tasks"))
        .map(str::to_owned)
}

#[cfg(test)]
mod tests;
