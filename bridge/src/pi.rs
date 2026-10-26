//! Pi session-file adapter. Pi session identity is the UUID in its session
//! header; cwd and file recency are never used to pick a session.
use crate::{
    Result,
    adapter::Adapter,
    claude::{Entry, Transcript, bounded, entry_id},
    follower::{AgentType, Follower},
    herdr::Pane,
    resolver::{open_absolute, open_beneath, session_id},
};
use serde_json::Value;
use std::{
    fs::File,
    path::{Path, PathBuf},
};
use std::{
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    time::Duration,
};

pub struct PiAdapter {
    root: Option<PathBuf>,
    anchor: Option<File>,
}
impl PiAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let anchor = root.as_deref().and_then(|p| open_absolute(p, true).ok());
        Self { root, anchor }
    }
    pub fn default_root() -> Option<PathBuf> {
        default_agent_dir().map(|p| p.join("sessions"))
    }
    fn resolve(&self, kind: &str, value: &str) -> Result<(String, PathBuf)> {
        let root = self.root.as_deref().ok_or("transcript_root_unavailable")?;
        let anchor = self.anchor.as_ref().ok_or("transcript_root_unavailable")?;
        if kind == "path" {
            let candidate = Path::new(value);
            let relative = candidate
                .strip_prefix(root)
                .map_err(|_| "unsafe_transcript_path")?;
            let file = open_beneath(anchor, relative, false)?;
            let id = pi_header_id(file)?;
            return Ok((id, root.join(relative)));
        }
        if kind != "id" || !session_id(value) {
            return Err("invalid_session_reference");
        }
        // Pi groups JSONL files below encoded-cwd directories. Search only
        // immediate session directories, and require a single matching header.
        let mut found = None;
        let mut dirs = 0usize;
        for entry in std::fs::read_dir(root).map_err(|_| "transcript_root_unavailable")? {
            dirs += 1;
            if dirs > 10000 {
                return Err("transcript_index_too_large");
            }
            let entry = entry.map_err(|_| "transcript_root_unavailable")?;
            if !entry
                .file_type()
                .map_err(|_| "transcript_unavailable")?
                .is_dir()
            {
                continue;
            }
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "unsafe_transcript_path")?;
            let child = PathBuf::from(name);
            let dir = open_beneath(anchor, &child, true)?;
            let candidate = child.join(format!("{value}.jsonl"));
            if let Ok(file) = open_beneath(&dir, Path::new(&format!("{value}.jsonl")), false) {
                if pi_header_id(file)? != value {
                    return Err("session_mismatch");
                }
                if found.is_some() {
                    return Err("ambiguous_session");
                }
                found = Some(root.join(candidate));
            }
        }
        found
            .map(|p| (value.to_owned(), p))
            .ok_or("transcript_unavailable")
    }
}
fn pi_header_id(mut file: File) -> Result<String> {
    use std::io::{BufRead, BufReader, Read};
    let mut line = String::new();
    BufReader::new(&mut file)
        .take(1024 * 1024)
        .read_line(&mut line)
        .map_err(|_| "transcript_unavailable")?;
    let value: Value = serde_json::from_str(&line).map_err(|_| "invalid_transcript")?;
    if value["type"] != "session" {
        return Err("invalid_transcript");
    }
    let id = value["id"]
        .as_str()
        .filter(|s| session_id(s))
        .ok_or("invalid_transcript")?;
    Ok(id.to_owned())
}
pub fn is_agent(agent: &str) -> bool {
    agent == "pi"
}
pub fn extension_socket(session: &str) -> Result<PathBuf> {
    extension_socket_at(
        &default_agent_dir().ok_or("pi_extension_unavailable")?,
        session,
    )
}
pub fn extension_socket_at(agent_dir: &Path, session: &str) -> Result<PathBuf> {
    if !session_id(session) {
        return Err("invalid_session_reference");
    }
    if !agent_dir.is_absolute() {
        return Err("pi_extension_unavailable");
    }
    Ok(agent_dir.join("herdcats").join(format!("{session}.sock")))
}
pub fn default_agent_dir() -> Option<PathBuf> {
    std::env::var_os("PI_CODING_AGENT_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".pi/agent")))
}
pub fn extension_request(session: &str, method: &str, params: Value) -> Result<Value> {
    let path = extension_socket(session)?;
    extension_request_at(&path, method, params)
}
pub fn extension_request_at(path: &Path, method: &str, params: Value) -> Result<Value> {
    let mut stream = UnixStream::connect(path).map_err(|_| "pi_extension_unavailable")?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "pi_extension_unavailable")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(3)))
        .map_err(|_| "pi_extension_unavailable")?;
    let request = serde_json::json!({"method":method,"params":params});
    let bytes = serde_json::to_vec(&request).map_err(|_| "invalid_pi_response")?;
    if bytes.len() > crate::follower::MAX_RECORD {
        return Err("invalid_pi_response");
    }
    stream
        .write_all(&bytes)
        .and_then(|()| stream.write_all(b"\n"))
        .map_err(|_| "pi_extension_unavailable")?;
    let mut line = Vec::new();
    BufReader::new(stream)
        .take((crate::follower::MAX_RECORD + 1) as u64)
        .read_until(b'\n', &mut line)
        .map_err(|_| "pi_extension_unavailable")?;
    if line.len() > crate::follower::MAX_RECORD {
        return Err("pi_state_too_large");
    }
    if line.last() != Some(&b'\n') {
        return Err("invalid_pi_response");
    }
    let frame: Value = serde_json::from_slice(&line).map_err(|_| "invalid_pi_response")?;
    if frame.get("error").is_some() {
        return Err(match frame["error"]["code"].as_str() {
            Some("stale") => "stale",
            Some("agent_busy") => "agent_busy",
            Some("unsupported") => "unsupported_capability",
            _ => "pi_extension_unavailable",
        });
    }
    frame.get("result").cloned().ok_or("invalid_pi_response")
}
impl Adapter for PiAdapter {
    fn name(&self) -> &'static str {
        "pi"
    }
    fn supports(&self, agent: &str) -> bool {
        is_agent(agent)
    }
    fn is_available(&self) -> bool {
        self.root.is_some() && self.anchor.is_some()
    }
    fn resolve_and_open(&self, pane: &Pane) -> Result<(String, File)> {
        if pane.agent.as_deref() != Some("pi") {
            return Err("unsupported_agent");
        }
        let reference = pane
            .agent_session
            .as_ref()
            .ok_or("session_reference_unavailable")?;
        if reference.agent != "pi" || reference.source != "herdr:pi" {
            return Err("unsupported_session_source");
        }
        let (session, path) = self.resolve(&reference.kind, &reference.value)?;
        let relative = path
            .strip_prefix(self.root.as_deref().ok_or("transcript_root_unavailable")?)
            .map_err(|_| "unsafe_transcript_path")?;
        let file = open_beneath(
            self.anchor.as_ref().ok_or("transcript_root_unavailable")?,
            relative,
            false,
        )?;
        if pi_header_id(file.try_clone().map_err(|_| "transcript_unavailable")?)? != session {
            return Err("session_mismatch");
        }
        Ok((session, file))
    }
    fn resolve_pi_live(&self, pane: &Pane) -> Result<(String, Option<File>, PathBuf)> {
        let reference = pane
            .agent_session
            .as_ref()
            .ok_or("session_reference_unavailable")?;
        if pane.agent.as_deref() != Some("pi")
            || reference.agent != "pi"
            || reference.source != "herdr:pi"
        {
            return Err("unsupported_session_source");
        }
        if reference.kind != "path" {
            let (session, file) = self.resolve_and_open(pane)?;
            let (_, path) = self.resolve(&reference.kind, &reference.value)?;
            return Ok((session, Some(file), path));
        }
        let root = self.root.as_deref().ok_or("transcript_root_unavailable")?;
        let anchor = self.anchor.as_ref().ok_or("transcript_root_unavailable")?;
        let path = Path::new(&reference.value);
        let relative = path
            .strip_prefix(root)
            .map_err(|_| "unsafe_transcript_path")?;
        // Pin every parent before inspecting the leaf. Only ENOENT at this
        // final component is eligible for live-extension bootstrap.
        let parent = relative.parent().ok_or("unsafe_transcript_path")?;
        let dir = if parent.as_os_str().is_empty() {
            anchor.try_clone().map_err(|_| "transcript_unavailable")?
        } else {
            open_beneath(anchor, parent, true)?
        };
        let leaf = relative
            .file_name()
            .and_then(|p| p.to_str())
            .ok_or("unsafe_transcript_path")?;
        let stem = leaf.strip_suffix(".jsonl").unwrap_or("");
        let pending_session = stem
            .get(stem.len().saturating_sub(36)..)
            .filter(|s| session_id(s));
        use std::os::{
            fd::{AsRawFd, FromRawFd},
            unix::ffi::OsStrExt,
        };
        let name = std::ffi::CString::new(std::ffi::OsStr::new(leaf).as_bytes())
            .map_err(|_| "unsafe_transcript_path")?;
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
            )
        };
        let (session, file) = if fd < 0 {
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::ENOENT) {
                return Err("unsafe_transcript_path");
            }
            (
                pending_session
                    .ok_or("invalid_session_reference")?
                    .to_owned(),
                None,
            )
        } else {
            let file = unsafe { File::from_raw_fd(fd) };
            if !file
                .metadata()
                .map_err(|_| "transcript_unavailable")?
                .is_file()
            {
                return Err("unsafe_transcript_path");
            }
            let session = pi_header_id(file.try_clone().map_err(|_| "transcript_unavailable")?)?;
            if pending_session.is_some_and(|expected| expected != session) {
                return Err("session_mismatch");
            }
            (session, Some(file))
        };
        Ok((session, file, path.to_owned()))
    }
    fn new_follower(&self, include_content: bool) -> Follower {
        if include_content {
            Follower::with_content_for_agent(AgentType::Pi)
        } else {
            Follower::for_agent(AgentType::Pi)
        }
    }
}

impl Transcript {
    /// Project Pi's versioned session entries into the existing timeline schema.
    pub fn apply_pi(&mut self, row: &Value, session: &str) -> Result<()> {
        if row["type"] == "session" {
            if row["id"].as_str() != Some(session) {
                return Err("session_mismatch");
            }
            return Ok(());
        }
        if row["type"] != "message" {
            return Ok(());
        }
        let message = &row["message"];
        let role = message["role"].as_str().ok_or("invalid_transcript")?;
        let source_id = row["id"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or("invalid_transcript")?;
        // Pi extension messages may contain plain text (including system
        // messages); native model messages use structured content blocks.
        let plain_content;
        let content = if let Some(text) = message["content"].as_str() {
            plain_content = vec![serde_json::json!({"type":"text", "text":text})];
            &plain_content
        } else {
            message["content"].as_array().ok_or("invalid_transcript")?
        };
        let mut text_parts = Vec::new();
        let mut calls = Vec::new();
        for block in content {
            match block["type"].as_str().unwrap_or("") {
                "text" => {
                    if let Some(text) = block["text"].as_str() {
                        text_parts.push(text);
                    }
                }
                "toolCall" => calls.push(block),
                // Images and thinking are deliberately not rendered as text.
                "image" | "thinking" => (),
                _ => self.unknown_records += 1,
            }
        }
        let text = text_parts.join("\n");
        if !text.is_empty() {
            let (text, truncated) = bounded(&text);
            self.upsert(Entry {
                id: entry_id("pi", source_id)?,
                kind: "message".into(),
                text,
                role: Some(role.into()),
                tool_name: None,
                status: None,
                details: None,
                truncated,
                content_ref: None,
                record_refs: Vec::new(),
            })?;
        }
        for call in calls {
            let id = call["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("invalid_transcript")?;
            let name = call["name"].as_str().unwrap_or("tool");
            let arguments = serde_json::to_string(&call["arguments"]).unwrap_or_default();
            let (details, truncated) = bounded(&arguments);
            self.upsert(Entry {
                id: entry_id("pi:tool", id)?,
                kind: "tool".into(),
                text: name.into(),
                role: None,
                tool_name: Some(name.into()),
                status: Some("running".into()),
                details: Some(details),
                truncated,
                content_ref: None,
                record_refs: Vec::new(),
            })?;
        }
        if role == "toolResult" {
            let call_id = message["toolCallId"].as_str().ok_or("invalid_transcript")?;
            let (text, truncated) = bounded(&text);
            let id = entry_id("pi:tool", call_id)?;
            let arguments = self
                .entries
                .iter()
                .find(|e| e.id == id)
                .and_then(|e| e.details.clone());
            self.upsert(Entry {
                id,
                kind: "tool".into(),
                text,
                role: None,
                tool_name: message["toolName"].as_str().map(str::to_owned),
                status: Some(
                    if message["isError"] == true {
                        "failed"
                    } else {
                        "completed"
                    }
                    .into(),
                ),
                details: arguments,
                truncated,
                content_ref: None,
                record_refs: Vec::new(),
            })?;
        }
        Ok(())
    }
}
