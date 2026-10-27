//! Fail-closed readers for the live Cursor CLI terminal. Cursor never writes a
//! pending approval or question to its transcript, and Herdr can report a live
//! question form as `done`, so the screen is the only oracle for "is this pane
//! at an empty prompt, and what is it asking?". Anything unrecognized is
//! `Unknown` and must be handled in Terminal.
use crate::{
    approval_screen::{ApprovalDialog, ApprovalOption, OptionKey, client_limits},
    hooks::Agent,
};

/// Rows examined from the bottom of the viewport. History above is content.
const LIVE_ROWS: usize = 40;
/// Rows Cursor draws below the composer (mode, model footer, cwd, tasks).
const MAX_FOOTER_ROWS: usize = 4;
const PLACEHOLDERS: [&str; 2] = ["Add a follow-up", "Plan, search, build anything"];
pub const CARD_OPTIONS: usize = 4;
/// Options a phone may choose. "Add to allowlist" and "Run Everything" persist
/// permissions or switch the whole session to unrestricted, and their follow-up
/// screens are unverified, so they stay in Terminal.
pub const ONCE: usize = 0;
pub const SKIP: usize = 3;

/// Whether a card row may be chosen from the phone.
pub fn phone_option(index: usize) -> bool {
    matches!(index, ONCE | SKIP)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Screen {
    /// Bottom-anchored composer showing its faint placeholder. `mode` is the
    /// Plan/Ask/Debug label above the footer; `None` is the default Agent mode.
    Idle { mode: Option<String> },
    /// Typed text, a slash-command query, or an unrecognized composer.
    Draft,
    /// A turn is running (`ctrl+c to stop`).
    Busy,
    /// The exact supported shell permission card.
    Approval(Box<ApprovalDialog>),
    /// The "tell the agent what to do instead" input shown after choosing Skip.
    DenyFeedback,
    /// A permission card or other approval this reader does not support.
    UnsupportedCard,
    /// The boxed `AskQuestion` form.
    Question,
    /// A picker or menu (`/model`, parameter editor, slash completions).
    Overlay,
    Unknown,
}

fn rows(screen: &str) -> Vec<&str> {
    let mut rows: Vec<_> = screen.lines().rev().take(400).collect();
    rows.reverse();
    while rows.last().is_some_and(|row| row.trim().is_empty()) {
        rows.pop();
    }
    rows
}

fn bar(row: &str, glyph: char) -> bool {
    let row = row.trim();
    row.chars().count() >= 8 && row.chars().all(|c| c == glyph)
}

fn live(rows: &[&str]) -> usize {
    rows.len().saturating_sub(LIVE_ROWS)
}

fn composer_text(row: &str) -> Option<&str> {
    row.trim_end()
        .strip_prefix("  → ")
        .or_else(|| (row.trim() == "→").then_some(""))
}

/// Composer block anchored at the bottom: top bar, text rows, bottom bar, then
/// at most a few footer rows. Returns (text rows, footer rows).
fn composer<'a>(rows: &[&'a str]) -> Option<(Vec<&'a str>, Vec<&'a str>)> {
    let end = rows.len();
    let top = (live(rows)..end).rev().find(|&i| bar(rows[i], '▄'))?;
    let bottom = (top + 1..end).find(|&i| bar(rows[i], '▀'))?;
    let text = &rows[top + 1..bottom];
    let footer = &rows[bottom + 1..];
    if text.is_empty() || text.len() > 12 || footer.len() > MAX_FOOTER_ROWS {
        return None;
    }
    // Continuation rows of a wrapped draft are indented under the first row.
    if composer_text(text[0]).is_none() || text[1..].iter().any(|row| !row.starts_with("    ")) {
        return None;
    }
    // The box must not be covered by another UI element drawn below it.
    if footer.iter().any(|row| bar(row, '▄') || bar(row, '▀')) {
        return None;
    }
    Some((text.to_vec(), footer.to_vec()))
}

fn mode_label(row: &str) -> Option<Option<String>> {
    let label = row.trim().strip_suffix("(shift+tab to cycle)")?.trim();
    Some((!label.is_empty()).then(|| label.to_owned()))
}

/// Parse the exact shell permission card; see `Screen::Approval`. The card is
/// the last thing on screen (no composer below it) and its command occupies a
/// single row, so nothing visual-wrap can reshape it.
pub fn parse_card(screen: &str) -> Option<(String, ApprovalDialog)> {
    let rows = rows(screen);
    let n = rows.len();
    let question = (live(&rows)..n).rev().find(|&i| rows[i].trim() == "Run this command?")?;
    if question + 2 + CARD_OPTIONS != n || rows[question..].iter().filter(|r| r.trim() == "Run this command?").count() != 1 {
        return None;
    }
    let notice = rows[question + 1].trim();
    // `Shell allowlist is empty`, or `Not in allowlist: a, b` when the user's
    // allow list is non-empty. Any other wording stays in Terminal.
    let missing = match notice.strip_prefix("Not in allowlist: ") {
        Some(names) => Some(prefix_names(names)?),
        None if notice == "Shell allowlist is empty" => None,
        None => return None,
    };
    let rule = (0..question).rev().find(|&i| bar(rows[i], '─'))?;
    let header: Vec<_> = rows[rule + 1..question].iter().filter(|r| !r.trim().is_empty()).collect();
    let [header] = header[..] else { return None };
    let body = header.strip_prefix(" $  ")?.trim_end();
    let (command, cwd) = body.rsplit_once(" in ")?;
    if command.trim().is_empty() || command.trim() != command || cwd.is_empty() || cwd.contains(char::is_whitespace)
        || command.len() > client_limits::COMMAND_BYTES
    {
        return None;
    }
    let mut options = Vec::new();
    let mut selected = None;
    for (index, row) in rows[question + 2..].iter().enumerate() {
        let (label, highlighted) = match (row.strip_prefix("  → "), row.strip_prefix("    ")) {
            (Some(label), _) => (label.trim_end(), true),
            (None, Some(label)) if !label.starts_with(' ') => (label.trim_end(), false),
            _ => return None,
        };
        let valid = match index {
            0 => label == "Run (once) (y)",
            1 => label
                .strip_prefix("Add ")
                .and_then(|rest| rest.strip_suffix(" to allowlist? (tab)"))
                .is_some_and(|items| {
                    !items.is_empty()
                        && items.split(", ").all(|item| {
                            item.strip_prefix("Shell(")
                                .and_then(|item| item.strip_suffix(')'))
                                .is_some_and(|inner| !inner.is_empty() && !inner.contains(['(', ')', ' ']))
                        })
                }),
            2 => label == "Run Everything (shift+tab)",
            _ => label == "Skip & tell the agent what to do instead (esc or n)",
        };
        if !valid || label.len() > client_limits::OPTION_LINE_BYTES {
            return None;
        }
        if highlighted && selected.replace(index).is_some() {
            return None;
        }
        options.push(ApprovalOption {
            number: u32::try_from(index + 1).ok()?,
            label_lines: vec![label.to_owned()],
            key: OptionKey::Navigate(index),
        });
    }
    // The notice and the allow button describe the same commands: compare as
    // sets (the notice is sorted, the button follows command order).
    if let Some(mut missing) = missing {
        let mut offered = prefix_names(
            options[1].label_lines[0].strip_prefix("Add ")?.strip_suffix(" to allowlist? (tab)")?
                .replace("Shell(", "").replace(')', "").as_str(),
        )?;
        missing.sort();
        offered.sort();
        if missing != offered {
            return None;
        }
    }
    let dialog = ApprovalDialog {
        agent: Agent::Cursor,
        title: "Shell command".into(),
        environment: Some(cwd.to_owned()),
        detail: vec![command.to_owned()],
        reason_lines: vec![notice.to_owned()],
        options,
        selected: Some(selected?),
    };
    Some((command.to_owned(), dialog))
}

/// Command names from `a, b, c`; none may be empty or contain spaces or parentheses.
fn prefix_names(text: &str) -> Option<Vec<String>> {
    let names: Vec<String> = text.split(", ").map(str::to_owned).collect();
    names
        .iter()
        .all(|name| !name.is_empty() && !name.contains([' ', '(', ')']))
        .then_some(names)
}

/// `styled` is the same screen read with ANSI attributes. Typed text is
/// drawn plain; only a placeholder is faint, with its first letter under the
/// reverse-video cursor.
fn placeholder_is_faint(styled: &str, text: &str) -> bool {
    let want = format!("→ {text}");
    for line in styled.lines().rev().take(LIVE_ROWS) {
        let mut plain = String::new();
        let mut faint = Vec::new();
        let (mut dim, mut reverse) = (false, false);
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' && chars.peek() == Some(&'[') {
                chars.next();
                let mut params = String::new();
                let mut last = ' ';
                for c in chars.by_ref() {
                    last = c;
                    if c.is_ascii_alphabetic() {
                        break;
                    }
                    params.push(c);
                }
                if last == 'm' {
                    let mut codes = params.split(';').map(|p| p.parse::<u32>().unwrap_or(0));
                    while let Some(code) = codes.next() {
                        match code {
                            0 => (dim, reverse) = (false, false),
                            2 => dim = true,
                            22 => dim = false,
                            7 => reverse = true,
                            27 => reverse = false,
                            38 | 48 => match codes.next() {
                                Some(2) => {
                                    for _ in 0..3 {
                                        codes.next();
                                    }
                                }
                                Some(5) => {
                                    codes.next();
                                }
                                _ => {}
                            },
                            _ => {}
                        }
                    }
                }
            } else if c != '\r' {
                plain.push(c);
                faint.push((dim, reverse));
            }
        }
        let start = match plain.find("→ ") {
            Some(start) => plain[..start].chars().count(),
            None => continue,
        };
        let shown: String = plain.chars().skip(start).collect();
        if shown.trim_end() != want {
            continue;
        }
        // Arrow, space, then the text: the arrow and every letter but the
        // cursor-highlighted first one must be dim, the first letter reverse.
        let cells = &faint[start..start + want.chars().count()];
        return cells[0].0
            && cells[2..]
                .iter()
                .enumerate()
                .all(|(i, (dim, reverse))| if i == 0 { *reverse || *dim } else { *dim && !*reverse });
    }
    false
}

/// Classify the bottom of a visible screen. `styled` is the same read with ANSI.
pub fn classify(screen: &str, styled: &str) -> Screen {
    let rows = rows(screen);
    if rows.is_empty() {
        return Screen::Unknown;
    }
    let bottom = &rows[live(&rows)..];
    let has = |needle: &str| bottom.iter().any(|row| row.contains(needle));
    if let Some((_, dialog)) = parse_card(screen) {
        return Screen::Approval(Box::new(dialog));
    }
    if has("Tell the agent what to do instead") {
        return Screen::DenyFeedback;
    }
    if has("Run this command?") || has("Waiting for approval") || has("Run Everything") {
        return Screen::UnsupportedCard;
    }
    if bottom.iter().any(|row| row.contains("Question ") && row.contains(" of "))
        && (has("Space select") || has("Enter next/submit") || has("Esc to skip"))
    {
        return Screen::Question;
    }
    if has("Type to filter") || has("Edit Parameters") || has("Available models") || has("Models matching") {
        return Screen::Overlay;
    }
    let Some((text, footer)) = composer(&rows) else {
        return Screen::Unknown;
    };
    if text.iter().any(|row| row.contains("ctrl+c to stop")) || footer.iter().any(|row| row.contains("ctrl+c to stop")) {
        return Screen::Busy;
    }
    // A slash command query opens a completion list below the composer, which
    // breaks the bottom anchoring; a typed `/` prefix is still a draft.
    let typed = composer_text(text[0]).unwrap_or("");
    if text.len() == 1 && PLACEHOLDERS.contains(&typed.trim_end()) && placeholder_is_faint(styled, typed.trim_end()) {
        let mode = footer.iter().find_map(|row| mode_label(row)).flatten();
        return Screen::Idle { mode };
    }
    Screen::Draft
}

#[cfg(test)]
mod tests;
