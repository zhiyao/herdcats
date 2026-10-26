//! Passive Antigravity CLI transcript adapter. Identity comes only from Herdr,
//! never a workspace cache or modification time.
use crate::{
    Result,
    adapter::Adapter,
    claude::{Entry, Transcript, bounded},
    follower::{AgentType, Follower},
    herdr::Pane,
    resolver::{open_absolute, open_beneath, session_id},
};
use serde_json::Value;
use std::{fs::File, path::PathBuf};
pub struct AgyAdapter {
    root: Option<PathBuf>,
    anchor: std::sync::Mutex<Option<File>>,
}
impl AgyAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let anchor = root.as_deref().and_then(|p| open_absolute(p, true).ok());
        Self {
            root,
            anchor: std::sync::Mutex::new(anchor),
        }
    }
    pub fn default_root() -> Option<PathBuf> {
        std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".gemini/antigravity-cli/brain"))
    }
}
pub fn is_agent(value: &str) -> bool {
    matches!(value, "agy" | "antigravity_cli")
}
impl Adapter for AgyAdapter {
    fn name(&self) -> &'static str {
        "antigravity_cli"
    }
    fn supports(&self, agent: &str) -> bool {
        is_agent(agent)
    }
    fn is_available(&self) -> bool {
        self.root.is_some()
    }
    fn resolve_and_open(&self, pane: &Pane) -> Result<(String, File)> {
        if !pane.agent.as_deref().is_some_and(is_agent) {
            return Err("unsupported_agent");
        }
        let r = pane
            .agent_session
            .as_ref()
            .ok_or("session_reference_unavailable")?;
        if !is_agent(&r.agent) || r.source != "herdr:antigravity_cli" {
            return Err("unsupported_session_source");
        }
        if r.kind != "id" || !session_id(&r.value) {
            return Err("invalid_session_reference");
        }
        // Pin the root descriptor when available. If source creation is delayed,
        // reopen only the configured absolute root with NOFOLLOW at every level.
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
        let relative = PathBuf::from(&r.value).join(".system_generated/logs/transcript.jsonl");
        Ok((
            r.value.clone(),
            open_beneath(anchor, &relative, false).map_err(|_| "transcript_unavailable")?,
        ))
    }
    fn new_follower(&self, include_content: bool) -> Follower {
        if include_content {
            Follower::with_content_for_agent(AgentType::Agy)
        } else {
            Follower::for_agent(AgentType::Agy)
        }
    }
}
/// Remove only the complete, recognized outer USER_INPUT envelope. Searching
/// from the end keeps literal closing tags and nested request examples inside
/// the user's text. Unknown/malformed suffixes remain visible verbatim.
fn user_request_text(text: &str) -> &str {
    // Envelope delimiters use LF or CRLF consistently. The request itself is
    // borrowed unchanged, including its whitespace and any literal tag text.
    let newline = if text.starts_with("<USER_REQUEST>\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let Some(body) = text.strip_prefix(&format!("<USER_REQUEST>{newline}")) else {
        return text;
    };
    fn split_blocks<'a>(
        text: &'a str,
        close: &str,
        open: &str,
        newline: &str,
    ) -> Option<(&'a str, &'a str)> {
        [1, 2]
            .into_iter()
            .filter_map(|gap| {
                let delimiter = format!("{newline}{close}{}{open}{newline}", newline.repeat(gap));
                let index = text.rfind(&delimiter)?;
                Some((index, delimiter.len()))
            })
            .max_by_key(|(index, _)| *index)
            .map(|(index, length)| (&text[..index], &text[index + length..]))
    }
    let Some((request, metadata)) =
        split_blocks(body, "</USER_REQUEST>", "<ADDITIONAL_METADATA>", newline)
    else {
        return text;
    };
    let metadata = if let Some((metadata, settings)) = split_blocks(
        metadata,
        "</ADDITIONAL_METADATA>",
        "<USER_SETTINGS_CHANGE>",
        newline,
    ) {
        let Some(settings) = settings.strip_suffix(&format!("{newline}</USER_SETTINGS_CHANGE>"))
        else {
            return text;
        };
        if settings.contains("<USER_SETTINGS_CHANGE>")
            || settings.contains("</USER_SETTINGS_CHANGE>")
        {
            return text;
        }
        metadata
    } else {
        let Some(metadata) = metadata.strip_suffix(&format!("{newline}</ADDITIONAL_METADATA>"))
        else {
            return text;
        };
        metadata
    };
    if metadata.contains("<ADDITIONAL_METADATA>") || metadata.contains("</ADDITIONAL_METADATA>") {
        return text;
    }
    request
}

impl Transcript {
    pub fn apply_agy(
        &mut self,
        row: &Value,
        offset: usize,
        length: usize,
        preserve: bool,
    ) -> Result<()> {
        let reference = format!("source:{offset}:{length}");
        let kind = row["type"].as_str().unwrap_or("UNKNOWN");
        let step = row["step_index"].as_u64();
        let prefix = step
            .map(|s| format!("agy:{s}"))
            .unwrap_or_else(|| format!("agy:offset:{offset}"));
        let text = row["content"].as_str().unwrap_or("");
        let text = if kind == "USER_INPUT" {
            user_request_text(text)
        } else {
            text
        };
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
        match kind {
            "USER_INPUT" | "PLANNER_RESPONSE" => {
                if step.is_none() {
                    return Err("invalid_transcript");
                }
                if !text.is_empty() {
                    self.upsert(make(
                        format!("{prefix}:message"),
                        "message",
                        text,
                        Some(if kind == "USER_INPUT" {
                            "user"
                        } else {
                            "assistant"
                        }),
                        None,
                        None,
                        None,
                    ))?;
                }
                if let Some(thinking) = row["thinking"]
                    .as_str()
                    .filter(|s| preserve && !s.is_empty())
                {
                    self.upsert(make(
                        format!("{prefix}:thinking"),
                        "record",
                        "Thinking",
                        Some("assistant"),
                        None,
                        None,
                        Some(thinking),
                    ))?;
                }
                self.agy_pending.clear();
                if let Some(calls) = row["tool_calls"].as_array() {
                    if calls.len() > 128 {
                        return Err("transcript_identity_limit");
                    }
                    for (i, call) in calls.iter().enumerate() {
                        let name = call["name"].as_str().unwrap_or("Unknown tool");
                        self.agy_pending.push(format!("{prefix}:tool:{i}"));
                        self.upsert(make(
                            format!("{prefix}:tool:{i}"),
                            "tool",
                            name,
                            None,
                            Some(name),
                            Some("running"),
                            Some(&call["args"].to_string()),
                        ))?;
                    }
                }
            }
            "GENERIC" => {
                // No durable call ID exists in sampled records. Link only when
                // precisely one tool remains outstanding; ambiguity stays raw.
                let pending: Vec<_> = self
                    .entries
                    .iter()
                    .enumerate()
                    .filter(|(_, e)| {
                        self.agy_pending.len() == 1 && self.agy_pending.contains(&e.id)
                    })
                    .map(|(i, _)| i)
                    .collect();
                if pending.len() == 1 {
                    let e = &mut self.entries[pending[0]];
                    let (details, t) = bounded(text);
                    e.details = Some(details);
                    e.truncated = t;
                    e.status = Some(
                        match row["status"].as_str() {
                            Some("ERROR") => "failed",
                            Some("DONE") => "completed",
                            _ => "running",
                        }
                        .into(),
                    );
                    if preserve && e.record_refs.len() < 4 {
                        e.record_refs.push(reference.clone());
                    }
                } else {
                    self.unknown_records += 1;
                    if preserve {
                        self.upsert(make(
                            format!("{prefix}:result"),
                            "record",
                            "Tool result",
                            None,
                            None,
                            None,
                            Some(text),
                        ))?;
                    }
                }
                if matches!(row["status"].as_str(), Some("DONE" | "ERROR")) {
                    self.agy_pending.clear();
                }
            }
            "SYSTEM_MESSAGE" | "CHECKPOINT" => {}
            _ => {
                self.unknown_records += 1;
                if preserve {
                    self.upsert(make(
                        format!("{prefix}:record"),
                        "record",
                        kind,
                        None,
                        None,
                        None,
                        Some(&row.to_string()),
                    ))?;
                }
            }
        }
        Ok(())
    }
}

/// One budget covers version validation and model discovery, including slow CLIs.
pub const CATALOG_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(6);

/// Resolve an executable without a shell. Noninteractive SSH commonly omits
/// ~/.local/bin; that verified user install location is the only fallback.
pub fn resolve_executable(
    path: Option<&std::ffi::OsStr>,
    home: Option<&std::path::Path>,
) -> Result<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let executable = |path: &std::path::Path| {
        path.is_absolute()
            && path
                .metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    };
    if let Some(path) = path {
        for dir in std::env::split_paths(path).filter(|dir| dir.is_absolute()) {
            let candidate = dir.join("agy");
            if executable(&candidate) {
                return Ok(candidate);
            }
        }
    }
    if let Some(home) = home {
        let candidate = home.join(".local/bin/agy");
        if executable(&candidate) {
            return Ok(candidate);
        }
    }
    Err("agy_unavailable")
}

pub fn installed_executable() -> Result<PathBuf> {
    resolve_executable(
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("HOME")
            .as_deref()
            .map(std::path::Path::new),
    )
}

/// Both read-only commands use the same resolved executable and shared deadline.
pub fn discover_catalog(
    executable: &std::path::Path,
    deadline: std::time::Instant,
) -> Result<Vec<crate::model_control::AgyModel>> {
    let version = query_executable(executable, &["--version"], deadline)?;
    if !crate::model_control::agy_supported_version(&version) {
        return Err("agy_unsupported_version");
    }
    let text = query_executable(executable, &["models"], deadline)?;
    if text
        .lines()
        .all(|line| line.trim().is_empty() || line.trim() == "Fetching available models...")
    {
        return Err("agy_catalog_empty");
    }
    let catalog = crate::model_control::parse_agy_models(&text);
    if catalog.is_empty() {
        return Err("agy_catalog_invalid");
    }
    Ok(catalog)
}

/// Bounded read-only query. Never starts or resumes a conversation.
pub fn query(args: &[&str]) -> Result<String> {
    query_executable(
        &installed_executable()?,
        args,
        std::time::Instant::now() + CATALOG_TIMEOUT,
    )
}

pub fn query_executable(
    executable: &std::path::Path,
    args: &[&str],
    deadline: std::time::Instant,
) -> Result<String> {
    use std::{
        io::Read,
        os::{fd::AsRawFd, unix::process::CommandExt},
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };
    if !matches!(args, ["--version"] | ["models"]) {
        return Err("invalid_request");
    }
    if Instant::now() >= deadline {
        return Err("agy_timeout");
    }
    let mut child = Command::new(executable)
        .args(args)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "agy_unavailable")?;
    let terminate = |child: &mut std::process::Child| {
        // SAFETY: this child started its own process group. Killing that group
        // also closes inherited output pipes from its helper processes.
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGKILL);
        }
        let _ = child.wait();
    };
    let mut stdout = child.stdout.take().ok_or("agy_unavailable")?;
    let fd = stdout.as_raw_fd();
    // SAFETY: stdout owns fd for both fcntl calls and the following reads.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        terminate(&mut child);
        return Err("agy_unavailable");
    }
    let mut bytes = Vec::new();
    let mut exited = None;
    loop {
        if Instant::now() >= deadline {
            terminate(&mut child);
            return Err("agy_timeout");
        }
        let mut chunk = [0u8; 4096];
        match stdout.read(&mut chunk) {
            Ok(0) if exited.is_some() => break,
            Ok(n) => bytes.extend_from_slice(&chunk[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => {
                terminate(&mut child);
                return Err("agy_unavailable");
            }
        }
        if bytes.len() > 65536 {
            terminate(&mut child);
            return Err("agy_catalog_invalid");
        }
        match child.try_wait() {
            Ok(Some(status)) => exited = Some(status.success()),
            Ok(None) => {}
            Err(_) => {
                terminate(&mut child);
                return Err("agy_unavailable");
            }
        }
        thread::sleep(
            Duration::from_millis(5).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
    if exited != Some(true) {
        return Err("agy_unavailable");
    }
    String::from_utf8(bytes).map_err(|_| "agy_catalog_invalid")
}

/// Sampled Agy results lack a durable tool ID. Confirm only the unambiguous
/// immediate result of a unique single-call planner record.
pub fn completed_question(history: &[Value], request: &str, count: usize) -> bool {
    let mut seen = std::collections::HashSet::new();
    let mut matching = false;
    for row in history {
        match row["type"].as_str() {
            Some("PLANNER_RESPONSE") => {
                let Some(step) = row["step_index"].as_u64() else {
                    return false;
                };
                if !seen.insert(step) {
                    return false;
                }
                matching = format!("agy:{step}:tool:0") == request
                    && row["tool_calls"]
                        .as_array()
                        .is_some_and(|c| c.len() == 1 && c[0]["name"] == "ask_question");
            }
            Some("USER_INPUT") => matching = false,
            Some("GENERIC") if matching => {
                let text = row["content"].as_str().unwrap_or("");
                return row["status"] == "DONE"
                    && (1..=count)
                        .all(|n| text.lines().any(|l| l.starts_with(&format!("A{n}: "))));
            }
            _ => {}
        }
    }
    false
}

/// Confirm a command result (success or denial/error), only when unambiguous.
pub fn completed_call(history: &[Value], request: &str, tool: &str) -> bool {
    let mut matching = false;
    let mut seen = std::collections::HashSet::new();
    for row in history {
        match row["type"].as_str() {
            Some("PLANNER_RESPONSE") => {
                let Some(step) = row["step_index"].as_u64() else {
                    return false;
                };
                if !seen.insert(step) {
                    return false;
                }
                matching = format!("agy:{step}:tool:0") == request
                    && row["tool_calls"]
                        .as_array()
                        .is_some_and(|c| c.len() == 1 && c[0]["name"] == tool);
            }
            Some("USER_INPUT") => matching = false,
            Some("GENERIC") if matching => {
                return matches!(row["status"].as_str(), Some("DONE" | "ERROR"));
            }
            _ => {}
        }
    }
    false
}
