//! Passive Cursor CLI transcript adapter. Identity comes only from Herdr and
//! is matched by exact chat ID; the project slug, cwd and modification times
//! are never used to choose a transcript.
use crate::{
    Result,
    adapter::Adapter,
    claude::{Entry, Transcript, bounded},
    follower::{AgentType, Follower},
    herdr::Pane,
    resolver::{dir_names, open_absolute, open_beneath, session_id},
};
use serde_json::Value;
use std::{fs::File, path::PathBuf};

/// Project directories examined per lookup. Cursor keeps one per workspace.
const MAX_PROJECTS: usize = 10_000;
/// Tool calls retained from one assistant record.
const MAX_CALLS: usize = 128;

pub struct CursorAdapter {
    root: Option<PathBuf>,
    anchor: std::sync::Mutex<Option<File>>,
}
impl CursorAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let anchor = root.as_deref().and_then(|p| open_absolute(p, true).ok());
        Self {
            root,
            anchor: std::sync::Mutex::new(anchor),
        }
    }
    pub fn default_root() -> Option<PathBuf> {
        std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".cursor/projects"))
    }
}
impl Adapter for CursorAdapter {
    fn name(&self) -> &'static str {
        "cursor"
    }
    fn supports(&self, agent: &str) -> bool {
        agent == "cursor"
    }
    fn is_available(&self) -> bool {
        self.root.is_some()
    }
    fn resolve_and_open(&self, pane: &Pane) -> Result<(String, File)> {
        if pane.agent.as_deref() != Some("cursor") {
            return Err("unsupported_agent");
        }
        // A pane with no reported session (for example after `--resume`) has no
        // verifiable chat. Never guess the newest transcript for its cwd.
        let r = pane
            .agent_session
            .as_ref()
            .ok_or("session_reference_unavailable")?;
        if r.agent != "cursor" || r.source != "herdr:cursor" {
            return Err("unsupported_session_source");
        }
        if r.kind != "id" || !session_id(&r.value) {
            return Err("invalid_session_reference");
        }
        // Pin the root descriptor when available. If the root appears later,
        // reopen only the configured absolute path with NOFOLLOW at every level.
        let mut pinned = self
            .anchor
            .lock()
            .map_err(|_| "transcript_root_unavailable")?;
        if pinned.is_none() {
            *pinned = Some(
                open_absolute(
                    self.root.as_deref().ok_or("transcript_root_unavailable")?,
                    true,
                )
                .map_err(|_| "transcript_root_unavailable")?,
            );
        }
        let anchor = pinned.as_ref().ok_or("transcript_root_unavailable")?;
        // The project directory name is a lossy, hashed-when-long encoding of
        // the cwd, so it cannot identify a chat. Require exactly one project
        // holding this exact chat ID; a missing file is delayed creation.
        let mut found = None;
        for project in dir_names(anchor, MAX_PROJECTS)? {
            let relative = PathBuf::from(&project)
                .join("agent-transcripts")
                .join(&r.value)
                .join(format!("{}.jsonl", r.value));
            if let Ok(file) = open_beneath(anchor, &relative, false) {
                if found.is_some() {
                    return Err("ambiguous_session");
                }
                found = Some(file);
            }
        }
        Ok((r.value.clone(), found.ok_or("transcript_unavailable")?))
    }
    fn new_follower(&self, include_content: bool) -> Follower {
        if include_content {
            Follower::with_content_for_agent(AgentType::Cursor)
        } else {
            Follower::for_agent(AgentType::Cursor)
        }
    }
}

/// Remove only the complete outer `<timestamp>`/`<user_query>` envelope.
/// Matching the closing tag at the very end keeps literal tag text inside the
/// prompt; anything unrecognized stays visible verbatim.
fn user_query_text(text: &str) -> &str {
    let body = match text.strip_prefix("<timestamp>") {
        Some(rest) => match rest.split_once("</timestamp>\n") {
            Some((stamp, body)) if !stamp.contains(['\n', '<']) => body,
            _ => return text,
        },
        None => text,
    };
    body.strip_prefix("<user_query>\n")
        .and_then(|body| body.strip_suffix("\n</user_query>"))
        .unwrap_or(text)
}

/// The marker Cursor keeps at the end of a finished turn. The next prompt
/// overwrites it in place, so it is never durable.
pub(crate) fn is_turn_end(row: &Value) -> bool {
    row["type"] == "turn_ended"
}

impl Transcript {
    pub fn apply_cursor(
        &mut self,
        row: &Value,
        offset: usize,
        length: usize,
        preserve: bool,
    ) -> Result<()> {
        let reference = format!("source:{offset}:{length}");
        let prefix = format!("cursor:{offset}");
        let refs = || {
            if preserve {
                vec![reference.clone()]
            } else {
                vec![]
            }
        };
        let make = |id: String,
                    kind: &str,
                    text: &str,
                    role: Option<&str>,
                    name: Option<&str>,
                    status: Option<&str>,
                    details: Option<&str>| {
            let (text, t) = bounded(text);
            let (details, dt) = details
                .map(bounded)
                .map(|(s, t)| (Some(s), t))
                .unwrap_or((None, false));
            Entry {
                id,
                kind: kind.into(),
                text,
                role: role.map(str::to_owned),
                tool_name: name.map(str::to_owned),
                status: status.map(str::to_owned),
                details,
                truncated: t || dt,
                content_ref: (preserve && kind == "record").then(|| reference.clone()),
                record_refs: refs(),
            }
        };
        let role = row["role"].as_str().filter(|r| matches!(*r, "user" | "assistant"));
        let blocks = row["message"]["content"].as_array();
        let (Some(role), Some(blocks)) = (role, blocks) else {
            if is_turn_end(row) {
                return Ok(());
            }
            self.unknown_records += 1;
            if preserve {
                self.upsert(make(
                    format!("{prefix}:record"),
                    "record",
                    row["type"].as_str().or(row["role"].as_str()).unwrap_or("record"),
                    None,
                    None,
                    None,
                    Some(&row.to_string()),
                ))?;
            }
            return Ok(());
        };
        let mut text = String::new();
        let mut tools = Vec::new();
        for (index, block) in blocks.iter().enumerate() {
            match block["type"].as_str() {
                Some("text") if block["text"].is_string() => {
                    if !text.is_empty() {
                        text.push('\n');
                    }
                    text.push_str(block["text"].as_str().unwrap_or(""));
                }
                Some("tool_use") if role == "assistant" => tools.push(block),
                _ => {
                    self.unknown_records += 1;
                    if preserve {
                        self.upsert(make(
                            format!("{prefix}:block:{index}"),
                            "record",
                            block["type"].as_str().unwrap_or("block"),
                            Some(role),
                            None,
                            None,
                            Some(&block.to_string()),
                        ))?;
                    }
                }
            }
        }
        if tools.len() > MAX_CALLS {
            return Err("transcript_identity_limit");
        }
        let text = if role == "user" {
            user_query_text(&text)
        } else {
            &text
        };
        if !text.is_empty() {
            self.upsert(make(
                format!("{prefix}:message"),
                "message",
                text,
                Some(role),
                None,
                None,
                None,
            ))?;
        }
        // The transcript carries no tool-call ID and no result, and a call is
        // written only after its approval or question was resolved. "completed"
        // therefore means "recorded", never "succeeded" or "approved".
        for (i, block) in tools.into_iter().enumerate() {
            let name = block["name"].as_str().unwrap_or("Unknown tool");
            self.upsert(make(
                format!("{prefix}:tool:{i}"),
                "tool",
                name,
                None,
                Some(name),
                Some("completed"),
                Some(&block["input"].to_string()),
            ))?;
        }
        Ok(())
    }
}

/// 64-bit FNV-1a, stable across runs, for request IDs only (not security).
fn fingerprint(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}

/// The shell request behind a live permission card. `file` is the verified
/// transcript; its current length anchors the ID because Cursor appends the
/// call only after it is resolved.
pub fn pending_shell(
    session: &str,
    file: &File,
    command: &str,
) -> Option<crate::approval_match::PendingRequest> {
    let length = file.metadata().ok().filter(|m| m.is_file())?.len();
    (!session.is_empty() && !command.is_empty()).then(|| crate::approval_match::PendingRequest {
        agent: crate::hooks::Agent::Cursor,
        session_id: session.into(),
        request_id: format!("cursor:{length}:{:016x}", fingerprint(command)),
        tool_name: "Shell".into(),
        tool_input: serde_json::json!({"command": command}),
        justification: None,
        turn_id: None,
        suggestions: None,
        recorded_at: 0.0,
    })
}

/// Byte offset a `pending_shell` request was anchored at.
pub fn request_offset(request_id: &str) -> Option<u64> {
    let mut parts = request_id.split(':');
    (parts.next() == Some("cursor")).then_some(())?;
    let offset = parts.next()?.parse().ok()?;
    (parts.next().is_some() && parts.next().is_none()).then_some(offset)
}

/// True when an `AskQuestion` call that asked exactly `prompt` was appended at
/// or after `offset`: the form was submitted. Compared without whitespace
/// because the screen wraps the prompt. Answers are not in the transcript.
pub fn recorded_question(file: &File, offset: u64, prompt: &str) -> bool {
    let want: String = prompt.chars().filter(|c| !c.is_whitespace()).collect();
    appended_blocks(file, offset).iter().any(|block| {
        block["type"] == "tool_use"
            && block["name"] == "AskQuestion"
            && block["input"]["questions"].as_array().is_some_and(|questions| {
                questions.iter().any(|q| {
                    q["prompt"].as_str().is_some_and(|p| {
                        p.chars().filter(|c| !c.is_whitespace()).collect::<String>() == want
                    })
                })
            })
    })
}

/// Assistant content blocks appended at or after `offset` (bounded read).
fn appended_blocks(file: &File, offset: u64) -> Vec<Value> {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = file.try_clone() else { return vec![] };
    let Ok(length) = file.metadata().map(|m| m.len()) else { return vec![] };
    if offset > length || file.seek(SeekFrom::Start(offset)).is_err() {
        return vec![];
    }
    let mut bytes = Vec::new();
    if file.take(4 * 1024 * 1024).read_to_end(&mut bytes).is_err() {
        return vec![];
    }
    bytes
        .split_inclusive(|b| *b == b'\n')
        .filter(|line| line.last() == Some(&b'\n'))
        .filter_map(|line| serde_json::from_slice::<Value>(line).ok())
        .filter(|row| row["role"] == "assistant")
        .filter_map(|row| row["message"]["content"].as_array().cloned())
        .flatten()
        .collect()
}

/// True when a `Shell` call for exactly `command` was appended at or after
/// `offset`. This shows only that the call was recorded after its card was
/// resolved: Cursor writes no result, so run versus denied is not visible.
pub fn recorded_shell(file: &File, offset: u64, command: &str) -> bool {
    appended_blocks(file, offset)
        .iter()
        .any(|block| {
            block["type"] == "tool_use"
                && block["name"] == "Shell"
                && block["input"]["command"].as_str() == Some(command)
        })
}
