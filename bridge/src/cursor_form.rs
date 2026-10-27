//! Cursor's boxed `AskQuestion` form, read from the screen. Cursor writes the
//! call to its transcript only after the form is answered, so the screen is
//! the only source for what is being asked. The form shows one question at a
//! time ("Question 2 of 3"); each visible question becomes its own pending
//! request, and the next one arrives as a new request after Enter.
use crate::{
    question_match::{PendingQuestion, Question, QuestionKind, QuestionOption, client_limits},
    question_screen::{FreeText, QuestionCursor, QuestionScreen, QuestionStep, ScreenOption},
};

/// Rows examined from the bottom: a form with 32 options still fits.
const LIVE_ROWS: usize = 120;
const HINT: &str = "↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to skip";
const OTHER_PLACEHOLDER: &str = "(type to answer)";
const MAX_FORMS: usize = client_limits::QUESTIONS;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub label: String,
    pub checked: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Form {
    pub title: String,
    /// Zero-based position of the visible question.
    pub index: usize,
    pub total: usize,
    pub prompt: String,
    pub multi: bool,
    /// The question's own options, without the trailing "Other" row.
    pub options: Vec<Row>,
    /// The write-in row: its checkbox and typed text (empty while untouched).
    pub other_checked: bool,
    pub other_text: String,
    /// One-based row under the `›` cursor; the Other row is `options.len() + 1`.
    pub cursor: u32,
    pub fingerprint: Vec<u8>,
}

fn fingerprint(rows: &[&str]) -> Vec<u8> {
    let mut bytes = Vec::new();
    for row in rows {
        bytes.extend_from_slice(&(row.len() as u64).to_le_bytes());
        bytes.extend_from_slice(row.as_bytes());
    }
    bytes
}

fn compact(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace()).collect()
}

/// Inner text of one box row, with the border and one pad space removed.
fn inner(row: &str) -> Option<&str> {
    let row = row.trim_end();
    let body = row.strip_prefix(" │")?.strip_suffix('│')?;
    Some(body.strip_prefix(' ').unwrap_or(body).trim_end())
}

fn border(row: &str, left: char, right: char) -> bool {
    let row = row.trim();
    let mut chars = row.chars();
    chars.next() == Some(left)
        && row.ends_with(right)
        && row.chars().count() >= 8
        && chars.as_str().trim_end_matches(right).chars().all(|c| c == '─')
}

/// Parse the form at the bottom of the screen. The box must be the last thing
/// drawn; text quoted in conversation history above a live composer is not a
/// form. Anything unrecognized returns `None` and stays in Terminal.
pub fn parse_form(screen: &str) -> Option<Form> {
    let mut rows: Vec<&str> = screen.lines().rev().take(400).collect();
    rows.reverse();
    while rows.last().is_some_and(|row| row.trim().is_empty()) {
        rows.pop();
    }
    let end = rows.len().checked_sub(1)?;
    if !border(rows[end], '└', '┘') {
        return None;
    }
    let start = (end.saturating_sub(LIVE_ROWS)..end).rev().find(|&i| border(rows[i], '┌', '┐'))?;
    let body: Vec<&str> = rows[start + 1..end].iter().map(|row| inner(row)).collect::<Option<_>>()?;
    let mut it = body.iter().copied().enumerate().peekable();

    let (_, title) = it.next()?;
    if title.is_empty() || title.len() > client_limits::HEADER || !it.next()?.1.is_empty() {
        return None;
    }
    let position = it.next()?.1.strip_prefix("Question ")?;
    let (number, total) = position.split_once(" of ")?;
    let (number, total) = (number.parse::<usize>().ok()?, total.parse::<usize>().ok()?);
    if number == 0 || number > total || total > MAX_FORMS || !it.next()?.1.is_empty() {
        return None;
    }
    // Prompt rows: "N. text" then wrapped continuation rows, up to a blank row.
    let first = it.next()?.1.strip_prefix(&format!("{number}. "))?;
    let mut prompt = vec![first];
    while let Some(&(_, row)) = it.peek() {
        if row.is_empty() {
            break;
        }
        prompt.push(row);
        it.next();
        if prompt.len() > 40 {
            return None;
        }
    }
    let mut prompt = prompt.join(" ");
    let multi = prompt.ends_with(" (multi-select)");
    if multi {
        prompt.truncate(prompt.len() - " (multi-select)".len());
    }
    if prompt.trim().is_empty() || prompt.len() > client_limits::TEXT || !it.next()?.1.is_empty() {
        return None;
    }

    // Option rows until the blank row before the hint.
    struct Raw {
        label: Vec<String>,
        checked: bool,
        cursor: bool,
    }
    let mut raw: Vec<Raw> = Vec::new();
    while let Some(&(_, row)) = it.peek() {
        if row.is_empty() {
            break;
        }
        it.next();
        let (cursor, rest) = match (row.strip_prefix("  › "), row.strip_prefix("    ")) {
            (Some(rest), _) => (true, rest),
            (None, Some(rest)) if rest.starts_with('[') => (false, rest),
            // Wrapped label continuation, aligned under the label.
            (None, Some(rest)) if rest.starts_with("    ") => {
                let last = raw.last_mut()?;
                last.label.push(rest.trim().to_owned());
                if last.label.len() > 8 {
                    return None;
                }
                continue;
            }
            _ => return None,
        };
        let (checked, label) = if let Some(label) = rest.strip_prefix("[ ] ") {
            (false, label)
        } else {
            (true, rest.strip_prefix("[x] ")?)
        };
        raw.push(Raw { label: vec![label.trim().to_owned()], checked, cursor });
        if raw.len() > client_limits::OPTIONS + 1 {
            return None;
        }
    }
    if raw.len() < 2 || !it.next()?.1.is_empty() {
        return None;
    }
    // The hint may wrap anywhere; compare without whitespace.
    let hint: String = it.by_ref().map(|(_, row)| row).collect::<Vec<_>>().join(" ");
    if compact(&hint) != compact(HINT) {
        return None;
    }
    let cursors: Vec<usize> = raw.iter().enumerate().filter(|(_, r)| r.cursor).map(|(i, _)| i).collect();
    let [cursor] = cursors[..] else { return None };
    let other = raw.pop()?;
    let other_label = other.label.join(" ");
    let other_text = other_label.strip_prefix("Other: ")?;
    let other_text = if other_text == OTHER_PLACEHOLDER { "" } else { other_text }.to_owned();
    // Single-select is a radio: more than one checked row is not a form we know.
    let checked_rows = raw.iter().filter(|r| r.checked).count() + usize::from(other.checked);
    if (!multi && checked_rows > 1) || raw.iter().any(|r| r.label.join(" ").is_empty() || r.label.join(" ").len() > client_limits::LABEL) {
        return None;
    }
    // An unchecked Other row never shows placeholder-only checks; a checked
    // one must carry the typed text.
    if other.checked && other_text.is_empty() {
        return None;
    }
    Some(Form {
        title: title.to_owned(),
        index: number - 1,
        total,
        prompt,
        multi,
        options: raw.into_iter().map(|r| Row { label: r.label.join(" "), checked: r.checked }).collect(),
        other_checked: other.checked,
        other_text,
        cursor: u32::try_from(cursor + 1).ok()?,
        fingerprint: fingerprint(&rows[start..=end]),
    })
}

/// Stable digest of the question's own content (not its cursor or checks).
fn digest(form: &Form) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |text: &str| {
        for byte in (text.len() as u64).to_le_bytes().into_iter().chain(text.bytes()) {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3);
        }
    };
    feed(&form.title);
    feed(&form.prompt);
    feed(if form.multi { "multi" } else { "single" });
    for option in &form.options {
        feed(&option.label);
    }
    hash
}

/// `cursor-q:<transcript length>:<n>of<total>:<digest>`. The length is the
/// transcript's size while the form is open (Cursor appends the call only after
/// it is answered), so an identical form asked later gets a new ID.
pub fn request_id(form: &Form, transcript_length: u64) -> String {
    format!("cursor-q:{transcript_length}:{}of{}:{:016x}", form.index + 1, form.total, digest(form))
}

/// (transcript length, 1-based number, total) parsed back from a request ID.
pub fn request_parts(request_id: &str) -> Option<(u64, usize, usize)> {
    let mut parts = request_id.split(':');
    (parts.next() == Some("cursor-q")).then_some(())?;
    let length = parts.next()?.parse().ok()?;
    let (number, total) = parts.next()?.split_once("of")?;
    parts.next()?;
    parts.next().is_none().then_some(())?;
    Some((length, number.parse().ok()?, total.parse().ok()?))
}

/// The pending request behind a visible form; one question per request.
pub fn pending(form: &Form, transcript_length: u64) -> Option<PendingQuestion> {
    let pending = PendingQuestion {
        request_id: request_id(form, transcript_length),
        kind: QuestionKind::CursorAsk,
        turn_id: None,
        questions: vec![Question {
            id: None,
            header: Some(form.title.clone()),
            text: form.prompt.clone(),
            options: form
                .options
                .iter()
                .map(|o| QuestionOption { label: o.label.clone(), description: None })
                .collect(),
            multi_select: form.multi,
            allows_other: true,
            secret: false,
        }],
    };
    pending.client_compatible().then_some(pending)
}

/// Parse the screen against an existing request: same form content and
/// position. `None` when the form changed, moved to another question or left.
pub fn parse(screen: &str, pending: &PendingQuestion) -> Option<QuestionScreen> {
    let form = parse_form(screen)?;
    let (_, number, total) = request_parts(&pending.request_id)?;
    if form.index + 1 != number || form.total != total {
        return None;
    }
    let expected = {
        let question = pending.questions.first()?;
        pending.questions.len() == 1
            && question.header.as_deref() == Some(form.title.as_str())
            && question.text == form.prompt
            && question.multi_select == form.multi
            && question.options.len() == form.options.len()
            && question.options.iter().zip(&form.options).all(|(q, r)| q.label == r.label)
    };
    if !expected || !pending.request_id.ends_with(&format!(":{:016x}", digest(&form))) {
        return None;
    }
    Some(screen_of(&form))
}

fn screen_of(form: &Form) -> QuestionScreen {
    let mut options: Vec<ScreenOption> = form
        .options
        .iter()
        .enumerate()
        .map(|(i, o)| ScreenOption {
            number: i as u32 + 1,
            label: o.label.clone(),
            description: None,
            checked: Some(o.checked),
        })
        .collect();
    options.push(ScreenOption {
        number: form.options.len() as u32 + 1,
        label: "Other".into(),
        description: None,
        checked: Some(form.other_checked),
    });
    QuestionScreen {
        step: QuestionStep::CursorQuestion { index: form.index, total: form.total },
        options,
        cursor: Some(QuestionCursor::Option(form.cursor)),
        // The write-in row takes typing as soon as the cursor reaches it, so
        // there is no separate editing mode to observe.
        free_text: Some(FreeText { active: false, text: form.other_text.clone() }),
        countdown: None,
        queued_count: None,
        unanswered: None,
        completed_tabs: false,
        highlighted: None,
        review_answers: vec![],
        fingerprint: form.fingerprint.clone(),
    }
}

#[cfg(test)]
mod tests;
