use crate::{
    cursor_screen,
    Result,
    adapter::Adapter,
    agy::AgyAdapter,
    pi::PiAdapter,
    cursor::CursorAdapter,
    approval_match::{self, PendingRequest, Resolution},
    approval_screen::{self, ApprovalDialog, OptionKey},
    claude::{ClaudeAdapter, Entry},
    codex::{CodexAdapter, CodexResolver},
    follower::{Follower, MAX_RECORD},
    herdr::{Client, Pane},
    hooks::Agent,
    model_control::{self, ClaudeConfirmation, PickerScreen},
    resolver::Resolver,
    question_match::{self, PendingQuestion, QuestionKind},
    question_keys::{self, ExpectedScreen, Input, Step},
    question_screen::{self, QuestionScreen, QuestionStep},
    spool,
};
mod cursor_control;
use cursor_control::CursorCatalog;
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::mpsc,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Debug)]
struct InteractionError {
    code: &'static str,
    steps_sent: Option<usize>,
}
impl From<&'static str> for InteractionError {
    fn from(code: &'static str) -> Self { Self { code, steps_sent: None } }
}
impl InteractionError {
    fn stale_after(steps_sent: usize) -> Self { Self { code: "stale", steps_sent: Some(steps_sent) } }
    fn data(&self) -> Value {
        let mut data = json!({"code":self.code});
        if let Some(steps_sent) = self.steps_sent { data["steps_sent"] = json!(steps_sent); }
        data
    }
}
type InteractionResult<T> = std::result::Result<T, InteractionError>;

/// One successful poll: the verified identity, whether the timeline reset, the
/// agent status, and descriptor clones for interaction/model tail reads.
struct PollOutcome {
    identity: Identity,
    reset: bool,
    status: String,
    approval_file: Option<std::fs::File>,
    model_file: Option<std::fs::File>,
}

#[derive(Clone, PartialEq, Serialize)]
struct Identity {
    pane_id: String,
    terminal_id: String,
    agent: String,
    native_session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    native_instance_id: Option<String>,
}
struct PendingApproval {
    identity: Identity,
    generation: u64,
    request: PendingRequest,
    dialog: ApprovalDialog,
}
impl PendingApproval {
    fn response_key(&self, params: &Value) -> Result<String> {
        let number = params["option"].as_u64().ok_or("mismatch")?;
        let option = self.dialog.options.iter()
            .find(|option| u64::from(option.number) == number).ok_or("mismatch")?;
        let rows = params["label_lines"].as_array().ok_or("mismatch")?;
        if rows.len() != option.label_lines.len()
            || !rows.iter().zip(&option.label_lines).all(|(row, label)| row.as_str() == Some(label))
        {
            return Err("mismatch");
        }
        match (self.request.agent, &option.key) {
            (Agent::Claude, OptionKey::Digit(n)) if *n > 0 => Ok(n.to_string()),
            (Agent::Codex, OptionKey::Letter(c)) if c.is_ascii_alphabetic() => Ok(c.to_string()),
            (Agent::Codex, OptionKey::Escape) => Ok("esc".into()),
            (Agent::Agy, OptionKey::Navigate(_)) => Ok("navigate".into()),
            (Agent::Cursor, OptionKey::Navigate(i)) if cursor_screen::phone_option(*i) => Ok("navigate".into()),
            _ => Err("mismatch"),
        }
    }
    fn data(&self) -> Value {
        // Cursor's persistent and global-permission rows stay in Terminal. The
        // rest keep their screen numbers and exact labels; `selected` indexes
        // the advertised list, or is null while a hidden row is highlighted.
        let advertised: Vec<usize> = (0..self.dialog.options.len())
            .filter(|i| self.request.agent != Agent::Cursor || cursor_screen::phone_option(*i)).collect();
        let selected = self.dialog.selected.and_then(|s| advertised.iter().position(|i| *i == s));
        let options: Vec<_> = advertised.iter().map(|i| &self.dialog.options[*i]).map(|option| {
            let key = match option.key {
                OptionKey::Digit(n) => n.to_string(),
                OptionKey::Letter(c) => c.to_string(),
                OptionKey::Escape => "esc".into(),
                OptionKey::Navigate(_) => "navigate".into(),
            };
            json!({"number":option.number,"label_lines":option.label_lines,"key":key})
        }).collect();
        json!({
            "identity":self.identity,"generation":self.generation,"kind":"approval",
            "request_id":self.request.request_id,"agent":self.request.agent.name(),
            "tool_name":self.request.tool_name,"command":self.request.tool_input["command"],
            "description":if self.request.agent == Agent::Claude {
                self.request.tool_input.get("description").and_then(Value::as_str)
            } else { None },
            "justification":self.request.justification,"environment":self.dialog.environment,
            "title":self.dialog.title,"options":options,"selected":selected
        })
    }
}
struct PendingQuestionEvent {
    identity: Identity,
    generation: u64,
    request: PendingQuestion,
    screen: QuestionScreen,
    fresh: bool,
}
enum PendingInteraction {
    Approval(PendingApproval),
    Question(PendingQuestionEvent),
}
impl PendingInteraction {
    fn data(&self) -> Value {
        match self {
            Self::Approval(p) => p.data(),
            Self::Question(p) => {
                let questions: Vec<_> = p.request.questions.iter().enumerate().map(|(index, q)| {
                    let mut options: Vec<_> = q.options.iter().enumerate().map(|(i, o)|
                        json!({"number":i + 1,"label":o.label,"description":o.description})).collect();
                    if p.request.kind == QuestionKind::CodexPlan && q.allows_other {
                        options.push(json!({"number":options.len() + 1,"label":"None of the above",
                            "description":"Optionally, add details in notes (tab)"}));
                    }
                    json!({"index":index,"header":q.header,"text":q.text,"options":options,
                        "multi_select":q.multi_select,"allows_other":q.allows_other})
                }).collect();
                let step = match p.screen.step {
                    QuestionStep::ClaudeQuestion(index) => json!({"kind":"claude_question","index":index}),
                    QuestionStep::AgyQuestion { index, total } => json!({"kind":"agy_question","index":index,"total":total}),
                    QuestionStep::CursorQuestion { index, total } => json!({"kind":"cursor_question","index":index,"total":total}),
                    QuestionStep::ClaudeReview => json!({"kind":"claude_review"}),
                    QuestionStep::CodexQuestion { index, total } => json!({"kind":"codex_question","index":index,"total":total}),
                    QuestionStep::AsyncQueued => json!({"kind":"async_queued"}),
                    QuestionStep::AsyncPicker(index) => json!({"kind":"async_picker","index":index}),
                };
                let kind = match p.request.kind {
                    QuestionKind::ClaudeAsk => "claude", QuestionKind::CodexPlan => "codex_plan",
                    QuestionKind::CodexAsync => "codex_async",
                    QuestionKind::AgyAsk => "agy",
                    QuestionKind::CursorAsk => "cursor",
                };
                json!({"identity":p.identity,"generation":p.generation,"request_id":p.request.request_id,
                    "agent":p.identity.agent,"kind":"question","question_kind":kind,
                    "questions":questions,"step":step,"fresh":p.fresh,"countdown":p.screen.countdown})
            }
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum QuestionInputStamp {
    Claude(ApprovalInputStamp),
    Codex(ApprovalFileStamp),
    Agy(ApprovalFileStamp),
}
struct QuestionMatchCache {
    identity: Identity,
    stamp: QuestionInputStamp,
    request: Option<PendingQuestion>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct ApprovalFileStamp {
    dev: u64,
    ino: u64,
    len: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}
impl ApprovalFileStamp {
    fn of(metadata: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;
        Self {
            dev: metadata.dev(), ino: metadata.ino(), len: metadata.len(),
            mtime: (metadata.mtime(), metadata.mtime_nsec()),
            ctime: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct ApprovalInputStamp {
    spool: ApprovalFileStamp,
    transcript: ApprovalFileStamp,
}
struct ApprovalMatchCache {
    identity: Identity,
    stamp: ApprovalInputStamp,
    request: Option<PendingRequest>,
}
type ModelPair = Option<(String, Option<String>)>;

struct ModelOverride {
    applied: ModelPair,
    applied_label: Option<String>,
    scanned_at_set: ModelPair,
}

impl ModelOverride {
    fn label_for(&self, pair: &ModelPair) -> Option<String> {
        (self.applied == *pair)
            .then(|| self.applied_label.clone())
            .flatten()
    }
    fn resolve(slot: &mut Option<Self>, scanned: ModelPair) -> ModelPair {
        if let Some(current) = slot {
            if current.scanned_at_set == scanned {
                return current.applied.clone();
            }
            *slot = None;
        }
        scanned
    }
}

struct Watch {
    pane_id: String,
    identity: Option<Identity>,
    follower: Follower,
    generation: u64,
    previous: Vec<Entry>,
    unavailable: Option<&'static str>,
    status: String,
    unknown_records: usize,
    dropped_entries: usize,
    source_changing_count: u32,
    delayed: bool,
    agent: Option<String>,
    // What was last EMITTED as the unavailable state, so a change of any
    // component re-emits: the code, the occupant agent, and the Codex daemon
    // status. Without the agent component, a pane that swaps its occupant
    // codex <-> claude while both fail with the same no-session code would
    // keep the stale event (including the Codex-only codex_daemon field) and
    // would not reset the generation for the new occupant.
    unavailable_agent: Option<String>,
    last_daemon_status: Option<&'static str>,
    pending: Option<PendingInteraction>,
    approval_cache: Option<ApprovalMatchCache>,
    question_cache: Option<QuestionMatchCache>,
    source_pane: Option<Pane>,
    // Transcript stamp behind the last model/effort scan (or emission reset),
    // so unchanged files skip tail reads on every poll.
    model_stamp: Option<(u64, (i64, i64))>,
    last_model: Option<(String, Option<String>)>,
    model_override: Option<ModelOverride>,
    pi_state: Option<Value>,
    pi_dialog: Option<Value>,
}
// Last supported-CLI Codex discovery attempt and failure backoff are kept in
// memory so repeated background status reads never respawn the CLI. Explicit
// Retry clears error backoff while preserving the last successful catalog.

/// Codex catalog plus where it came from, for honest UI labelling.
struct CodexCatalogView {
    models: Vec<model_control::CodexCatalogModel>,
    /// `refreshed` (live CLI), `cache` (models_cache.json), or `unavailable`.
    source: &'static str,
    fresh: bool,
    fetched_at: Option<String>,
    cli_version: Option<String>,
    error: Option<&'static str>,
}

const CODEX_REFRESH_OK_TTL: Duration = Duration::from_secs(300);
const CODEX_REFRESH_FAIL_TTL: Duration = Duration::from_secs(60);
const CODEX_CATALOG_MAX_BYTES: usize = 1 << 20;

pub struct Service {
    pub client: Client,
    pub resolver: Option<Resolver>,
    pub codex_resolver: Option<CodexResolver>,
    adapters: Vec<Box<dyn Adapter>>,
    agy_catalog_cache: std::cell::RefCell<Option<(Instant, Vec<model_control::AgyModel>)>>,
    agy_catalog_error: std::cell::RefCell<Option<(Instant, &'static str)>>,
    agy_executable: std::cell::RefCell<Option<PathBuf>>,
    /// Picker rows of the verified Cursor build, scanned once per version.
    cursor_catalog: std::cell::RefCell<Option<CursorCatalog>>,
    codex_executable: std::cell::RefCell<Option<PathBuf>>,
    codex_catalog_cache: std::cell::RefCell<Option<(Instant, Vec<model_control::CodexCatalogModel>)>>,
    codex_catalog_error: std::cell::RefCell<Option<(Instant, &'static str)>>,
    epoch: String,
    sequence: u64,
    generation: u64,
    initialized: bool,
    include_content: bool,
    include_approvals: bool,
    include_questions: bool,
    watch: Option<Watch>,
    codex_daemon_cache: Option<(std::time::Instant, &'static str)>,
    // The CONFIGURED (never canonicalized) Codex home. CodexResolver::new
    // canonicalizes the sessions root, so deriving the home from
    // `codex_resolver.root.parent()` would follow a symlinked sessions dir
    // (e.g. ~/.codex/sessions -> another volume) and check the WRONG
    // app-server-daemon/daemon.pid — reporting not_running while the real
    // daemon runs under the configured home.
    codex_home: Option<PathBuf>,
    spool_dir: Option<PathBuf>,
    include_model_control: bool,
    // settings.json beside the configured (non-canonicalized) Claude root's
    // parent; `~/.claude/projects` -> `~/.claude/settings.json`.
    claude_settings_path: Option<PathBuf>,
    pi_agent_dir: Option<PathBuf>,
}
pub fn page(entries: &[Entry], before: usize) -> Value {
    let mut start = before.saturating_sub(100);
    // Leave room for envelope and identity; JSON escaping can expand source text.
    while start < before
        && serde_json::to_vec(&entries[start..before]).map_or(true, |v| v.len() > MAX_RECORD / 2)
    {
        start += 1;
    }
    json!({"entries":entries[start..before], "has_more":start>0,
        "before":entries.get(start).filter(|_|start<before).map(|e|e.id.as_str())})
}
impl Service {
    pub fn new(socket: PathBuf, root: PathBuf) -> Self {
        let resolver = Resolver::new(&root).ok();
        let codex_home = crate::codex_config::resolve_codex_dir();
        let codex_root = codex_home.clone().map(|p| p.join("sessions"));
        let codex_resolver = codex_root.and_then(|r| CodexResolver::new(&r).ok());
        let mut service = Self::with_resolvers(socket, resolver, codex_resolver);
        service.codex_home = codex_home;
        service.claude_settings_path = root
            .parent()
            .map(|parent| parent.join("settings.json"))
            .filter(|path| path.is_absolute());
        service
    }

    pub fn codex_root_default() -> Option<PathBuf> {
        crate::codex_config::resolve_codex_dir().map(|p| p.join("sessions"))
    }

    pub fn codex_root_default_from(
        codex_home: Option<impl AsRef<Path>>,
        home: Option<impl AsRef<Path>>,
    ) -> Option<PathBuf> {
        crate::codex_config::resolve_codex_dir_from(codex_home, home).map(|p| p.join("sessions"))
    }
    pub fn with_resolvers(
        socket: PathBuf,
        resolver: Option<Resolver>,
        codex_resolver: Option<CodexResolver>,
    ) -> Self {
        let epoch = format!(
            "{}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            std::process::id()
        );
        let adapters: Vec<Box<dyn Adapter>> = vec![
            Box::new(ClaudeAdapter::new(resolver.clone())),
            Box::new(CodexAdapter::new(codex_resolver.clone())),
            Box::new(AgyAdapter::new(AgyAdapter::default_root())),
            Box::new(PiAdapter::new(PiAdapter::default_root())),
            Box::new(CursorAdapter::new(CursorAdapter::default_root())),
        ];
        Self {
            client: Client { socket },
            resolver,
            codex_resolver,
            adapters,
            agy_catalog_cache: std::cell::RefCell::new(None),
            agy_catalog_error: std::cell::RefCell::new(None),
            agy_executable: std::cell::RefCell::new(None),
            cursor_catalog: std::cell::RefCell::new(None),
            codex_executable: std::cell::RefCell::new(None),
            codex_catalog_cache: std::cell::RefCell::new(None),
            codex_catalog_error: std::cell::RefCell::new(None),
            epoch,
            sequence: 0,
            generation: 0,
            initialized: false,
            include_content: false,
            include_approvals: false,
            include_questions: false,
            watch: None,
            codex_daemon_cache: None,
            codex_home: None,
            spool_dir: spool::resolve_spool_dir(),
            include_model_control: false,
            claude_settings_path: None,
            pi_agent_dir: crate::pi::default_agent_dir(),
        }
    }
    pub fn invalidate_codex_daemon_cache(&mut self) {
        self.codex_daemon_cache = None;
    }
    fn cached_codex_daemon_status(&mut self) -> &'static str {
        if let Some((cached_at, status)) = self.codex_daemon_cache {
            // Monotonic clock: wall-clock jumps must not extend or shrink the TTL.
            if cached_at.elapsed() < Duration::from_secs(3) {
                return status;
            }
        }
        // Resolve from the CONFIGURED home, not the canonicalized resolver
        // root's parent: a symlinked sessions dir must not redirect the
        // daemon pid lookup to the symlink target's parent.
        let codex_dir = self
            .codex_home
            .clone()
            .or_else(crate::codex_config::resolve_codex_dir);
        let status = match codex_dir {
            Some(dir) => {
                let pid_file = dir.join("app-server-daemon").join("daemon.pid");
                match crate::codex_config::check_process(&pid_file, &dir) {
                    crate::codex_config::ProcessStatus::Running => "running",
                    crate::codex_config::ProcessStatus::NotRunning => "not_running",
                    crate::codex_config::ProcessStatus::Unknown => "unknown",
                }
            }
            None => "not_running",
        };
        self.codex_daemon_cache = Some((std::time::Instant::now(), status));
        status
    }
    #[doc(hidden)]
    pub fn with_codex_executable(self, executable: PathBuf) -> Self {
        *self.codex_executable.borrow_mut() = Some(executable);
        self
    }
    #[doc(hidden)]
    pub fn with_codex_home(mut self, home: PathBuf) -> Self {
        self.codex_home = Some(home);
        self.invalidate_codex_daemon_cache();
        self
    }
    #[doc(hidden)]
    pub fn with_claude_settings(mut self, path: PathBuf) -> Self {
        self.claude_settings_path = Some(path);
        self
    }
    pub fn with_codex_root(mut self, root: PathBuf) -> Self {
        self.codex_resolver = CodexResolver::new(&root).ok();
        self.adapters = vec![
            Box::new(ClaudeAdapter::new(self.resolver.clone())),
            Box::new(CodexAdapter::new(self.codex_resolver.clone())),
            Box::new(AgyAdapter::new(AgyAdapter::default_root())),
            Box::new(PiAdapter::new(PiAdapter::default_root())),
            Box::new(CursorAdapter::new(CursorAdapter::default_root())),
        ];
        self
    }
    pub fn with_agy_root(mut self, root: PathBuf) -> Self {
        self.adapters.retain(|a| a.name() != "antigravity_cli");
        self.adapters.push(Box::new(AgyAdapter::new(Some(root))));
        self
    }
    pub fn with_pi_agent_dir(mut self, root: PathBuf) -> Self {
        self.adapters.retain(|a|a.name()!="pi");
        self.adapters.push(Box::new(PiAdapter::new(Some(root.join("sessions")))));
        self.pi_agent_dir=Some(root);
        self
    }
    fn pi_request(&self,session:&str,method:&str,params:Value)->Result<Value>{
        let dir=self.pi_agent_dir.as_deref().ok_or("pi_extension_unavailable")?;
        let socket=crate::pi::extension_socket_at(dir,session)?;
        crate::pi::extension_request_at(&socket,method,params)
    }
    pub fn with_cursor_root(mut self, root: PathBuf) -> Self {
        self.adapters.retain(|a| a.name() != "cursor");
        self.adapters.push(Box::new(CursorAdapter::new(Some(root))));
        self
    }
    fn adapter_for(&self, agent: &str) -> Option<&dyn Adapter> {
        self.adapters
            .iter()
            .find(|a| a.supports(agent))
            .map(|a| a.as_ref())
    }
    fn write(out: &mut impl Write, frame: &Value) -> io::Result<()> {
        let bytes = serde_json::to_vec(frame)?;
        if bytes.len() > MAX_RECORD {
            return Err(io::Error::other("output_frame_too_large"));
        }
        out.write_all(&bytes)?;
        out.write_all(b"\n")?;
        out.flush()
    }
    fn error(out: &mut impl Write, id: Value, code: &str) -> io::Result<()> {
        Self::write(out, &json!({"id":id,"error":{"code":code}}))
    }
    fn event(&mut self, out: &mut impl Write, event: &str, data: Value) -> io::Result<()> {
        self.sequence += 1;
        Self::write(
            out,
            &json!({"event":event,"epoch":self.epoch,"seq":self.sequence,"data":data}),
        )
    }
    fn poll_inner(
        &self,
        watch: &mut Watch,
        refresh: &mut impl FnMut(&mut Follower, std::fs::File, &str) -> Result<bool>,
    ) -> Result<PollOutcome> {
        let snapshot = self.client.snapshot()?;
        let pane = snapshot
            .panes
            .iter()
            .find(|p| p.pane_id == watch.pane_id)
            .ok_or("pane_unavailable")?;
        watch.agent = pane.agent.clone();
        let agent = pane.agent.as_deref().ok_or("unsupported_agent")?;
        let adapter = self.adapter_for(agent).ok_or("unsupported_agent")?;
        let (session, file, pi_state) = if adapter.name() == "pi" {
            let (session, file, path) = adapter.resolve_pi_live(pane)?;
            let state = self.pi_request(&session, "state", json!({}))?;
            if state["version"] != "1.4.0" || state["session_id"].as_str() != Some(session.as_str())
                || state["instance_id"].as_str().is_none_or(|v| v.is_empty() || v.len() > 128)
                || !state["entries"].is_array()
            { return Err("invalid_pi_response"); }
            if state["session_file"].as_str() != path.to_str() { return Err("session_mismatch"); }
            // Rewalk after the extension response: reject parent substitutions,
            // invalid newly persisted files, and any source/session swap.
            let (current_session, current_file, current_path) = adapter.resolve_pi_live(pane)?;
            if current_session != session || current_path != path { return Err("session_mismatch"); }
            if let (Some(before), Some(after)) = (&file, &current_file) {
                use std::os::unix::fs::MetadataExt;
                let before = before.metadata().map_err(|_| "transcript_unavailable")?;
                let after = after.metadata().map_err(|_| "transcript_unavailable")?;
                if before.dev() != after.dev() || before.ino() != after.ino() { return Err("session_mismatch"); }
            } else if file.is_some() { return Err("session_mismatch"); }
            (session, current_file, Some(state))
        } else {
            let (session, file) = adapter.resolve_and_open(pane)?;
            (session, Some(file), None)
        };
        if pane.terminal_id.is_empty()
            || pane.terminal_id.len() > 256
            || pane.agent_status.len() > 256
        {
            return Err("invalid_herdr_response");
        }
        let identity = Identity {
            pane_id: pane.pane_id.clone(),
            terminal_id: pane.terminal_id.clone(),
            agent: adapter.name().into(),
            native_session_id: session.clone(),
            native_instance_id: pi_state.as_ref().and_then(|s|s["instance_id"].as_str().map(str::to_owned)),
        };
        if watch.identity.as_ref() != Some(&identity) {
            watch.follower = adapter.new_follower(self.include_content);
            // A transient read of a new occupant cannot authorize serving the
            // previous occupant's cached transcript.
            watch.identity = None;
            watch.model_override = None;
            watch.approval_cache = None;
            watch.question_cache = None;
            watch.pi_dialog = None;
        }
        if pane.agent_status != "blocked" || identity.agent == "antigravity_cli" {
            watch.approval_cache = None;
            watch.question_cache = None;
        }
        watch.source_pane = Some(pane.clone());
        // Clone only the descriptor. Tail reading happens after timeline work,
        // using the same adapter-verified source and no additional path lookup.
        let approval_file = if identity.agent == "antigravity_cli"
            || (identity.agent == "cursor" && (self.include_approvals || self.include_questions))
            || ((self.include_approvals || self.include_questions) && pane.agent_status == "blocked") {
            file.as_ref().and_then(|f| f.try_clone().ok())
        } else {
            None
        };
        let model_file = if self.include_model_control { file.as_ref().and_then(|f| f.try_clone().ok()) } else { None };
        if let Some(state) = &pi_state {
            watch.follower.refresh_pi_entries(state["entries"].as_array().ok_or("invalid_pi_response")?, &session)?;
            watch.pi_state = Some(state.clone());
        } else {
            watch.pi_state = None;
            refresh(&mut watch.follower, file.ok_or("transcript_unavailable")?, &session)?;
        }
        let reset = watch.identity.as_ref() != Some(&identity)
            || watch.unavailable.is_some()
            || watch.follower.generation != watch.generation;
        Ok(PollOutcome {
            identity,
            reset,
            status: pi_state.as_ref().map(|s| {
                if !s["pending"].is_null() { "blocked" } else { s["status"].as_str().unwrap_or("unknown") }
            }).unwrap_or(&pane.agent_status).to_owned(),
            approval_file,
            model_file,
        })
    }
    pub fn poll(&mut self, out: &mut impl Write) -> io::Result<()> {
        self.poll_with_refresh(out, |follower, file, session| {
            follower.refresh_file(file, session)
        })
    }
    fn poll_with_refresh(
        &mut self,
        out: &mut impl Write,
        mut refresh: impl FnMut(&mut Follower, std::fs::File, &str) -> Result<bool>,
    ) -> io::Result<()> {
        let Some(mut watch) = self.watch.take() else {
            return Ok(());
        };
        let mut pending = None;
        let mut preserve_pending = false;
        match self.poll_inner(&mut watch, &mut refresh) {
            Err("source_changing") if watch.identity.is_some() && watch.unavailable.is_none() => {
                preserve_pending = true;
                watch.source_changing_count += 1;
                if watch.source_changing_count >= 10 && !watch.delayed {
                    watch.delayed = true;
                    let identity = watch.identity.clone().unwrap();
                    let status = watch.status.clone();
                    self.event(
                        out,
                        "timeline.updated",
                        json!({
                            "identity": identity,
                            "generation": self.generation,
                            "entries": [],
                            "evicted_ids": [],
                            "agent_status": status,
                            "unknown_records": watch.unknown_records,
                            "dropped_entries": watch.dropped_entries,
                            "delayed": true
                        }),
                    )?;
                }
            }
            Err(code) => {
                watch.source_pane = None;
                watch.approval_cache = None;
                watch.question_cache = None;
                watch.source_changing_count = 0;
                watch.delayed = false;
                let is_codex_no_session = watch.agent.as_deref() == Some("codex")
                    && matches!(
                        code,
                        "session_reference_unavailable"
                            | "ambiguous_session"
                            | "invalid_session_reference"
                    );
                let current_daemon_status = if is_codex_no_session {
                    Some(self.cached_codex_daemon_status())
                } else {
                    None
                };

                // Emit whenever the emitted-unavailable triple changed: the
                // code, the occupant agent, or the daemon status. An agent
                // change goes through the same generation/reset path below as
                // any other occupant change.
                let should_emit = watch.unavailable != Some(code)
                    || watch.unavailable_agent != watch.agent
                    || watch.last_daemon_status != current_daemon_status;

                if should_emit {
                    self.generation += 1;
                    watch.identity = None;
                    watch.model_override = None;
                    watch.previous.clear();
                    watch.follower = if self.include_content {
                        Follower::with_content()
                    } else {
                        Follower::default()
                    };
                    watch.unavailable = Some(code);
                    watch.unavailable_agent = watch.agent.clone();
                    watch.last_daemon_status = current_daemon_status;
                    let mut data = json!({
                        "pane_id": watch.pane_id,
                        "generation": self.generation,
                        "code": code
                    });
                    if let Some(daemon_status) = current_daemon_status {
                        data["codex_daemon"] = json!(daemon_status);
                    }
                    self.event(out, "timeline.unavailable", data)?;
                }
            }
            Ok(PollOutcome {
                identity,
                reset,
                status,
                approval_file,
                model_file,
            }) => {
                let was_delayed = watch.delayed;
                watch.source_changing_count = 0;
                watch.delayed = false;
                // Agy's local Herdr detection can report idle/done/working on
                // a live question card. Never use that label as an input oracle.
                // Discover before emitting status, even when cards are opted out.
                if reset {
                    watch.approval_cache = None;
                    watch.question_cache = None;
                    // The snapshot clears iOS's pending dialog. Re-emit even
                    // when the native dialog itself has not changed.
                    watch.pi_dialog = None;
                    self.generation += 1;
                }
                let status = if identity.agent == "antigravity_cli" {
                    match approval_file {
                        Some(file) => {
                            let verified = watch.follower.verify_source(file.try_clone().map_err(io::Error::other)?)
                                .and_then(|()| self.agy_interaction(&identity, file, &watch.follower));
                            match verified {
                                Ok(Some(found)) => {
                                    let opted_in = match &found {
                                        PendingInteraction::Approval(_) => self.include_approvals,
                                        PendingInteraction::Question(_) => self.include_questions,
                                    };
                                    if opted_in { pending = Some(found); }
                                    "blocked".to_owned()
                                }
                                // An unresolved call alone never authorizes a
                                // card or input. Hide compose until it is known.
                                Ok(None) => status,
                                Err(_) => "unknown".to_owned(),
                            }
                        }
                        None => "unknown".to_owned(),
                    }
                } else if identity.agent == "cursor" {
                    // Herdr reports a live question form as done, so the screen
                    // decides. Cards still need the blocked status Herdr gives them.
                    match approval_file {
                        Some(file) => {
                            if self.include_approvals && status == "blocked" {
                                pending = file.try_clone().ok().and_then(|file|
                                    self.read_pending(&identity, file, &mut None))
                                    .map(PendingInteraction::Approval);
                            }
                            if pending.is_none() && self.include_questions
                                && matches!(status.as_str(), "blocked" | "idle" | "done") {
                                pending = self.read_question(&identity, file, &mut None)
                                    .map(PendingInteraction::Question);
                            }
                            // A pending decision closes the composer for the phone too.
                            if pending.is_some() { "blocked".to_owned() } else { status }
                        }
                        None => status,
                    }
                } else {
                    if status == "blocked" && let Some(file) = approval_file {
                        if self.include_approvals {
                            pending = file.try_clone().ok().and_then(|file|
                                self.read_pending(&identity, file, &mut watch.approval_cache))
                                .map(PendingInteraction::Approval);
                        }
                        if pending.is_none() && self.include_questions {
                            pending = self.read_question(&identity, file, &mut watch.question_cache)
                                .map(PendingInteraction::Question);
                        }
                    }
                    status
                };
                let data = &watch.follower.transcript;
                let evicted: Vec<_> = watch
                    .previous
                    .iter()
                    .filter(|old| !data.entries.iter().any(|new| new.id == old.id))
                    .map(|old| old.id.clone())
                    .collect();
                if reset {
                    watch.last_model = None;
                    watch.model_override = None;
                    watch.model_stamp = None;
                    let mut body = page(&data.entries, data.entries.len());
                    body["identity"] = json!(identity);
                    body["generation"] = json!(self.generation);
                    body["agent_status"] = json!(status);
                    body["unknown_records"] = json!(data.unknown_records);
                    body["dropped_entries"] = json!(data.dropped_entries);
                    body["delayed"] = json!(false);
                    if self.include_model_control && identity.agent == "antigravity_cli"
                        && let (Some(pane), Some(file)) = (watch.source_pane.as_ref(), model_file.as_ref())
                        && let Ok(file) = file.try_clone()
                        && let Some((id, effort)) = self.model_scan_raw(&identity.agent, pane, file)
                        && let Ok(catalog) = self.agy_catalog()
                    {
                        body["model"] = model_control::agy_model_value(&id, &catalog);
                        body["effort"] = json!(effort);
                    }
                    if let Some(state)=watch.pi_state.as_ref() {
                        body["model"] = state["model"].clone();
                        body["effort"] = state["model"]["effort"].clone();
                    }
                    self.event(out, "timeline.snapshot", body)?;
                } else {
                    let changed: Vec<_> = data
                        .entries
                        .iter()
                        .filter(|entry| {
                            watch.previous.iter().find(|old| old.id == entry.id) != Some(*entry)
                        })
                        .cloned()
                        .collect();
                    if !changed.is_empty()
                        || !evicted.is_empty()
                        || status != watch.status
                        || data.unknown_records != watch.unknown_records
                        || data.dropped_entries != watch.dropped_entries
                        || was_delayed
                    {
                        // Each batch reserves half the frame for the envelope.
                        // Evictions precede inserts, with <=1000 IDs in total.
                        let mut evictions = Vec::new();
                        let mut size = 0;
                        for id in evicted {
                            let encoded = serde_json::to_vec(&id)?.len() + 1;
                            if !evictions.is_empty() && size + encoded > MAX_RECORD / 2 {
                                self.event(out, "timeline.updated", json!({"identity":identity,"generation":self.generation,"entries":[],"evicted_ids":evictions,"agent_status":status,"unknown_records":data.unknown_records,"dropped_entries":data.dropped_entries,"delayed":false}))?;
                                evictions.clear();
                                size = 0;
                            }
                            evictions.push(id);
                            size += encoded;
                        }
                        let mut batch = Vec::new();
                        for entry in changed {
                            let encoded = serde_json::to_vec(&entry)?.len() + 1;
                            if (!batch.is_empty() || !evictions.is_empty())
                                && size + encoded > MAX_RECORD / 2
                            {
                                self.event(out, "timeline.updated", json!({"identity":identity,"generation":self.generation,"entries":batch,"evicted_ids":evictions,"agent_status":status,"unknown_records":data.unknown_records,"dropped_entries":data.dropped_entries,"delayed":false}))?;
                                batch.clear();
                                evictions.clear();
                                size = 0;
                            }
                            batch.push(entry);
                            size += encoded;
                        }
                        self.event(out, "timeline.updated", json!({"identity":identity,"generation":self.generation,"entries":batch,"evicted_ids":evictions,"agent_status":status,"unknown_records":data.unknown_records,"dropped_entries":data.dropped_entries,"delayed":false}))?;
                    }
                }
                watch.unknown_records = data.unknown_records;
                watch.dropped_entries = data.dropped_entries;
                watch.previous = data.entries.clone();
                watch.identity = Some(identity.clone());
                watch.status = status;
                watch.unavailable = None;
                watch.unavailable_agent = None;
                watch.last_daemon_status = None;
                watch.generation = watch.follower.generation;
                if self.include_model_control {
                    if identity.agent == "pi" { self.update_pi_model(out,&mut watch)?; }
                    else { self.update_model(out, &mut watch, model_file)?; }
                }
            }
        }
        if (self.include_approvals || self.include_questions) && !preserve_pending {
            self.update_pending(out, &mut watch, pending)?;
        }
        if !preserve_pending && let Some(state) = watch.pi_state.as_ref() {
            let dialog = state.get("pending").filter(|value| !value.is_null()).cloned();
            if dialog != watch.pi_dialog {
                if let Some(dialog) = &dialog {
                    let mut data = dialog.clone();
                    data["identity"] = serde_json::to_value(watch.identity.as_ref()).unwrap_or(Value::Null);
                    data["generation"] = json!(self.generation);
                    data["request_id"] = data["id"].clone();
                    if let Some(options)=data.get("options").cloned() {
                        data["dialog_options"]=options;
                        data.as_object_mut().map(|object|object.remove("options"));
                    }
                    data.as_object_mut().map(|object|object.remove("id"));
                    self.event(out, "pi.dialog", data)?;
                } else if let Some(previous) = &watch.pi_dialog {
                    self.event(out, "pi.dialog.cleared", json!({"identity":watch.identity,"generation":self.generation,"request_id":previous["id"]}))?;
                }
                watch.pi_dialog = dialog;
            }
        }
        self.watch = Some(watch);
        Ok(())
    }
    fn approval_input_stamp(
        &self,
        identity: &Identity,
        file: &std::fs::File,
    ) -> Option<ApprovalInputStamp> {
        let dir = self.spool_dir.as_deref()?;
        let directory = std::fs::symlink_metadata(dir).ok()?;
        if !directory.is_dir() || directory.file_type().is_symlink() {
            return None;
        }
        let path = dir.join(format!("{}-{}.jsonl", identity.agent, identity.native_session_id));
        let spool = std::fs::symlink_metadata(path).ok()?;
        let transcript = file.metadata().ok()?;
        if !spool.is_file() || !transcript.is_file() {
            return None;
        }
        Some(ApprovalInputStamp {
            spool: ApprovalFileStamp::of(&spool),
            transcript: ApprovalFileStamp::of(&transcript),
        })
    }
    // Match only when the source files changed; the visible dialog remains a
    // live read in read_pending. The tail I/O boundary mirrors poll's refresh
    // boundary so tests can verify that cache hits do no tail reading.
    fn matched_request(
        &self,
        identity: &Identity,
        file: std::fs::File,
        cache: &mut Option<ApprovalMatchCache>,
        mut read_tail: impl FnMut(std::fs::File) -> Result<Vec<Value>>,
    ) -> Option<PendingRequest> {
        if Agent::parse(&identity.agent) == Some(Agent::Cursor) {
            // Cursor writes nothing to its transcript while a card is pending,
            // so the live screen supplies the request. The ID is anchored to the
            // transcript length: resolving any call appends a record, so a new
            // card for an identical command gets a new ID.
            *cache = None;
            let screen = self.client.read_visible(&identity.pane_id).ok()?;
            let (command, _) = cursor_screen::parse_card(&screen)?;
            return crate::cursor::pending_shell(&identity.native_session_id, &file, &command);
        }
        if Agent::parse(&identity.agent) == Some(Agent::Agy) {
            *cache = None;
            let history = read_tail(file).ok()?;
            return approval_match::pending_agy_commands(&identity.native_session_id, &history).into_iter().last();
        }
        let stamp = match self.approval_input_stamp(identity, &file) {
            Some(stamp) => stamp,
            None => {
                *cache = None;
                return None;
            }
        };
        if let Some(cached) = cache.as_ref().filter(|c| c.identity == *identity && c.stamp == stamp) {
            return cached.request.clone();
        }
        *cache = None;
        let agent = Agent::parse(&identity.agent)?;
        let mut records = spool::read_session(
            self.spool_dir.as_deref()?, agent, &identity.native_session_id,
        );
        records.retain(|record| {
            record["session_id"] == identity.native_session_id
                && record["payload"]["session_id"] == identity.native_session_id
        });
        if records.is_empty() {
            return None;
        }
        let history = read_tail(file.try_clone().ok()?).ok()?;
        let requests = match agent {
            Agent::Claude => approval_match::match_claude_records(&records, &history),
            Agent::Codex => approval_match::match_codex_records(&records, &history),
            Agent::Agy | Agent::Cursor => return None,
        };
        let request = requests.into_iter().rfind(|request| {
            let resolution = match agent {
                Agent::Agy | Agent::Cursor => return false,
                Agent::Claude => approval_match::claude_resolution(&request.request_id, &history),
                Agent::Codex => match request.turn_id.as_deref() {
                    Some(turn) => approval_match::codex_resolution(&request.request_id, turn, &history),
                    None => return false,
                },
            };
            resolution == Resolution::Pending
        });
        // Never retain a result assembled while either input was changing.
        if self.approval_input_stamp(identity, &file).as_ref() != Some(&stamp) {
            return None;
        }
        *cache = Some(ApprovalMatchCache {
            identity: identity.clone(), stamp, request: request.clone(),
        });
        request
    }
    fn read_pending(
        &self,
        identity: &Identity,
        file: std::fs::File,
        cache: &mut Option<ApprovalMatchCache>,
    ) -> Option<PendingApproval> {
        let request = self.matched_request(identity, file, cache, crate::follower::read_tail)?;
        let agent = request.agent;
        let command = request.tool_input["command"].as_str()?;
        let screen = self.client.read_visible(&identity.pane_id).ok()?;
        let dialog = approval_screen::parse(agent, &screen, command)?;
        Some(PendingApproval {
            identity: identity.clone(), generation: self.generation, request, dialog,
        })
    }
    fn question_input_stamp(&self, identity: &Identity, file: &std::fs::File) -> Option<QuestionInputStamp> {
        match Agent::parse(&identity.agent)? {
            Agent::Claude => self.approval_input_stamp(identity, file).map(QuestionInputStamp::Claude),
            Agent::Agy => {
                let meta = file.metadata().ok()?;
                meta.is_file().then(|| QuestionInputStamp::Agy(ApprovalFileStamp::of(&meta)))
            }
            // Cursor questions arrive in a later section; none are advertised.
            Agent::Cursor => None,
            Agent::Codex => {
                let meta = file.metadata().ok()?;
                meta.is_file().then(|| QuestionInputStamp::Codex(ApprovalFileStamp::of(&meta)))
            }
        }
    }
    fn matched_question(
        &self,
        identity: &Identity,
        file: std::fs::File,
        cache: &mut Option<QuestionMatchCache>,
    ) -> Option<PendingQuestion> {
        if Agent::parse(&identity.agent) == Some(Agent::Cursor) {
            // Nothing about a pending Cursor form is in the transcript: the
            // screen is the request. Never cached; the length anchors the ID.
            *cache = None;
            let length = file.metadata().ok().filter(|m| m.is_file())?.len();
            let form = crate::cursor_form::parse_form(&self.client.read_visible(&identity.pane_id).ok()?)?;
            return crate::cursor_form::pending(&form, length);
        }
        let stamp = match self.question_input_stamp(identity, &file) {
            Some(stamp) => stamp,
            None => { *cache = None; return None; }
        };
        if let Some(cached) = cache.as_ref()
            .filter(|c| c.identity == *identity && c.stamp == stamp) {
            cached.request.clone()
        } else {
            *cache = None;
            let history = crate::follower::read_tail(file.try_clone().ok()?).ok()?;
            let requests = match Agent::parse(&identity.agent)? {
                Agent::Claude => {
                    let mut records = spool::read_session(self.spool_dir.as_deref()?, Agent::Claude,
                        &identity.native_session_id);
                    records.retain(|r| r["session_id"] == identity.native_session_id
                        && r["payload"]["session_id"] == identity.native_session_id);
                    question_match::pending_claude_spool_questions(&records, &history)
                },
                Agent::Codex => question_match::pending_codex_questions(&history),
                Agent::Agy => question_match::pending_agy_questions(&history),
                Agent::Cursor => vec![],
            };
            // A queued banner cannot identify which async call shift+left opens,
            // even when the calls have identical questions. Preserve Plan selection.
            let async_count = requests.iter().filter(|r| r.kind == QuestionKind::CodexAsync).count();
            let request = requests.into_iter().last()
                .filter(|r| r.kind != QuestionKind::CodexAsync || async_count == 1);
            if self.question_input_stamp(identity, &file).as_ref() != Some(&stamp) { return None; }
            *cache = Some(QuestionMatchCache { identity: identity.clone(), stamp, request: request.clone() });
            request
        }
    }
    fn read_question(
        &self,
        identity: &Identity,
        file: std::fs::File,
        cache: &mut Option<QuestionMatchCache>,
    ) -> Option<PendingQuestionEvent> {
        let request = self.matched_question(identity, file, cache)?;
        if request.questions.iter().any(|q| q.secret)
            || (request.kind == QuestionKind::CodexAsync && request.questions.len() != 1) {
            return None;
        }
        let visible = self.client.read_visible(&identity.pane_id).ok()?;
        let screen = question_screen::parse(request.kind, &visible, &request)?;
        if screen.step == QuestionStep::AsyncQueued && screen.queued_count != Some(1) {
            return None;
        }
        let fresh = screen.is_fresh(&request);
        Some(PendingQuestionEvent { identity: identity.clone(), generation: self.generation,
            request, screen, fresh })
    }
    /// Native record + exact live screen, then fresh occupant/source again.
    /// Err means unresolved/uncertain; None means no outstanding interaction.
    fn agy_interaction(&self, identity: &Identity, file: std::fs::File, follower: &Follower) -> Result<Option<PendingInteraction>> {
        let history = crate::follower::read_tail(file.try_clone().map_err(|_| "stale")?)?;
        let outstanding = Self::agy_unresolved_tools(&history);
        if !outstanding { return Ok(None); }
        let found = self.read_pending(identity, file.try_clone().map_err(|_| "stale")?, &mut None)
            .map(PendingInteraction::Approval)
            .or_else(|| self.read_question(identity, file, &mut None).map(PendingInteraction::Question))
            .ok_or("stale")?;
        let (_, fresh) = self.model_pane_file(identity)?;
        // Verify the same bytes still supply the pending call after screen I/O.
        follower.verify_source(fresh.try_clone().map_err(|_|"stale")?)?;
        let current = crate::follower::read_tail(fresh)?;
        if history != current { return Err("stale"); }
        Ok(Some(found))
    }
    fn agy_unresolved_tools(history: &[Value]) -> bool {
        let mut unresolved = false;
        for row in history {
            match row["type"].as_str() {
                Some("USER_INPUT") => unresolved = false,
                Some("PLANNER_RESPONSE") => unresolved = row.get("tool_calls").is_some_and(|calls| calls.as_array().is_none_or(|calls| !calls.is_empty())),
                Some("GENERIC") if matches!(row["status"].as_str(), Some("DONE" | "ERROR")) => unresolved = false,
                _ => {},
            }
        }
        unresolved
    }
    fn agy_require_no_pending(&self, identity: &Identity, file: std::fs::File) -> Result<()> {
        if identity.agent != "antigravity_cli" { return Ok(()); }
        let watch=self.watch.as_ref().ok_or("stale")?;
        watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?)?;
        let history=crate::follower::read_tail(file)?;
        // Refusal can be conservative; authorization still needs an empty
        // composer and an idle occupant, never transcript completion alone.
        if Self::agy_unresolved_tools(&history) {return Err("agent_busy");}
        Ok(())
    }
    fn update_pending(
        &mut self,
        out: &mut impl Write,
        watch: &mut Watch,
        pending: Option<PendingInteraction>,
    ) -> io::Result<()> {
        // Include the actual event envelope and a possible preceding resolved
        // event's sequence increment when checking the bounded wire frame.
        let pending = pending.filter(|pending| {
            let frame = json!({"event":"interaction.pending","epoch":self.epoch,
                "seq":self.sequence.saturating_add(2),"data":pending.data()});
            serde_json::to_vec(&frame).is_ok_and(|bytes| bytes.len() < MAX_RECORD)
        });
        let old_data = watch.pending.as_ref().map(PendingInteraction::data);
        let new_data = pending.as_ref().map(PendingInteraction::data);
        let same_request = old_data.as_ref().zip(new_data.as_ref()).is_some_and(|(old, new)|
            ["identity", "generation", "request_id", "kind"].iter().all(|key| old[key] == new[key]));
        if !same_request && let Some(old) = watch.pending.take() {
            let old = old.data();
            self.event(out, "interaction.resolved", json!({"identity":old["identity"],
                "generation":old["generation"],"request_id":old["request_id"]}))?;
        }
        if let Some(new) = pending {
            let dialog_changed = match (watch.pending.as_ref(), &new) {
                (Some(PendingInteraction::Approval(old)), PendingInteraction::Approval(new)) =>
                    old.dialog.canonical() != new.dialog.canonical(),
                _ => false,
            };
            if old_data != new_data || dialog_changed {
                self.event(out, "interaction.pending", new.data())?;
            }
            watch.pending = Some(new);
        }
        Ok(())
    }
    fn update_pi_model(&mut self, out: &mut impl Write, watch: &mut Watch) -> io::Result<()> {
        let (Some(identity),Some(state))=(watch.identity.clone(),watch.pi_state.as_ref()) else {return Ok(());};
        let Some(id)=state["model"]["id"].as_str() else {return Ok(());};
        let effort=state["model"]["effort"].as_str().map(str::to_owned);
        let observed=(id.to_owned(),effort.clone());
        if watch.last_model.as_ref()==Some(&observed) {return Ok(());}
        watch.last_model=Some(observed);
        let model=state["model"].clone();
        self.event(out,"model.updated",json!({"identity":identity,"generation":self.generation,"model":model,"effort":effort}))
    }
    fn update_model(
        &mut self,
        out: &mut impl Write,
        watch: &mut Watch,
        file: Option<std::fs::File>,
    ) -> io::Result<()> {
        let Some(file) = file else {
            return Ok(());
        };
        let Some(identity) = watch.identity.clone() else {
            return Ok(());
        };
        if identity.agent == "antigravity_cli" && !matches!(watch.status.as_str(), "idle" | "done") { return Ok(()); }
        let stamp = match file.metadata() {
            Ok(metadata) if metadata.is_file() => {
                use std::os::unix::fs::MetadataExt;
                (metadata.len(), (metadata.mtime(), metadata.mtime_nsec()))
            }
            _ => return Ok(()),
        };
        let live_footer =
            matches!(identity.agent.as_str(), "codex" | "antigravity_cli") && matches!(watch.status.as_str(), "idle" | "done");
        if watch.model_stamp == Some(stamp) && !live_footer {
            return Ok(());
        }
        // Claude can skip unchanged transcript scans; Codex idle footers must
        // remain live even when session-only changes leave that stamp unchanged.
        watch.model_stamp = Some(stamp);
        let Some(pane) = watch.source_pane.as_ref() else {
            return Ok(());
        };
        let observed = self.model_scan_raw(&identity.agent, pane, file);
        let observed = ModelOverride::resolve(&mut watch.model_override, observed);
        let Some(observed) = observed else {
            return Ok(());
        };
        if watch.last_model.as_ref() != Some(&observed) {
            let label = watch
                .model_override
                .as_ref()
                .and_then(|value| value.label_for(&Some(observed.clone())));
            // Always a labeled object, so clients never fall back to raw ids.
            let label = label.unwrap_or_else(|| match identity.agent.as_str() {
                "claude" => model_control::claude_display_label(&observed.0),
                "antigravity_cli" => self.agy_catalog().ok().and_then(|catalog| catalog.iter().find(|m| m.id == observed.0).map(|m|m.label.clone())).unwrap_or_else(||observed.0.clone()),
                _ => self
                    .codex_catalog()
                    .iter()
                    .find(|model| model.slug == observed.0)
                    .map(|model| model.label.clone())
                    .unwrap_or_else(|| model_control::codex_slug_label(&observed.0)),
            });
            let model = if identity.agent == "antigravity_cli" {
                let Ok(catalog) = self.agy_catalog() else { return Ok(()) };
                model_control::agy_model_value(&observed.0, &catalog)
            } else { json!({"id":observed.0,"label":label}) };
            watch.last_model = Some(observed.clone());
            self.event(
                out,
                "model.updated",
                json!({"identity":identity,"generation":self.generation,
                    "model":model,"effort":observed.1}),
            )?;
        }
        Ok(())
    }
    /// Fallback pair for a session with no turns yet: Claude's persisted
    /// default (settings.json), Codex's config.toml defaults.
    fn model_scan_fallback(&self, agent: &str) -> Option<(String, Option<String>)> {
        match agent {
            "claude" => {
                // A missing settings.json (a fresh install) is empty settings:
                // Claude still runs its default model.
                let text = self
                    .claude_settings_path
                    .as_ref()
                    .and_then(|path| std::fs::read_to_string(path).ok())
                    .unwrap_or_default();
                let settings = model_control::parse_claude_settings(&text);
                // No configured model means Claude's default; its effort can
                // still be set and must not be lost with the model.
                let model = settings
                    .model
                    .clone()
                    .unwrap_or_else(|| model_control::CLAUDE_DEFAULT_MODEL.to_owned());
                let effort = settings.effort_for(&model).map(str::to_owned);
                Some((model, effort))
            }
            "codex" => {
                let home = self
                    .codex_home
                    .clone()
                    .or_else(crate::codex_config::resolve_codex_dir)?;
                let text = std::fs::read_to_string(home.join("config.toml")).ok()?;
                let (model, effort) = model_control::parse_codex_config(&text);
                model.map(|model| (model, effort))
            }
            _ => None,
        }
    }
    fn model_scan_raw(&self, agent: &str, pane: &Pane, file: std::fs::File) -> ModelPair {
        if agent == "antigravity_cli" {
            return self.client.read_visible(&pane.pane_id).ok().and_then(|screen| { let catalog = self.agy_catalog().ok()?; model_control::agy_idle_footer(&screen, &catalog) });
        }
        if agent == "codex"
            && matches!(pane.agent_status.as_str(), "idle" | "done")
            && let Ok(screen) = self.client.read_visible(&pane.pane_id)
            && let Some(pair) = model_control::codex_idle_footer(&screen, &self.codex_catalog())
        {
            return Some(pair);
        }
        let scan = |records: &[Value]| match agent {
            "claude" => model_control::claude_scan(records),
            "codex" => model_control::codex_scan(records),
            _ => None,
        };
        let wide = file
            .try_clone()
            .ok()
            .filter(|file| file.metadata().is_ok_and(|meta| meta.len() > 4 * 1024 * 1024));
        let records = crate::follower::read_tail(file).ok()?;
        // A latest record larger than the usual tail (a huge assistant reply,
        // or a turn_context pushed out by one) needs the follower's full
        // bounded window before falling back to settings.
        scan(&records)
            .or_else(|| {
                let records =
                    crate::follower::read_tail_within(wide?, crate::follower::MAX_SOURCE).ok()?;
                scan(&records)
            })
            .or_else(|| self.model_scan_fallback(agent))
    }
    fn model_scan_current(&mut self, agent: &str, pane: &Pane, file: std::fs::File) -> ModelPair {
        let scanned = self.model_scan_raw(agent, pane, file);
        self.resolve_model_scan(scanned)
    }
    fn resolve_model_scan(&mut self, scanned: ModelPair) -> ModelPair {
        match self.watch.as_mut() {
            Some(watch) => ModelOverride::resolve(&mut watch.model_override, scanned),
            None => scanned,
        }
    }
    fn agy_catalog(&self) -> Result<Vec<model_control::AgyModel>> {
        if let Some((at, catalog)) = self.agy_catalog_cache.borrow().as_ref()
            && at.elapsed() < Duration::from_secs(60) { return Ok(catalog.clone()); }
        // Automatic footer polling must not repeatedly spawn a failing CLI.
        // Explicit model.status clears this failure throttle before polling.
        if let Some((at, code)) = self.agy_catalog_error.borrow().as_ref()
            && at.elapsed() < Duration::from_secs(60) { return Err(*code); }
        let result = (|| {
            let pinned = self.agy_executable.borrow().clone();
            let executable = match pinned {
                Some(path) => path,
                None => {
                    let path = crate::agy::installed_executable()?;
                    *self.agy_executable.borrow_mut() = Some(path.clone());
                    path
                }
            };
            crate::agy::discover_catalog(&executable, Instant::now() + crate::agy::CATALOG_TIMEOUT)
        })();
        match &result {
            Ok(catalog) => {
                *self.agy_catalog_cache.borrow_mut() = Some((Instant::now(), catalog.clone()));
                *self.agy_catalog_error.borrow_mut() = None;
            }
            Err(code) => *self.agy_catalog_error.borrow_mut() = Some((Instant::now(), *code)),
        }
        result
    }
    fn set_agy_model(&self, identity: &Identity, current: &ModelPair, model: Option<&str>, effort: Option<&str>) -> Result<Value> {
        let catalog = self.agy_catalog()?;
        let (current_id, current_effort) = current.as_ref().ok_or("stale")?;
        let target = model_control::agy_target(&catalog, current_id, current_effort.as_deref(), model, effort)?;
        let target_effort = model_control::agy_native_effort(target).ok_or("invalid_effort")?;
        let result = |confirmed, error: Option<&str>, pair: &ModelPair| json!({"identity":identity,"generation":self.generation,"applied":{
            "model":pair.as_ref().map(|(id,_)|json!({"id":id,"label":catalog.iter().find(|m|m.id==*id).map(|m|m.label.as_str()).unwrap_or(id)})),
            "effort":pair.as_ref().and_then(|(_,e)|e.as_deref())},"confirmed":confirmed,"error":error});
        if target.id==*current_id && current_effort.as_deref()==Some(target_effort) { return Ok(result(true,None,current)); }
        // Refuse changed installed versions even if a previous catalog is cached.
        let executable = self.agy_executable.borrow().clone().ok_or("agy_unavailable")?;
        let version=crate::agy::query_executable(&executable, &["--version"], Instant::now() + crate::agy::CATALOG_TIMEOUT)?;
        if !model_control::agy_supported_version(&version) {return Err("agy_unsupported_version");}
        self.composer_clear(identity,"agy")?;
        let before=self.client.read_visible(&identity.pane_id)?;
        if model_control::agy_composer_state(&before, &catalog)!=model_control::Composer::Empty {return Err("composer_not_empty");}
        if model_control::agy_idle_footer(&before,&catalog).as_ref()!=current.as_ref() {return Err("stale");}
        self.recheck_idle(identity)?;
        let (_,file)=self.model_pane_file(identity)?;
        self.watch.as_ref().ok_or("stale")?.follower.verify_source(file)?;
        let command=if model.is_some() {format!("/model {}",target.id)} else {format!("/effort {target_effort}")};
        // A failed send may have been delivered. The caller must refresh; no retry.
        self.client.agent_prompt(&identity.pane_id,&command)?;
        let deadline=Instant::now()+Duration::from_secs(4);
        loop {
            self.recheck_idle(identity)?;
            let screen=self.client.read_visible(&identity.pane_id)?;
            let observed=model_control::agy_idle_footer(&screen,&catalog);
            let acknowledgement=model_control::agy_fresh_confirmation(&screen,&before,
                model.map(|_|target.label.as_str()),if model.is_none(){Some(target_effort)}else{None});
            if acknowledgement && observed.as_ref().is_some_and(|(id,e)|id==&target.id && e.as_deref()==Some(target_effort)) {
                return Ok(result(true,None,&observed));
            }
            if Instant::now()>=deadline {return Ok(result(false,Some("confirm_timeout"),current));}
            thread::sleep(Duration::from_millis(100));
        }
    }
    /// Catalog for guards, footer matching, and label lookups: never spawns the CLI.
    fn codex_catalog(&self) -> Vec<model_control::CodexCatalogModel> {
        if let Some((_, models)) = self.codex_catalog_cache.borrow().as_ref() {
            return models.clone();
        }
        self.codex_catalog_view(false).models
    }
    fn codex_home_dir(&self) -> Option<PathBuf> {
        self.codex_home.clone().or_else(crate::codex_config::resolve_codex_dir)
    }
    fn codex_executable_path(&self) -> Result<PathBuf> {
        if let Some(path) = self.codex_executable.borrow().clone() { return Ok(path); }
        crate::agy::resolve_named_executable(
            "codex",
            std::env::var_os("PATH").as_deref(),
            std::env::var_os("HOME").as_deref().map(Path::new),
        )
    }
    /// Read-only supported discovery: `codex --version` then
    /// `codex debug models`, pinned to this session's CODEX_HOME, bounded in
    /// time and output. Returns the installed version with the catalog.
    fn codex_discover(&self) -> std::result::Result<(String, Vec<model_control::CodexCatalogModel>), &'static str> {
        let executable = self.codex_executable_path()?;
        let home = self.codex_home_dir();
        let deadline = Instant::now() + crate::agy::CATALOG_TIMEOUT;
        let map = |code: &'static str| match code {
            "agy_timeout" => "timeout",
            "agy_unavailable" => "codex_unavailable",
            "agy_catalog_invalid" => "codex_catalog_invalid",
            other => other,
        };
        let version = crate::agy::run_bounded(&executable, &["--version"], home.as_deref(), deadline, 4096).map_err(map)?;
        let version = model_control::parse_codex_version(&version).ok_or("codex_catalog_invalid")?;
        let text = crate::agy::run_bounded(&executable, &["debug", "models"], home.as_deref(), deadline, CODEX_CATALOG_MAX_BYTES).map_err(map)?;
        let models = model_control::parse_codex_catalog_checked(&text).map_err(|e| e.code())?;
        Ok((version, models))
    }
    /// `discover` permits a bounded CLI refresh when the cache is missing,
    /// stale, corrupt, or from another CLI version. Failure never discards a
    /// readable cache; the view says it is cached and why.
    fn codex_catalog_view(&self, discover: bool) -> CodexCatalogView {
        let cache = self.codex_home_dir().and_then(|home| std::fs::read_to_string(home.join("models_cache.json")).ok());
        let meta = cache.as_deref().map(model_control::parse_codex_catalog_meta).unwrap_or_default();
        let parsed = match cache.as_deref() {
            Some(text) => model_control::parse_codex_catalog_checked(text).map_err(|e| e.code()),
            None => Err("codex_catalog_missing"),
        };
        let from_cache = |fresh: bool, error: Option<&'static str>| {
            if let Some((_, models)) = self.codex_catalog_cache.borrow().as_ref() {
                return CodexCatalogView {
                    models: models.clone(),
                    source: "cache",
                    fresh,
                    fetched_at: None,
                    cli_version: None,
                    error,
                };
            }
            match &parsed {
                Ok(models) => CodexCatalogView { models: models.clone(), source: "cache", fresh, fetched_at: meta.fetched_at.clone(), cli_version: meta.client_version.clone(), error },
                Err(code) => CodexCatalogView { models: Vec::new(), source: "unavailable", fresh: false, fetched_at: None, cli_version: None, error: Some(error.unwrap_or(code)) },
            }
        };
        // Expiry only permits a refresh; lookups that don't discover keep the
        // last successful catalog so labels and efforts of rows already shown
        // stay available to `set_codex_model` and footer scans.
        if let Some((at, models)) = self.codex_catalog_cache.borrow().as_ref()
            && (!discover || at.elapsed() < CODEX_REFRESH_OK_TTL)
        {
            return CodexCatalogView { models: models.clone(), source: "refreshed", fresh: true, fetched_at: None, cli_version: None, error: None };
        }
        if !discover { return from_cache(false, None); }
        if let Some((at, code)) = *self.codex_catalog_error.borrow()
            && at.elapsed() < CODEX_REFRESH_FAIL_TTL
        {
            return from_cache(false, Some(code));
        }
        match self.codex_discover() {
            Ok((version, models)) => {
                // The live result is authoritative and is exactly what stays
                // remembered, so later label/effort lookups match what iOS was
                // shown. A disk cache is only a fallback when discovery fails.
                *self.codex_catalog_cache.borrow_mut() = Some((Instant::now(), models.clone()));
                *self.codex_catalog_error.borrow_mut() = None;
                CodexCatalogView { models, source: "refreshed", fresh: true, fetched_at: None, cli_version: Some(version), error: None }
            }
            Err(code) => {
                *self.codex_catalog_error.borrow_mut() = Some((Instant::now(), code));
                from_cache(false, Some(code))
            }
        }
    }
    /// Fresh occupant check shared by both model methods: returns the live
    /// pane and the adapter-verified transcript for the watched identity.
    fn model_pane_file(&self, identity: &Identity) -> Result<(Pane, std::fs::File)> {
        let snapshot = self.client.snapshot().map_err(|_| "stale")?;
        let pane = snapshot
            .panes
            .iter()
            .find(|p| p.pane_id == identity.pane_id)
            .ok_or("stale")?
            .clone();
        if pane.terminal_id != identity.terminal_id
            || !pane.agent.as_deref().is_some_and(|agent| self.adapter_for(agent).is_some_and(|a| a.name() == identity.agent))
        {
            return Err("stale");
        }
        let adapter = self
            .adapter_for(&identity.agent)
            .ok_or("unsupported_agent")?;
        let (session, file) = adapter.resolve_and_open(&pane).map_err(|_| "stale")?;
        if session != identity.native_session_id {
            return Err("stale");
        }
        Ok((pane, file))
    }
    fn model_status(&mut self) -> Result<Value> {
        if !self.include_model_control {
            return Err("unsupported_capability");
        }
        let watch = self.watch.as_ref().ok_or("not_watching")?;
        let identity = watch
            .identity
            .clone()
            .filter(|_| watch.unavailable.is_none())
            .ok_or("timeline_unavailable")?;
        if identity.agent == "cursor" {
            return self.cursor_model_status(&identity);
        }
        let (pane, file) = self.model_pane_file(&identity)?;
        self.agy_require_no_pending(&identity, file.try_clone().map_err(|_|"stale")?)?;
        let agent = identity.agent.as_str();
        let codex_view = (agent == "codex").then(|| self.codex_catalog_view(true));
        let current = self.model_scan_current(agent, &pane, file);
        let current_id = current.as_ref().map(|(id, _)| id.as_str());
        let catalog_info;
        let (models, efforts) = match agent {
            "claude" => {
                // Claude Code 2.1.x has no structured model-listing command, so
                // these maintained tier aliases are an explicit fallback, not a
                // verified account catalog. Aliases carry no version label.
                catalog_info = json!({
                    "source":"fallback", "fresh":false, "complete":false,
                    "fetchedAt":Value::Null, "cliVersion":Value::Null, "error":Value::Null,
                });
                let default = model_control::CLAUDE_DEFAULT_MODEL;
                let mut models: Vec<Value> = std::iter::once(&(default, ""))
                    .chain(model_control::CLAUDE_MODELS.iter())
                    .map(|(alias, _)| json!({"id":alias,"label":model_control::claude_model_label(alias)}))
                    .collect();
                // Current matching is exact only: no assumption about which
                // version an alias resolves to. The observed id always keeps
                // its own checked row, including older or custom ids.
                let mut marked = false;
                for entry in &mut models {
                    if entry["id"].as_str().is_some_and(|alias| current_id == Some(alias)) {
                        entry["current"] = json!(true);
                        marked = true;
                    }
                }
                if !marked && let Some(id) = current_id {
                    models.push(json!({"id":id,"label":model_control::claude_display_label(id),"current":true,"observedOnly":true}));
                }
                let efforts = model_control::CLAUDE_EFFORTS
                    .iter()
                    .map(|effort| json!({"id":effort,"label":model_control::effort_label(effort)}))
                    .collect::<Vec<_>>();
                for entry in &mut models {
                    entry["efforts"] = json!(efforts);
                }
                (models, efforts)
            }
            "antigravity_cli" => {
                let catalog = self.agy_catalog()?;
                catalog_info = json!({"source":"cli","fresh":true,"complete":true,"fetchedAt":Value::Null,"cliVersion":Value::Null,"error":Value::Null});
                let models = model_control::agy_model_values(&catalog, current_id);
                let efforts = current_id.map(|id| model_control::agy_model_value(id, &catalog)["efforts"].as_array().cloned().unwrap_or_default()).unwrap_or_default();
                (models, efforts)
            }
            "codex" => {
                let view = codex_view.expect("codex view computed");
                let catalog = view.models.clone();
                catalog_info = json!({
                    "source":view.source, "fresh":view.fresh,
                    // Only a verified live/fresh catalog is a complete list.
                    "complete":view.fresh && !catalog.is_empty(),
                    "fetchedAt":view.fetched_at, "cliVersion":view.cli_version,
                    "error":view.error,
                });
                let fallback = model_control::CODEX_EFFORTS
                    .iter()
                    .map(|effort| json!({"id":effort,"label":model_control::effort_label(effort)}))
                    .collect::<Vec<_>>();
                let mut models: Vec<Value> = catalog
                    .iter()
                    .map(|model| {
                        let efforts: Vec<Value> = model
                            .efforts
                            .iter()
                            .map(|effort| {
                                json!({"id":effort,"label":model_control::effort_label(effort)})
                            })
                            .collect();
                        let mut entry = json!({"id":model.slug,"label":model.label,"efforts":efforts});
                        if !model.unsupported_efforts.is_empty() {
                            entry["unsupportedEfforts"] = json!(model.unsupported_efforts);
                        }
                        entry
                    })
                    .collect();
                let mut marked = false;
                for entry in &mut models {
                    if entry["id"].as_str() == current_id {
                        entry["current"] = json!(true);
                        marked = true;
                    }
                }
                if !marked && let Some(id) = current_id {
                    models.push(
                        json!({"id":id,"label":model_control::codex_slug_label(id),"current":true,"observedOnly":true,"efforts":fallback}),
                    );
                }
                let efforts: Vec<Value> = models
                    .iter()
                    .find(|entry| entry["current"] == true)
                    .and_then(|entry| entry["efforts"].as_array().cloned())
                    .unwrap_or_else(|| fallback.clone());
                (models, efforts)
            }
            _ => return Err("unsupported_agent"),
        };
        let confirmed_label = self
            .watch
            .as_ref()
            .and_then(|watch| watch.model_override.as_ref())
            .and_then(|value| value.label_for(&current));
        let current_label = confirmed_label.or_else(|| {
            current.as_ref().map(|(id, _)| match agent {
                "claude" => model_control::claude_display_label(id),
                "antigravity_cli" => self.agy_catalog().ok().and_then(|catalog| catalog.iter().find(|m| m.id == *id).map(|m|m.label.clone())).unwrap_or_else(||id.clone()),
                _ => self
                    .codex_catalog()
                    .iter()
                    .find(|model| model.slug == *id)
                    .map(|model| model.label.clone())
                    .unwrap_or_else(|| model_control::codex_slug_label(id)),
            })
        });
        Ok(json!({
            "identity":identity, "generation":self.generation, "agent":agent,
            "model": current.as_ref().and_then(|(id, _)| {
                if agent == "antigravity_cli" {
                    Some(model_control::agy_model_value(id, &self.agy_catalog().ok()?))
                } else { current_label.clone().map(|label| json!({"id":id, "label":label})) }
            }),
            "effort": current.as_ref().and_then(|(_, effort)| effort.clone()),
            "models":models, "efforts":efforts, "catalog":catalog_info,
        }))
    }
    fn model_set(&mut self, params: &Value) -> Result<Value> {
        if !self.include_model_control {
            return Err("unsupported_capability");
        }
        let watch = self.watch.as_ref().ok_or("not_watching")?;
        let identity = watch
            .identity
            .clone()
            .filter(|_| watch.unavailable.is_none())
            .ok_or("timeline_unavailable")?;
        if identity.agent == "cursor" {
            return self.cursor_model_set(&identity, params);
        }
        let agent = identity.agent.as_str();
        if agent=="antigravity_cli" && (params["expect"]["identity"]!=serde_json::to_value(&identity).map_err(|_|"stale")? || params["expect"]["generation"].as_u64()!=Some(self.generation)) {return Err("stale");}
        let target_model = params["model"].as_str();
        let target_effort = params["effort"].as_str();
        model_control::valid_set_target(if agent=="antigravity_cli" {"agy"} else {agent}, target_model, target_effort)?;
        if !params["expect"].is_object() {
            return Err("invalid_request");
        }
        let expect_model = params["expect"]["model"].as_str();
        let expect_effort = params["expect"]["effort"].as_str();
        let (pane, file) = self.model_pane_file(&identity)?;
        self.agy_require_no_pending(&identity, file.try_clone().map_err(|_|"stale")?)?;
        if !matches!(pane.agent_status.as_str(), "idle" | "done") {
            return Err("agent_busy");
        }
        let scanned_at_set = self.model_scan_raw(agent, &pane, file);
        let current = self.resolve_model_scan(scanned_at_set.clone());
        let current_id = current.as_ref().map(|(id, _)| id.as_str());
        let model_matches = if agent == "antigravity_cli" {
            model_control::agy_expect_matches(current_id, expect_model, &self.agy_catalog()?)
        } else { current_id == expect_model };
        if !model_matches
            || current.as_ref().and_then(|(_, effort)| effort.as_deref()) != expect_effort
        {
            return Err("stale");
        }
        let result = match agent {
            "claude" => self.set_claude_model(&identity, &current, target_model, target_effort)?,
            "codex" => self.set_codex_model(&identity, &current, target_model, target_effort)?,
            "antigravity_cli" => self.set_agy_model(&identity, &current, target_model, target_effort)?,
            _ => return Err("unsupported_agent"),
        };
        // Force the next poll to re-scan and emit `model.updated` for the new
        // pair (the confirmation may never reach the transcript).
        if let Some(watch) = self.watch.as_mut() {
            watch.model_stamp = None;
            let applied = result["applied"]["model"]["id"].as_str().map(|id| {
                (
                    id.to_owned(),
                    result["applied"]["effort"].as_str().map(str::to_owned),
                )
            });
            if result["confirmed"] == true || applied != current {
                watch.model_override = Some(ModelOverride {
                    applied,
                    applied_label: result["applied"]["model"]["label"]
                        .as_str()
                        .map(str::to_owned),
                    scanned_at_set,
                });
            }
        }
        // Overrides, scans, footer checks and acknowledgements stay native.
        // Project only after the authoritative raw result has been recorded.
        let mut result = result;
        if agent == "antigravity_cli" && let Some(id) = result["applied"]["model"]["id"].as_str() {
            result["applied"]["model"] = model_control::agy_model_value(id, &self.agy_catalog()?);
        }
        Ok(result)
    }
    fn pi_action(&self, method: &str, params: &Value) -> Result<Value> {
        let watch = self.watch.as_ref().ok_or("not_watching")?;
        let identity = watch.identity.as_ref().filter(|i| i.agent == "pi").ok_or("unsupported_agent")?;
        if params["pane_id"].as_str() != Some(identity.pane_id.as_str())
            || params["expect"]["identity"] != serde_json::to_value(identity).map_err(|_|"stale")?
            || params["expect"]["generation"].as_u64() != Some(self.generation)
        { return Err("stale"); }
        let state = watch.pi_state.as_ref().ok_or("pi_extension_unavailable")?;
        if !matches!(method,"prompt"|"cancel"|"dialog.respond"|"model.set") { return Err("unsupported_capability"); }
        if method == "model.set"
            && (params["expect"]["model"] != state["model"]["id"]
                || params["expect"]["effort"] != state["model"]["effort"])
        { return Err("stale"); }
        let snapshot = self.client.snapshot().map_err(|_| "stale")?;
        let pane = snapshot.panes.iter().find(|p| p.pane_id == identity.pane_id).ok_or("stale")?;
        if pane.terminal_id != identity.terminal_id || pane.agent.as_deref() != Some("pi") { return Err("stale"); }
        let adapter = self.adapter_for("pi").ok_or("stale")?;
        let (session, _, path) = adapter.resolve_pi_live(pane).map_err(|_| "stale")?;
        if session != identity.native_session_id || state["session_file"].as_str() != path.to_str() { return Err("stale"); }
        let mut extension_params = params.clone();
        extension_params.as_object_mut().ok_or("invalid_request")?.remove("pane_id");
        extension_params.as_object_mut().unwrap().remove("expect");
        extension_params["expect"] = json!({"session_id":identity.native_session_id,
            "instance_id":identity.native_instance_id,"revision":state["revision"]});
        let result = self.pi_request(&identity.native_session_id, method, extension_params)?;
        // Earlier loaded Pi runtimes acknowledge model.set with applied:true
        // only, after verifying the native model/thinking pair. Accept that
        // schema only when it describes the requested result; never resend.
        let legacy_model_applied = method == "model.set"
            && result.get("confirmed").is_none()
            && result["applied"] == true
            && result["model"]["id"].as_str().is_some()
            && result["model"]["id"].as_str()
                == params["model"].as_str().or(state["model"]["id"].as_str())
            && result["model"]["effort"].is_string()
            && params["effort"].as_str().is_none_or(|effort|
                result["model"]["effort"].as_str() == Some(effort));
        if result["confirmed"] != true && result["accepted"] != true && !legacy_model_applied {
            return Err("unconfirmed");
        }
        let mut result=result;
        result["confirmed"]=json!(true);
        if let Some(request_id)=params["request_id"].as_str(){result["request_id"]=json!(request_id);}
        if method=="model.set" {
            // Model controls validate the same session envelope as model.status.
            result["identity"] = serde_json::to_value(identity).map_err(|_| "invalid_pi_response")?;
            result["generation"] = json!(self.generation);
            let model=result["model"].clone();
            let effort=model["effort"].clone();
            result["applied"]=json!({"model":model,"effort":effort});
        }
        Ok(result)
    }
    /// Decline only a currently visible cache-switch dialog on the same idle occupant.
    fn decline_claude_switch(&self, identity: &Identity) {
        if self.recheck_idle(identity).is_err() {
            return;
        }
        let Ok(screen) = self.client.read_visible(&identity.pane_id) else {
            return;
        };
        if model_control::claude_switch_dialog(&screen).is_some_and(|dialog| dialog.can_decline()) {
            let _ = self.client.send_keys(&identity.pane_id, &["2"]);
        }
    }
    /// Wait for a direct result or accept the matching cache-switch dialog once.
    /// Result lines must follow the submitted command and differ from the baseline.
    fn wait_claude_confirmation(
        &self,
        identity: &Identity,
        baseline: &str,
        command: &str,
        want_effort: Option<&str>,
    ) -> (Option<String>, Option<&'static str>) {
        let pane_id = &identity.pane_id;
        let mut baseline = baseline.to_owned();
        let mut deadline = Instant::now() + Duration::from_secs(4);
        let mut accepted = false;
        let want_model = want_effort
            .is_none()
            .then(|| command.trim_start_matches("/model "));
        loop {
            let screen = self.client.read_visible(pane_id).unwrap_or_default();
            if screen != baseline {
                if let Some(dialog) = model_control::claude_switch_dialog(&screen) {
                    if !dialog.matches(want_model, want_effort) {
                        self.decline_claude_switch(identity);
                        return (None, Some("picker_mismatch"));
                    }
                    if !accepted {
                        if self.recheck_idle(identity).is_err() {
                            return (None, Some("stale"));
                        }
                        // A fresh read must still show exactly the verified dialog.
                        let fresh = self.client.read_visible(pane_id).unwrap_or_default();
                        if model_control::claude_switch_dialog(&fresh).as_ref() == Some(&dialog) {
                            if self.client.send_keys(pane_id, &["1"]).is_err() {
                                return (None, Some("herdr_unavailable"));
                            }
                            accepted = true;
                            baseline = fresh;
                            deadline = Instant::now() + Duration::from_secs(4);
                        }
                    }
                } else if let Some((_, outcome)) = screen.rsplit_once(command) {
                    match model_control::claude_confirmation(outcome) {
                        // A desk-side /model after ours can be the newest line;
                        // accept only a confirmation naming the requested model.
                        Some(ClaudeConfirmation::Model(label)) if want_effort.is_none() => {
                            let wanted = want_model.unwrap_or_default();
                            if !model_control::claude_label_names(&label, wanted) {
                                return (None, Some("stale"));
                            }
                            return (Some(label), None);
                        }
                        Some(ClaudeConfirmation::Effort(level))
                            if want_effort.is_some_and(|wanted| level == wanted) =>
                        {
                            return (Some(level), None);
                        }
                        Some(ClaudeConfirmation::Kept) => return (None, Some("change_declined")),
                        Some(ClaudeConfirmation::Invalid(payload)) => {
                            let expected_invalid = match want_effort {
                                None => payload.contains(command.trim_start_matches("/model ")),
                                Some(wanted) => payload == wanted,
                            };
                            if expected_invalid {
                                return (
                                    None,
                                    Some(if want_effort.is_none() {
                                        "unknown_model"
                                    } else {
                                        "invalid_effort"
                                    }),
                                );
                            }
                        }
                        _ => {}
                    }
                }
            }
            if Instant::now() >= deadline {
                self.decline_claude_switch(identity);
                return (None, Some("confirm_timeout"));
            }
            thread::sleep(Duration::from_millis(150));
        }
    }
    /// Proves the agent's composer is empty before submitting a prompt through
    /// `agent.prompt`, which would otherwise append to a desk-side draft.
    /// Fails closed: an unreadable or unparsable screen refuses the send.
    fn composer_clear(&self, identity: &Identity, agent: &str) -> Result<()> {
        if identity.agent == "antigravity_cli" { self.recheck_idle(identity)?; }
        self.composer_empty(&identity.pane_id, agent)?;
        // Re-verify the occupant last, immediately before the caller's prompt,
        // so a pane replaced after the composer read never receives it.
        self.recheck_idle(identity)
    }
    fn composer_empty(&self, pane_id: &str, agent: &str) -> Result<()> {
        let screen = self
            .client
            .read_visible(pane_id)
            .map_err(|_| "composer_not_empty")?;
        let composer = if matches!(agent, "agy" | "antigravity_cli") {
            model_control::agy_composer_state(&screen, &self.agy_catalog()?)
        } else { model_control::composer_state(agent, &screen) };
        match composer {
            model_control::Composer::Empty => Ok(()),
            // Placeholder-shaped text may be the user's draft: accept it only
            // when the styled screen shows it faint, as idle suggestions are.
            model_control::Composer::Placeholder(text) => {
                let styled = self
                    .client
                    .read_visible_ansi(pane_id)
                    .map_err(|_| "composer_not_empty")?;
                if model_control::placeholder_is_faint(agent, &styled, &text) {
                    Ok(())
                } else {
                    Err("composer_not_empty")
                }
            }
            _ => Err("composer_not_empty"),
        }
    }
    /// Occupant and idle/done re-verification before every keystroke batch.
    /// Mid-flow failures map to `stale`, matching `interaction.respond`.
    fn recheck_idle(&self, identity: &Identity) -> Result<()> {
        let (pane, file) = self.model_pane_file(identity)?;
        self.agy_require_no_pending(identity, file)?;
        if !matches!(pane.agent_status.as_str(), "idle" | "done") {
            return Err("stale");
        }
        Ok(())
    }
    fn set_claude_model(
        &self,
        identity: &Identity,
        current: &Option<(String, Option<String>)>,
        target_model: Option<&str>,
        target_effort: Option<&str>,
    ) -> Result<Value> {
        let pane_id = identity.pane_id.as_str();
        let mut applied_model = current.clone().map(|(id, _)| {
            let label = self
                .watch
                .as_ref()
                .and_then(|watch| watch.model_override.as_ref())
                .and_then(|value| value.label_for(current))
                .unwrap_or_else(|| model_control::claude_display_label(&id));
            (id, label)
        });
        let mut applied_effort = current.as_ref().and_then(|(_, effort)| effort.clone());
        let mut error: Option<&str> = None;
        if let Some(target) = target_model
            // Only the exact observed id is unchanged. An alias (`opus`) may
            // now resolve to a newer model than the one running, so it is
            // sent; no maintained alias-version table decides otherwise.
            .filter(|target| !current.as_ref().is_some_and(|(id, _)| id == target))
        {
            let command = format!("/model {target}");
            self.composer_clear(identity, "claude")?;
            let baseline = self.client.read_visible(pane_id).unwrap_or_default();
            self.client
                .agent_prompt(pane_id, &command)
                .map_err(|_| "herdr_unavailable")?;
            let (label, failure) =
                self.wait_claude_confirmation(identity, &baseline, &command, None);
            match (label, failure) {
                (Some(label), _) => applied_model = Some((target.to_owned(), label)),
                (None, Some(code)) => error = Some(code),
                (None, None) => error = Some("confirm_timeout"),
            }
        }
        if error.is_none()
            && let Some(target) = target_effort.filter(|target| {
                Some(*target) != current.as_ref().and_then(|(_, effort)| effort.as_deref())
            })
        {
            let command = format!("/effort {target}");
            // Re-verify occupant and status, then the composer, before the
            // second command; failures keep the applied model step.
            if let Err(code) = self
                .recheck_idle(identity)
                .and_then(|()| self.composer_clear(identity, "claude"))
            {
                error = Some(if code == "composer_not_empty" {
                    code
                } else {
                    "stale"
                });
            } else {
                let baseline = self.client.read_visible(pane_id).unwrap_or_default();
                self.client
                    .agent_prompt(pane_id, &command)
                    .map_err(|_| "herdr_unavailable")?;
                let (level, failure) =
                    self.wait_claude_confirmation(identity, &baseline, &command, Some(target));
                match (level, failure) {
                    (Some(level), _) => applied_effort = Some(level),
                    (None, Some(code)) => error = Some(code),
                    (None, None) => error = Some("confirm_timeout"),
                }
            }
        }
        Ok(json!({
            "identity":identity, "generation":self.generation,
            "applied":{
                "model": applied_model.map(|(id, label)| json!({"id":id,"label":label})),
                "effort": applied_effort,
            },
            "confirmed": error.is_none(), "error": error,
        }))
    }
    /// Never send Escape into the composer: Esc-Esc opens Codex's rewind UI.
    /// An unchanged render cannot authorize another key after the first Escape.
    fn dismiss_codex_picker(&self, identity: &Identity) {
        let pane_id = identity.pane_id.as_str();
        for _ in 0..3 {
            // Never send Escape into a replacement occupant: the pane id can be
            // reused by another terminal or session that has its own picker open.
            if self.model_pane_file(identity).is_err() {
                return;
            }
            let Ok(screen) = self.client.read_visible(pane_id) else {
                return;
            };
            let before = model_control::parse_codex_screen(&screen);
            if before.is_composer() || before.rows().is_empty() {
                return;
            }
            if self.client.send_keys(pane_id, &["esc"]).is_err() {
                return;
            }
            let deadline = Instant::now() + Duration::from_millis(1500);
            loop {
                thread::sleep(Duration::from_millis(150));
                let Ok(screen) = self.client.read_visible(pane_id) else {
                    return;
                };
                let after = model_control::parse_codex_screen(&screen);
                if after.is_composer() || after.rows().is_empty() {
                    return;
                }
                if std::mem::discriminant(&after) != std::mem::discriminant(&before) {
                    break;
                }
                if Instant::now() >= deadline {
                    return;
                }
            }
        }
    }
    fn wait_codex_kind(
        &self,
        pane_id: &str,
        matches: impl Fn(&PickerScreen) -> bool,
    ) -> Option<PickerScreen> {
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let screen = self.client.read_visible(pane_id).unwrap_or_default();
            let parsed = model_control::parse_codex_screen(&screen);
            if matches(&parsed) {
                return Some(parsed);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(150));
        }
    }
    fn wait_codex_toast(
        &self,
        pane_id: &str,
        baseline: &str,
        slug: &str,
        effort: Option<&str>,
    ) -> Option<(String, String)> {
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let screen = self.client.read_visible(pane_id).unwrap_or_default();
            if let Some(applied) =
                model_control::codex_fresh_change(&screen, baseline, slug, effort)
            {
                return Some(applied);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(150));
        }
    }
    /// Re-reads the picker and confirms the expected screen with its cursor on
    /// `target` (or on any row when `target` is None).
    fn verify_cursor(&self, pane_id: &str, expected: &PickerScreen, target: Option<usize>) -> bool {
        let deadline = Instant::now() + Duration::from_millis(1500);
        loop {
            let matches = || -> bool {
                let Ok(screen) = self.client.read_visible(pane_id) else {
                    return false;
                };
                let parsed = model_control::parse_codex_screen(&screen);
                match (expected, &parsed) {
                    (PickerScreen::ModelList(_), PickerScreen::ModelList(_))
                    | (PickerScreen::Advanced(_), PickerScreen::Advanced(_)) => {}
                    (
                        PickerScreen::EffortList {
                            model_label: expected,
                            ..
                        },
                        PickerScreen::EffortList {
                            model_label: actual,
                            ..
                        },
                    ) if model_control::picker_label(expected)
                        .eq_ignore_ascii_case(model_control::picker_label(actual)) => {}
                    _ => return false,
                }
                if !expected.rows().iter().zip(parsed.rows()).all(|(a, b)| {
                    a.number == b.number
                        && model_control::picker_label(&a.label)
                            .eq_ignore_ascii_case(model_control::picker_label(&b.label))
                }) || expected.rows().len() != parsed.rows().len()
                {
                    return false;
                }
                match target {
                    Some(target) => parsed.cursor() == Some(target),
                    None => parsed.cursor().is_some(),
                }
            };
            if matches() {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(Duration::from_millis(150));
        }
    }

    fn set_codex_model(
        &self,
        identity: &Identity,
        current: &Option<(String, Option<String>)>,
        target_model: Option<&str>,
        target_effort: Option<&str>,
    ) -> Result<Value> {
        let pane_id = identity.pane_id.as_str();
        let current_slug = current.as_ref().map(|(id, _)| id.as_str());
        let target_slug = target_model.or(current_slug).ok_or("invalid_request")?;
        let catalog = self.codex_catalog();
        let label_for = |slug: &str| {
            catalog
                .iter()
                .find(|model| model.slug == slug)
                .map(|model| model.label.clone())
                .unwrap_or_else(|| model_control::codex_slug_label(slug))
        };
        // Reselecting the current model, with no effort or the current one, is
        // a no-op: walking the picker would apply its default row (replacing an
        // effort it can't show, like minimal), and an identical toast can't
        // confirm anything.
        let current_effort = current.as_ref().and_then(|(_, effort)| effort.as_deref());
        if Some(target_slug) == current_slug
            && target_effort.is_none_or(|effort| Some(effort) == current_effort)
        {
            return Ok(json!({
                "identity":identity, "generation":self.generation,
                "applied":{
                    "model":{"id":target_slug,"label":label_for(target_slug)},
                    "effort": current.as_ref().and_then(|(_, effort)| effort.clone()),
                },
                "confirmed": true, "error": null,
            }));
        }
        let target_label = label_for(target_slug);
        let mismatch = || -> &'static str {
            self.dismiss_codex_picker(identity);
            "picker_mismatch"
        };
        // Mid-flow occupant/status failures dismiss the open picker first.
        let stale = || -> &'static str {
            self.dismiss_codex_picker(identity);
            "stale"
        };
        let send = |keys: &[&str]| -> Result<()> {
            self.recheck_idle(identity).map_err(|_| stale())?;
            self.client
                .send_keys(pane_id, keys)
                .map_err(|_| "herdr_unavailable")
        };
        // Re-verify occupant, arrows to `target`, verify the landed cursor,
        // and re-verify again — every keystroke batch is bracketed.
        let walk = |screen: &PickerScreen, target: usize| -> Result<()> {
            self.recheck_idle(identity).map_err(|_| stale())?;
            for arrow in screen.arrow_plan(target).ok_or_else(mismatch)? {
                send(&[arrow])?;
            }
            if !self.verify_cursor(pane_id, screen, Some(target)) {
                return Err(mismatch());
            }
            self.recheck_idle(identity).map_err(|_| stale())?;
            Ok(())
        };

        self.composer_clear(identity, "codex")?;
        self.client
            .agent_prompt(pane_id, "/model")
            .map_err(|_| "herdr_unavailable")?;
        let model_list = self
            .wait_codex_kind(
                pane_id,
                |screen| matches!(screen, PickerScreen::ModelList(rows) if !rows.is_empty()),
            )
            .ok_or_else(mismatch)?;
        let PickerScreen::ModelList(_) = &model_list else {
            return Err(mismatch());
        };
        // Enter on the model row only advances to the effort step; it never
        // persists anything (verified against the isolated picker).
        let target_row = model_list
            .row_for_label(&target_label)
            .ok_or_else(mismatch)?;
        walk(&model_list, target_row)?;
        send(&["enter"])?;

        let effort_screen = self
            .wait_codex_kind(pane_id, |screen| {
                matches!(screen, PickerScreen::EffortList { model_label, rows }
                    if !rows.is_empty() && model_control::picker_label(model_label).eq_ignore_ascii_case(model_control::picker_label(&target_label)))
            })
            .ok_or_else(mismatch)?;
        let PickerScreen::EffortList { rows, .. } = &effort_screen else {
            return Err(mismatch());
        };

        // Re-picking the current effort still applies cleanly, but only when
        // the target model offers it; otherwise the target's default cursor
        // position applies (a model switch must not fail on a carried effort).
        let carried = current
            .as_ref()
            .and_then(|(_, effort)| effort.clone())
            .filter(|effort| match catalog.iter().find(|model| model.slug == target_slug) {
                Some(model) => model.efforts.iter().any(|offered| offered == effort),
                None => model_control::codex_effort_row_label(effort).is_some_and(|label| {
                    rows.iter().any(|row| {
                        model_control::picker_label(&row.label).starts_with(label)
                    })
                }),
            });
        if let Some(effort) = target_effort.map(str::to_owned).or(carried) {
            let row_label =
                model_control::codex_effort_row_label(&effort).ok_or_else(mismatch)?;
            if row_label.starts_with("More reasoning") {
                let index = rows
                    .iter()
                    .position(|row| {
                        model_control::picker_label(&row.label).starts_with("More reasoning")
                    })
                    .ok_or_else(mismatch)?;
                walk(&effort_screen, index)?;
                send(&["enter"])?;
                let advanced = self
                    .wait_codex_kind(
                        pane_id,
                        |screen| matches!(screen, PickerScreen::Advanced(rows) if !rows.is_empty()),
                    )
                    .ok_or_else(mismatch)?;
                let PickerScreen::Advanced(_) = &advanced else {
                    return Err(mismatch());
                };
                let label = model_control::effort_label(&effort);
                let index = advanced.row_for_label(label).ok_or_else(mismatch)?;
                walk(&advanced, index)?;
            } else {
                let index = effort_screen
                    .row_for_label(row_label)
                    .ok_or_else(mismatch)?;
                walk(&effort_screen, index)?;
            }
        } else {
            // No desired effort: any selected default row applies.
            if !self.verify_cursor(pane_id, &effort_screen, None) {
                return Err(mismatch());
            }
            self.recheck_idle(identity).map_err(|_| stale())?;
        }
        // `s` applies for this session only; digits or enter would persist a
        // new global default in config.toml.
        let baseline = self.client.read_visible(pane_id).map_err(|_| mismatch())?;
        send(&["s"])?;

        let Some((applied_slug, applied_effort)) =
            self.wait_codex_toast(pane_id, &baseline, target_slug, target_effort)
        else {
            self.dismiss_codex_picker(identity);
            return Err("confirm_timeout");
        };
        let applied_label = if applied_slug == target_slug {
            target_label
        } else {
            model_control::codex_slug_label(&applied_slug)
        };
        Ok(json!({
            "identity":identity, "generation":self.generation,
            "applied":{
                "model":{"id":applied_slug,"label":applied_label},
                "effort":applied_effort,
            },
            "confirmed":true, "error":null,
        }))
    }
    fn respond_interaction(&self, params: &Value) -> InteractionResult<Value> {
        let question_response = params.get("answers").is_some() || params.get("skip").is_some();
        if (!self.include_approvals && !self.include_questions) || (question_response && !self.include_questions) {
            return Err("unsupported_capability".into());
        }
        let watch = self.watch.as_ref().ok_or("not_watching")?;
        let identity = watch.identity.as_ref().filter(|_| watch.unavailable.is_none())
            .ok_or("timeline_unavailable")?;
        match watch.pending.as_ref().ok_or("stale")? {
            PendingInteraction::Approval(pending) => {
                if !self.include_approvals { return Err("unsupported_capability".into()); }
                if params["request_id"].as_str() != Some(&pending.request.request_id)
                    || pending.identity != *identity || pending.generation != self.generation {
                    return Err("stale".into());
                }
                if question_response { return Err("mismatch".into()); }
                self.respond_approval(params, watch, identity, pending).map_err(Into::into)
            }
            PendingInteraction::Question(pending) => {
                if !self.include_questions { return Err("unsupported_capability".into()); }
                if params["request_id"].as_str() != Some(&pending.request.request_id)
                    || pending.identity != *identity || pending.generation != self.generation {
                    return Err("stale".into());
                }
                self.respond_question(params, watch, identity, pending)
            }
        }
    }
    fn respond_approval(&self, params: &Value, watch: &Watch, identity: &Identity, pending: &PendingApproval) -> Result<Value> {
        let command = pending.request.tool_input["command"].as_str().ok_or("stale")?;
        let screen = self.client.read_visible(&identity.pane_id).map_err(|_| "stale")?;
        let current = approval_screen::parse(pending.request.agent, &screen, command).ok_or("stale")?;
        if !pending.dialog.same_dialog(&current) {
            return Err("stale");
        }
        let key = pending.response_key(params)?;

        // Reopen through the adapter using the last verified pane reference.
        // A response always bypasses the polling cache and rechecks both files.
        let source = watch.source_pane.as_ref().ok_or("stale")?;
        let adapter = self.adapter_for(&identity.agent).ok_or("stale")?;
        let (session, file) = adapter.resolve_and_open(source).map_err(|_| "stale")?;
        if session != identity.native_session_id {
            return Err("stale");
        }
        let newest = self.matched_request(identity, file, &mut None, crate::follower::read_tail)
            .ok_or("stale")?;
        if newest.request_id != pending.request.request_id
            || newest.tool_name != pending.request.tool_name
            || newest.tool_input != pending.request.tool_input
            || newest.turn_id != pending.request.turn_id
        {
            return Err("stale");
        }

        // Verify the live occupant as well as blocked status immediately before
        // sending. The adapter validates the fresh session reference and cwd.
        let snapshot = self.client.snapshot().map_err(|_| "stale")?;
        let pane = snapshot.panes.iter().find(|p| p.pane_id == identity.pane_id)
            .ok_or("stale")?;
        if (identity.agent != "antigravity_cli" && pane.agent_status != "blocked") || pane.terminal_id != identity.terminal_id
            || !pane.agent.as_deref().is_some_and(|agent| self.adapter_for(agent).is_some_and(|a| a.name() == identity.agent))
        {
            return Err("stale");
        }
        let (session, _) = adapter.resolve_and_open(pane).map_err(|_| "stale")?;
        if session != identity.native_session_id {
            return Err("stale");
        }
        let navigated = matches!(pending.request.agent, Agent::Agy | Agent::Cursor);
        let target = params["option"].as_u64().and_then(|n| n.checked_sub(1)).unwrap_or(usize::MAX as u64) as usize;
        if navigated {
            let plan = approval_screen::agy_plan(&current, target).ok_or("mismatch")?;
            let mut expected = current.selected;
            for (key, after) in plan {
                let file = self.question_pane_file(identity)?;
                watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?)?;
                let newest = self.matched_request(identity, file, &mut None, crate::follower::read_tail).ok_or("stale")?;
                if newest != pending.request { return Err("stale"); }
                let screen = self.client.read_visible(&identity.pane_id).map_err(|_|"stale")?;
                let dialog = approval_screen::parse(pending.request.agent, &screen, command).ok_or("stale")?;
                if !pending.dialog.same_dialog(&dialog) || dialog.selected != expected { return Err("stale"); }
                // No retry after this call: transport failure can mean delivered.
                self.client.send_keys(&identity.pane_id, &[key.as_str()])?;
                if let Some(after) = after {
                    let deadline = Instant::now()+Duration::from_secs(1);
                    loop {
                        let screen = self.client.read_visible(&identity.pane_id).map_err(|_|"stale")?;
                        let dialog=approval_screen::parse(pending.request.agent,&screen,command).ok_or("stale")?;
                        if !pending.dialog.same_dialog(&dialog) { return Err("stale"); }
                        if dialog.selected == Some(after) {break;}
                        if Instant::now()>=deadline {return Err("stale");}
                        thread::sleep(Duration::from_millis(50));
                    }
                    expected=Some(after);
                }
            }
        } else {
            self.client.send_keys(&identity.pane_id, &[key.as_str()])?;
        }

        let cursor = pending.request.agent == Agent::Cursor;
        if cursor && target == cursor_screen::SKIP {
            self.cursor_finish_skip(identity, pending)?;
        }
        // Cursor records the call only after the command finishes or is skipped.
        let window = Duration::from_secs(if cursor { 5 } else { 2 });
        let deadline = Instant::now() + window;
        let mut confirmed = false;
        for _ in 0..(window.as_millis() / 100) {
            let Ok(screen) = self.client.read_visible(&identity.pane_id) else { break };
            let same = approval_screen::parse(pending.request.agent, &screen, command)
                .is_some_and(|dialog| pending.dialog.same_dialog(&dialog));
            if cursor && !same && matches!(cursor_screen::classify(&screen, ""), cursor_screen::Screen::DenyFeedback) {
                // Still on the optional feedback input: nothing has resolved yet.
            } else if !same {
                if cursor {
                    let Ok((_,file))=self.model_pane_file(identity) else {break};
                    if watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?).is_err() {break;}
                    let anchor = crate::cursor::request_offset(&pending.request.request_id).ok_or("stale")?;
                    confirmed = crate::cursor::recorded_shell(&file, anchor, command);
                    if confirmed {break;}
                } else if pending.request.agent==Agent::Agy {
                    let Ok((_,file))=self.model_pane_file(identity) else {break};
                    if watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?).is_err() {break;}
                    if let Ok(history)=crate::follower::read_tail(file) {
                        confirmed=crate::agy::completed_call(&history,&pending.request.request_id,"run_command");
                    }
                    if confirmed {break;}
                } else { confirmed=true;break; }
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            thread::sleep(Duration::from_millis(100).min(remaining));
        }
        Ok(json!({"request_id":pending.request.request_id,"sent":key,"confirmed":confirmed}))
    }
    /// After choosing Skip, Cursor shows an optional "tell the agent what to do
    /// instead" input. Submit it empty so the skip completes without feedback.
    fn cursor_finish_skip(&self, identity: &Identity, pending: &PendingApproval) -> Result<()> {
        let command = pending.request.tool_input["command"].as_str().ok_or("stale")?;
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let screen = self.client.read_visible(&identity.pane_id).map_err(|_| "stale")?;
            match cursor_screen::classify(&screen, "") {
                cursor_screen::Screen::DenyFeedback => {
                    self.model_pane_file(identity)?;
                    // Delivery is not retried: a transport error may still have sent it.
                    self.client.send_keys(&identity.pane_id, &["enter"])?;
                    return Ok(());
                }
                cursor_screen::Screen::Approval(dialog) if pending.dialog.same_dialog(&dialog)
                    && approval_screen::parse(Agent::Cursor, &screen, command).is_some() => {}
                // The card went away without a feedback input; confirm normally.
                _ => return Ok(()),
            }
            if Instant::now() >= deadline { return Err("stale"); }
            thread::sleep(Duration::from_millis(50));
        }
    }
    /// The only safe basis for typing into a Cursor pane: an idle occupant whose
    /// screen shows an empty composer and no approval card or question form.
    /// Herdr can report `done` for a live question form, and Cursor writes no
    /// pending card to its transcript, so neither status nor transcript counts.
    fn cursor_ready(&self, identity: &Identity, require_agent_mode: bool) -> Result<()> {
        let idle = |pane: &Pane| matches!(pane.agent_status.as_str(), "idle" | "done");
        let (pane, _) = self.model_pane_file(identity)?;
        if !idle(&pane) { return Err("agent_busy"); }
        let plain = self.client.read_visible(&identity.pane_id).map_err(|_| "screen_unavailable")?;
        let styled = self.client.read_visible_ansi(&identity.pane_id).map_err(|_| "screen_unavailable")?;
        match cursor_screen::classify(&plain, &styled) {
            cursor_screen::Screen::Idle { mode } if !require_agent_mode || mode.is_none() => {}
            cursor_screen::Screen::Idle { .. } => return Err("mode_not_agent"),
            cursor_screen::Screen::Draft => return Err("composer_not_empty"),
            cursor_screen::Screen::Busy => return Err("agent_busy"),
            cursor_screen::Screen::Approval(_) | cursor_screen::Screen::UnsupportedCard
            | cursor_screen::Screen::DenyFeedback => return Err("approval_pending"),
            cursor_screen::Screen::Question => return Err("question_pending"),
            cursor_screen::Screen::Overlay => return Err("picker_open"),
            cursor_screen::Screen::Unknown => return Err("screen_unrecognized"),
        }
        // Re-verify the occupant last, immediately before the caller types.
        let (pane, _) = self.model_pane_file(identity)?;
        if !idle(&pane) { return Err("agent_busy"); }
        Ok(())
    }
    /// Submit one prompt to a Cursor pane. The screen guard and the prompt are
    /// one bridge call, so no phone round trip separates check from send.
    fn prompt_submit(&mut self, params: &Value) -> Result<Value> {
        let watch = self.watch.as_ref().ok_or("not_watching")?;
        let identity = watch.identity.clone().filter(|_| watch.unavailable.is_none())
            .ok_or("timeline_unavailable")?;
        if identity.agent != "cursor" { return Err("unsupported_agent"); }
        if params["expect"]["identity"] != serde_json::to_value(&identity).map_err(|_| "stale")?
            || params["expect"]["generation"].as_u64() != Some(self.generation) {
            return Err("stale");
        }
        let text = params["text"].as_str().ok_or("invalid_request")?;
        if text.trim().is_empty() || text.len() > 65_536 || text.chars().any(|c| c == '\0') {
            return Err("invalid_request");
        }
        // A leading slash would run a Cursor command (/quit, /model ...) instead
        // of reaching the model; the phone never sends one.
        if text.trim_start().starts_with('/') { return Err("slash_command_refused"); }
        self.cursor_ready(&identity, false)?;
        // No retry: a failed transport call may still have delivered the prompt.
        self.client.agent_prompt(&identity.pane_id, text).map_err(|_| "prompt_unconfirmed")?;
        Ok(json!({"submitted":true}))
    }
    fn question_pane_file(&self, identity: &Identity) -> Result<std::fs::File> {
        let snapshot = self.client.snapshot().map_err(|_| "stale")?;
        let pane = snapshot.panes.iter().find(|p| p.pane_id == identity.pane_id).ok_or("stale")?;
        // Herdr reports a live Cursor question form as done, so Cursor is judged
        // by its screen; a working or unknown pane is still refused.
        let status_ok = match identity.agent.as_str() {
            "antigravity_cli" => true,
            "cursor" => matches!(pane.agent_status.as_str(), "blocked" | "idle" | "done"),
            _ => pane.agent_status == "blocked",
        };
        if !status_ok || pane.terminal_id != identity.terminal_id
            || !pane.agent.as_deref().is_some_and(|agent| self.adapter_for(agent).is_some_and(|a| a.name() == identity.agent)) { return Err("stale"); }
        let adapter = self.adapter_for(&identity.agent).ok_or("stale")?;
        let (session, file) = adapter.resolve_and_open(pane).map_err(|_| "stale")?;
        if session != identity.native_session_id { return Err("stale"); }
        Ok(file)
    }
    fn respond_question(&self, params: &Value, watch: &Watch, identity: &Identity, pending: &PendingQuestionEvent) -> InteractionResult<Value> {
        if !pending.fresh { return Err("in_progress".into()); }
        // Reopen the last verified reference, then independently validate the fresh
        // occupant. Neither the transcript match nor screen may come from a cache.
        let source = watch.source_pane.as_ref().ok_or("stale")?;
        let adapter = self.adapter_for(&identity.agent).ok_or("stale")?;
        let (session, _) = adapter.resolve_and_open(source).map_err(|_| "stale")?;
        if session != identity.native_session_id { return Err("stale".into()); }
        let file = self.question_pane_file(identity)?;
        let newest = self.matched_question(identity, file, &mut None).ok_or("stale")?;
        if newest != pending.request { return Err("stale".into()); }
        let visible = self.client.read_visible(&identity.pane_id).map_err(|_| "stale")?;
        let current = question_screen::parse(newest.kind, &visible, &newest).ok_or("stale")?;
        if current.step == QuestionStep::AsyncQueued && current.queued_count != Some(1) {
            return Err("stale".into());
        }
        if !current.is_fresh(&newest) { return Err("in_progress".into()); }
        let steps = question_keys::plan(newest.kind, &newest, &current, params)?;
        let mut confirmed = self.execute_question(identity, &newest, current, &steps)?;
        if newest.kind == QuestionKind::CursorAsk {
            confirmed = self.confirm_cursor_question(watch, identity, &newest);
        }
        if newest.kind == QuestionKind::AgyAsk {
            confirmed=false;
            let deadline=Instant::now()+Duration::from_secs(2);
            loop {
                let Ok((_,file))=self.model_pane_file(identity) else {break};
                if watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?).is_err() {break;}
                if let Ok(history)=crate::follower::read_tail(file)
                    && crate::agy::completed_question(&history,&newest.request_id,newest.questions.len()) {confirmed=true;break;}
                if Instant::now()>=deadline {break;}
                thread::sleep(Duration::from_millis(100));
            }
        }
        Ok(json!({"request_id":newest.request_id,"confirmed":confirmed}))
    }
    /// The question left the screen. Confirmed means the form moved on: the next
    /// question is showing, or (for the last one) the form closed and Cursor
    /// appended the `AskQuestion` call. The answers themselves are not in the
    /// transcript, so neither proves what was chosen.
    fn confirm_cursor_question(&self, watch: &Watch, identity: &Identity, asked: &PendingQuestion) -> bool {
        let Some((anchor, number, total)) = crate::cursor_form::request_parts(&asked.request_id) else { return false };
        let prompt = asked.questions.first().map(|q| q.text.as_str()).unwrap_or("");
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            let Ok(screen) = self.client.read_visible(&identity.pane_id) else { return false };
            match crate::cursor_form::parse_form(&screen) {
                // The same question again: Enter has not taken effect yet.
                Some(form) if form.index + 1 == number && form.total == total => {}
                Some(form) => return number < total && form.index + 1 == number + 1 && form.total == total,
                None if number < total => return false,
                None => {
                    let Ok((_, file)) = self.model_pane_file(identity) else { return false };
                    if watch.follower.verify_source(match file.try_clone() { Ok(f) => f, Err(_) => return false }).is_err() {
                        return false;
                    }
                    if crate::cursor::recorded_question(&file, anchor, prompt) { return true; }
                }
            }
            thread::sleep(Duration::from_millis(100));
        }
        false
    }
    fn execute_question(&self, identity: &Identity, pending: &PendingQuestion, mut current: QuestionScreen, steps: &[Step]) -> InteractionResult<bool> {
        let mut steps_sent = 0;
        for (index, step) in steps.iter().enumerate() {
            if matches!(pending.kind, QuestionKind::AgyAsk | QuestionKind::CursorAsk) {
                let file=self.question_pane_file(identity).map_err(|_|InteractionError::stale_after(steps_sent))?;
                let watch=self.watch.as_ref().ok_or("stale")?;
                watch.follower.verify_source(file.try_clone().map_err(|_|"stale")?).map_err(|_|InteractionError::stale_after(steps_sent))?;
                if self.matched_question(identity,file,&mut None).as_ref()!=Some(pending) {return Err(InteractionError::stale_after(steps_sent));}
                if index==0 {
                    let visible=self.client.read_visible(&identity.pane_id).map_err(|_|InteractionError::stale_after(steps_sent))?;
                    if question_screen::parse(pending.kind,&visible,pending).is_none_or(|s|s.fingerprint!=current.fingerprint) {return Err(InteractionError::stale_after(steps_sent));}
                }
            }
            if index == 0 { self.question_pane_file(identity).map_err(|_| InteractionError::stale_after(steps_sent))?; }
            if index > 0 {
                let occupant = self.question_pane_file(identity);
                // A guard read immediately before each later input catches desk
                // edits and a last picker that disappeared after the digit check.
                let visible = self.client.read_visible_with_timeout(&identity.pane_id, Duration::from_secs(1))
                    .map_err(|_| InteractionError::stale_after(steps_sent))?;
                let parsed = question_screen::parse(pending.kind, &visible, pending);
                if step.only_if.is_some() && parsed.is_none() { return Ok(true); }
                let parsed = parsed.ok_or_else(|| InteractionError::stale_after(steps_sent))?;
                // A remaining dialog must still belong to this blocked occupant.
                // Disappearance needs no further input, even if the pane is idle.
                occupant.map_err(|_| InteractionError::stale_after(steps_sent))?;
                if !steps[index-1].expected.matches(Some(&parsed))
                    || step.only_if.as_ref().is_some_and(|guard| !guard.matches(&parsed)) {
                    return Err(InteractionError::stale_after(steps_sent));
                }
                current = parsed;
            }
            // Count dispatched input attempts conservatively: a transport failure
            // may happen after Herdr received the input. Never retry that input.
            steps_sent += 1;
            let sent = match &step.input {
                Input::Keys(keys) => self.client.send_keys(&identity.pane_id, &keys.iter().map(String::as_str).collect::<Vec<_>>()),
                Input::Text(text) => self.client.send_text(&identity.pane_id, text),
            };
            sent.map_err(|_| InteractionError::stale_after(steps_sent))?;
            let deadline = Instant::now() + Duration::from_secs(1);
            let final_input = matches!(step.expected, ExpectedScreen::Gone);
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    if final_input { return Ok(false); }
                    return Err(InteractionError::stale_after(steps_sent));
                }
                let visible = match self.client.read_visible_with_timeout(&identity.pane_id, remaining) {
                    Ok(visible) => visible,
                    Err(_) if final_input => return Ok(false),
                    Err(_) => return Err(InteractionError::stale_after(steps_sent)),
                };
                let parsed = question_screen::parse(pending.kind, &visible, pending);
                if step.expected.matches(parsed.as_ref()) {
                    match parsed {
                        Some(parsed) => { current = parsed; break; }
                        None => return Ok(true),
                    }
                }
                // On final submission an unchanged dialog means unconfirmed;
                // any different parsed dialog is a state mismatch, not success.
                if final_input && parsed.as_ref().is_none_or(|s| s.fingerprint != current.fingerprint) {
                    return Err(InteractionError::stale_after(steps_sent));
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                if !remaining.is_zero() { thread::sleep(Duration::from_millis(100).min(remaining)); }
            }
        }
        Ok(false)
    }
    pub fn request(&mut self, bytes: &[u8], out: &mut impl Write) -> io::Result<()> {
        self.request_with_refresh(bytes, out, |follower, file, session| {
            follower.refresh_file(file, session)
        })
    }
    fn request_with_refresh(
        &mut self,
        bytes: &[u8],
        out: &mut impl Write,
        refresh: impl FnMut(&mut Follower, std::fs::File, &str) -> Result<bool>,
    ) -> io::Result<()> {
        let request: Value = match serde_json::from_slice(bytes) {
            Ok(value) => value,
            Err(_) => return Self::error(out, Value::Null, "invalid_json"),
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        if !id.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 128) {
            return Self::error(out, Value::Null, "invalid_request_id");
        }
        let params = &request["params"];
        let method = request["method"].as_str().unwrap_or("");
        if method == "initialize" {
            self.initialized = false;
            self.include_content = params["record_content"] == true;
            self.include_approvals = params["approvals"] == true;
            self.include_questions = params["questions"] == true;
            self.include_model_control = params["model_control"] == true;
            self.watch = None;
            if params["protocol"] != 1 {
                return Self::error(out, id, "protocol_mismatch");
            }
            if let Err(code) = self.client.snapshot() {
                return Self::error(out, id, code);
            }
            self.initialized = true;
            let claude_available = self.adapter_for("claude").is_some_and(|a| a.is_available());
            let codex_available = self.adapter_for("codex").is_some_and(|a| a.is_available());
            return Self::write(
                out,
                &json!({"id":id,"result":{"protocol":1,"bridge_version":env!("CARGO_PKG_VERSION"),"epoch":self.epoch,"capabilities":{"agy":self.adapter_for("agy").is_some_and(|a| a.is_available()),"pi":self.adapter_for("pi").is_some_and(|a|a.is_available()),"cursor":self.adapter_for("cursor").is_some_and(|a| a.is_available()),"cursor_prompts":self.adapter_for("cursor").is_some_and(|a| a.is_available()),"claude_timeline":claude_available,"record_content":true,"codex_timeline":codex_available,"codex_daemon_config":true,"codex_daemon_stop":true,"git":false,"prompts":false,"approvals":true,"questions":true,"model_control":true,"routed_hosts":false}}}),
            );
        }
        if !self.initialized {
            return Self::error(out, id, "not_initialized");
        }
        match method {
            "interaction.respond" => match self.respond_interaction(params) {
                Ok(result) => {
                    Self::write(out, &json!({"id":id,"result":result}))?;
                    self.poll(out)
                }
                Err(error) => Self::write(out, &json!({"id":id,"error":error.data()})),
            },
            "model.status" => {
                // Retry failures once per explicit request, before the mandatory
                // refresh. Its result is reused below, so slow failures cannot
                // consume two discovery budgets in one RPC.
                *self.agy_catalog_error.borrow_mut() = None;
                *self.codex_catalog_error.borrow_mut() = None;
                self.poll_with_refresh(out, refresh)?;
                let result = if self.watch.as_ref().and_then(|w|w.identity.as_ref()).is_some_and(|i|i.agent=="pi") {
                    self.watch.as_ref().and_then(|w|w.pi_state.as_ref()).map(|s| {
                        let current=s["model"]["id"].as_str();
                        let efforts=s["models"].as_array().and_then(|models|models.iter()
                            .find(|model|model["id"].as_str()==current))
                            .and_then(|model|model["efforts"].as_array()).cloned().unwrap_or_default();
                        json!({
                            "identity":self.watch.as_ref().and_then(|w|w.identity.clone()),"generation":self.generation,"agent":"pi",
                            "model":s["model"],"effort":s["model"]["effort"],"models":s["models"],
                            "efforts":efforts,"catalog":{"source":"extension","fresh":true,"complete":true,"cliVersion":"1.4.0"}
                        })
                    }).ok_or("pi_extension_unavailable")
                } else { self.model_status() };
                match result {
                    Ok(result) => Self::write(out, &json!({"id":id,"result":result})),
                    Err(code) => Self::error(out, id, code),
                }
            }
            "prompt.submit" => {
                self.poll_with_refresh(out, refresh)?;
                match self.prompt_submit(params) {
                    Ok(result) => {
                        Self::write(out, &json!({"id":id,"result":result}))?;
                        self.poll(out)
                    }
                    Err(code) => Self::write(out, &json!({"id":id,"error":{"code":code}})),
                }
            }
            "model.set" => {
                self.poll_with_refresh(out, refresh)?;
                let is_pi=self.watch.as_ref().and_then(|w|w.identity.as_ref()).is_some_and(|i|i.agent=="pi");
                let result=if is_pi {self.pi_action("model.set",params)} else {self.model_set(params)};
                match result {
                    Ok(result) => {
                        Self::write(out, &json!({"id":id,"result":result}))?;
                        self.poll(out)
                    }
                    Err(code) => Self::write(out, &json!({"id":id,"error":{"code":code}})),
                }
            }
            "pi.prompt" | "pi.cancel" | "pi.dialog.respond" => {
                self.poll_with_refresh(out, refresh)?;
                let method=method.strip_prefix("pi.").unwrap_or(method);
                match self.pi_action(method,params) {
                    Ok(result) => { Self::write(out,&json!({"id":id,"result":result}))?; self.poll(out) }
                    Err(code) => Self::error(out,id,code),
                }
            }
            "watch" => {
                let Some(pane) = params["pane_id"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 256)
                else {
                    return Self::error(out, id, "invalid_pane_id");
                };
                self.watch = Some(Watch {
                    pane_id: pane.into(),
                    identity: None,
                    follower: if self.include_content {
                        Follower::with_content()
                    } else {
                        Follower::default()
                    },
                    generation: 0,
                    previous: Vec::new(),
                    unavailable: None,
                    status: String::new(),
                    unknown_records: 0,
                    dropped_entries: 0,
                    source_changing_count: 0,
                    delayed: false,
                    agent: None,
                    unavailable_agent: None,
                    last_daemon_status: None,
                    pending: None,
                    approval_cache: None,
                    question_cache: None,
                    source_pane: None,
                    model_stamp: None,
                    last_model: None,
                    model_override: None,
                    pi_state: None,
                    pi_dialog: None,
                });
                Self::write(out, &json!({"id":id,"result":{"watching":pane}}))?;
                self.poll(out)
            }
            "unwatch" => {
                self.watch = None;
                Self::write(out, &json!({"id":id,"result":{"watching":null}}))
            }
            "content" => {
                if !self.include_content {
                    return Self::error(out, id, "unsupported_capability");
                }
                self.poll_with_refresh(out, refresh)?;
                let Some(watch) = &self.watch else {
                    return Self::error(out, id, "not_watching");
                };
                if watch.unavailable.is_some() || watch.identity.is_none() || watch.delayed {
                    return Self::error(out, id, "timeline_unavailable");
                }
                if params["generation"].as_u64() != Some(self.generation) {
                    return Self::error(out, id, "stale_cursor");
                }
                let Some(reference) = params["content_ref"].as_str().filter(|s| s.len() <= 128)
                else {
                    return Self::error(out, id, "content_unavailable");
                };
                let Some(offset) = params["offset"]
                    .as_u64()
                    .and_then(|n| usize::try_from(n).ok())
                else {
                    return Self::error(out, id, "invalid_content_offset");
                };
                match watch.follower.read_content(reference, offset) {
                    Ok((bytes, total)) => {
                        let digits = b"0123456789abcdef";
                        let mut hex = String::with_capacity(bytes.len() * 2);
                        for byte in &bytes {
                            hex.push(digits[(byte >> 4) as usize] as char);
                            hex.push(digits[(byte & 15) as usize] as char);
                        }
                        Self::write(
                            out,
                            &json!({"id":id,"result":{"identity":watch.identity,"generation":self.generation,
                            "content_ref":reference,"offset":offset,"next_offset":offset + bytes.len(),"total":total,"hex":hex}}),
                        )
                    }
                    Err(code) => Self::error(out, id, code),
                }
            }
            "history" => {
                self.poll_with_refresh(out, refresh)?;
                let Some(watch) = &self.watch else {
                    return Self::error(out, id, "not_watching");
                };
                if watch.unavailable.is_some() || watch.identity.is_none() {
                    return Self::error(out, id, "timeline_unavailable");
                }
                if params["generation"].as_u64() != Some(self.generation) {
                    return Self::error(out, id, "stale_cursor");
                }
                let entries = &watch.follower.transcript.entries;
                let Some(before) = params["before"]
                    .as_str()
                    .and_then(|id| entries.iter().position(|e| e.id == id))
                else {
                    return Self::error(out, id, "stale_cursor");
                };
                let mut result = page(entries, before);
                result["identity"] = json!(watch.identity);
                result["generation"] = json!(self.generation);
                result["dropped_entries"] = json!(watch.follower.transcript.dropped_entries);
                Self::write(out, &json!({"id":id,"result":result}))
            }
            _ => Self::error(out, id, "unknown_method"),
        }
    }
}
pub fn serve(mut service: Service, interval: Duration) -> io::Result<()> {
    let (sender, receiver) = mpsc::sync_channel::<Result<Vec<u8>>>(16);
    thread::spawn(move || {
        let mut input = BufReader::new(io::stdin());
        loop {
            let mut bytes = Vec::new();
            match (&mut input)
                .take((MAX_RECORD + 1) as u64)
                .read_until(b'\n', &mut bytes)
            {
                Ok(0) => break,
                Ok(_) if bytes.len() > MAX_RECORD => {
                    let _ = sender.send(Err("input_frame_too_large"));
                    break;
                }
                Ok(_) if bytes.last() != Some(&b'\n') => {
                    let _ = sender.send(Err("incomplete_input_frame"));
                    break;
                }
                Ok(_) => {
                    if sender.send(Ok(bytes)).is_err() {
                        break;
                    }
                }
                Err(_) => {
                    let _ = sender.send(Err("input_unavailable"));
                    break;
                }
            }
        }
    });
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut deadline = Instant::now() + interval;
    loop {
        match receiver.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(Ok(bytes)) => service.request(&bytes, &mut out)?,
            Ok(Err(code)) => {
                Service::error(&mut out, Value::Null, code)?;
                return Err(io::Error::other(code));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        }
        if Instant::now() >= deadline {
            service.poll(&mut out)?;
            deadline = Instant::now() + interval;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, os::unix::net::UnixListener};
    const SESSION: &str = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
    const OTHER: &str = "11111111-1111-4111-8111-111111111111";

    #[test]
    fn transcript_override_keeps_daemon_home_and_home_override_invalidates_cache() {
        let root = std::env::temp_dir().join(format!(
            "service-home-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
        ));
        let home = root.join("home");
        let transcripts = root.join("other-volume/transcripts");
        fs::create_dir_all(home.join("app-server-daemon")).unwrap();
        fs::create_dir_all(&transcripts).unwrap();
        // A malformed home pid file gives Unknown; the unrelated transcript
        // parent has no pid file and would incorrectly give NotRunning.
        fs::write(home.join("app-server-daemon/daemon.pid"), "invalid").unwrap();
        let mut service = Service::with_resolvers(root.join("unused.sock"), None, None)
            .with_codex_home(root.join("empty-home"));
        assert_eq!(service.cached_codex_daemon_status(), "not_running");
        service = service.with_codex_home(home).with_codex_root(transcripts);
        let status = service.cached_codex_daemon_status();
        fs::remove_dir_all(root).unwrap();
        assert_eq!(status, "unknown");
    }

    // Return snapshots synchronously for each explicit poll. The injected
    // refresh boundary makes source_changing independent of timing/file races.
    #[derive(Default)]
    struct HerdrState {
        ansi_screen: Option<String>,
        // (n, terminal): from the n-th plain pane.read on, snapshots report a
        // replacement terminal (the pane was swapped right after that read).
        terminal_after_reads: Option<(usize, String)>,
        agent: Option<String>,
        status: Option<String>,
        screen: String,
        reads: usize,
        read_error: bool,
        read_error_after_send: bool,
        keys: Vec<Value>,
        screens_after_send: std::collections::VecDeque<String>,
        allow_question_input: bool,
        inputs: Vec<Value>,
        // One render sequence per input; extra guard reads retain the last render.
        screens_after_input: std::collections::VecDeque<std::collections::VecDeque<String>>,
        active_input_screens: std::collections::VecDeque<String>,
        screens_before_input: std::collections::VecDeque<String>,
        terminal_after_input: Option<String>,
        status_after_inputs: Option<(usize, String)>,
        hide_pane: bool,
        terminal_id: Option<String>,
        session_override: Option<String>,
        transcript_after_inputs: Option<(usize, PathBuf, String)>,
        // A stateful Cursor TUI emulator; when set it answers reads and inputs.
        tui: Option<CursorTui>,
        // Foreground process command lines for pane.process_info.
        process_lines: Option<Vec<String>>,
    }
    type SharedHerdr = std::sync::Arc<std::sync::Mutex<HerdrState>>;
    fn fixture() -> (Service, PathBuf, std::sync::Arc<std::sync::Mutex<String>>) {
        let (service, root, session, _) = fixture_with_herdr();
        (service, root, session)
    }
    fn fixture_with_herdr() -> (Service, PathBuf, std::sync::Arc<std::sync::Mutex<String>>, SharedHerdr) {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "service-test-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        fs::create_dir_all(root.join("projects/one")).unwrap();
        for session in [SESSION, OTHER] {
            let text = (0..107).map(|i| format!("{}\n", json!({"type":"user","uuid":format!("m{i}"),"sessionId":session,"message":{"role":"user","content":format!("text{i}")}}))).collect::<String>();
            fs::write(root.join(format!("projects/one/{session}.jsonl")), text).unwrap();
        }
        let socket = root.join("h.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let session = std::sync::Arc::new(std::sync::Mutex::new(SESSION.to_owned()));
        let session_for_server = session.clone();
        let herdr = SharedHerdr::default();
        let server_state = herdr.clone();
        // Cleanup wakes this blocking listener with an empty request.
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { break };
                let mut line = String::new();
                if BufReader::new(stream.try_clone().unwrap())
                    .read_line(&mut line)
                    .unwrap()
                    == 0
                {
                    break;
                }
                let request: Value = serde_json::from_str(&line).unwrap();
                let mut state = server_state.lock().unwrap();
                let result = match request["method"].as_str().unwrap() {
                    "pane.read" if state.tui.is_some() => {
                        let ansi = request["params"]["format"] == "ansi";
                        let tui = state.tui.as_ref().unwrap();
                        json!({"read":{"text":if ansi { tui.styled() } else { tui.plain() }}})
                    }
                    "pane.send_keys" if state.tui.is_some() => {
                        let keys: Vec<String> = request["params"]["keys"].as_array().unwrap().iter().map(|k| k.as_str().unwrap().to_owned()).collect();
                        assert_eq!(keys.len(), 1, "one key per call");
                        state.inputs.push(json!({"method":"pane.send_keys","params":request["params"]}));
                        state.tui.as_mut().unwrap().key(&keys[0]);
                        json!({})
                    }
                    "pane.send_text" if state.tui.is_some() => {
                        let text = request["params"]["text"].as_str().unwrap().to_owned();
                        state.inputs.push(json!({"method":"pane.send_text","params":request["params"]}));
                        state.tui.as_mut().unwrap().text(&text);
                        json!({})
                    }
                    "pane.process_info" => {
                        let lines = state.process_lines.clone().unwrap_or_else(|| vec![
                            "/home/u/.local/bin/cursor-agent --use-system-ca /home/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/index.js --trust".to_owned()]);
                        let procs: Vec<Value> = lines.iter().map(|l| json!({"cmdline":l,"name":"node","pid":1})).collect();
                        json!({"type":"pane_process_info","process_info":{"foreground_process_group_id":1,"foreground_processes":procs,"pane_id":"w1:p1","shell_pid":1}})
                    }
                    "pane.read" if request["params"]["format"] == "ansi" => {
                        assert_eq!(request["params"], json!({"pane_id":"w1:p1","source":"visible","format":"ansi"}));
                        // Real agents draw idle placeholders faint; a test sets
                        // `ansi_screen` to model typed, unstyled text instead.
                        let text = state.ansi_screen.clone().unwrap_or_else(|| {
                            state.screen.lines().map(|line| {
                                for marker in ["❯ ", "› "] {
                                    if let Some(rest) = line.trim_start().strip_prefix(marker) {
                                        return format!("{marker}\u{1b}[2m{rest}\u{1b}[0m");
                                    }
                                }
                                line.to_owned()
                            }).collect::<Vec<_>>().join("\n")
                        });
                        json!({"read":{"text":text}})
                    }
                    "pane.read" => {
                        assert_eq!(request["params"], json!({"pane_id":"w1:p1","source":"visible"}));
                        state.reads += 1;
                        if let Some((count, terminal)) = state.terminal_after_reads.clone()
                            && state.reads >= count { state.terminal_id = Some(terminal); }
                        if state.allow_question_input {
                            if let Some(screen) = state.screens_before_input.pop_front()
                                .or_else(|| state.active_input_screens.pop_front()) {
                                state.screen = screen;
                            }
                        } else if !state.keys.is_empty() {
                            if let Some(screen) = state.screens_after_send.pop_front() {
                                state.screen = screen;
                            }
                        }
                        json!({"read":{"text":state.screen}})
                    }
                    "pane.send_keys" => {
                        let keys = request["params"]["keys"].as_array().unwrap();
                        if !state.allow_question_input {
                            assert_eq!(keys.len(), 1);
                            assert!(keys.iter().all(|key| !["enter", "\n", "\r"].contains(&key.as_str().unwrap())));
                        }
                        state.keys.push(request["params"].clone());
                        state.inputs.push(json!({"method":"pane.send_keys","params":request["params"]}));
                        state.active_input_screens = state.screens_after_input.pop_front().unwrap_or_default();
                        json!({})
                    }
                    "pane.send_text" => {
                        assert!(state.allow_question_input);
                        assert_eq!(request["params"]["pane_id"], "w1:p1");
                        assert!(request["params"]["text"].is_string());
                        assert_eq!(request["params"].as_object().unwrap().len(), 2);
                        state.inputs.push(json!({"method":"pane.send_text","params":request["params"]}));
                        state.active_input_screens = state.screens_after_input.pop_front().unwrap_or_default();
                        json!({})
                    }
                    "agent.prompt" => {
                        assert!(state.allow_question_input);
                        assert_eq!(request["params"]["target"], "w1:p1");
                        assert!(request["params"]["text"].is_string());
                        assert_eq!(request["params"].as_object().unwrap().len(), 2);
                        state.inputs.push(json!({"method":"agent.prompt","params":request["params"]}));
                        state.active_input_screens = state.screens_after_input.pop_front().unwrap_or_default();
                        json!({})
                    }
                    "session.snapshot" => {
                        if let Some((count, path, text))=state.transcript_after_inputs.as_ref()
                            && state.inputs.len()>=*count {fs::write(path,text).unwrap();}

                        if let Some((count, status)) = state.status_after_inputs.clone()
                            && state.inputs.len() >= count { state.status = Some(status); }
                        if !state.inputs.is_empty() && let Some(terminal) = state.terminal_after_input.clone() {
                            state.terminal_id = Some(terminal);
                        }
                        let agent = state.agent.as_deref().unwrap_or("claude");
                        let mut snapshot = json!({"protocol":22,"version":"0.9.3","panes":[{"pane_id":"w1:p1","terminal_id":state.terminal_id.as_deref().unwrap_or("terminal-one"),"workspace_id":"w1","tab_id":"w1:t1","agent":agent,"agent_status":state.status.as_deref().unwrap_or("idle"),"foreground_cwd":"/fixture/work","revision":1,"agent_session":{"agent":agent,"source":if crate::agy::is_agent(agent) {"herdr:antigravity_cli".to_string()}else{format!("herdr:{agent}")},"kind":"id","value":state.session_override.clone().unwrap_or_else(|| session_for_server.lock().unwrap().clone())}}]});
                        if state.hide_pane {
                            snapshot["panes"] = json!([]);
                        }
                        json!({"type":"session_snapshot","snapshot":snapshot})
                    }
                    method => panic!("unexpected method: {method}"),
                };
                let frame = if request["method"] == "pane.read"
                    && (state.read_error || state.read_error_after_send && !state.keys.is_empty())
                {
                    json!({"id":request["id"],"error":{"code":"pane_not_found"}})
                } else {
                    json!({"id":request["id"],"result":result})
                };
                writeln!(stream, "{frame}").unwrap();
            }
        });
        let mut service = Service::new(socket, root.join("projects"));
        service.initialized = true;
        service
            .request(
                br#"{"id":"w","method":"watch","params":{"pane_id":"w1:p1"}}"#,
                &mut Vec::new(),
            )
            .unwrap();
        (service, root, session, herdr)
    }
    include!("service_agy_tests.rs");
    include!("service_cursor_tests.rs");
    include!("service_cursor_model_tests.rs");
    include!("service_approval_tests.rs");
    include!("service_question_tests.rs");
    include!("service_question_response_tests.rs");
    include!("service_response_tests.rs");
    include!("service_model_tests.rs");
    include!("service_pi_tests.rs");
    fn cleanup(service: &Service, root: PathBuf) {
        // Wake and terminate the fixture thread without a valid request.
        drop(std::os::unix::net::UnixStream::connect(&service.client.socket).unwrap());
        fs::remove_dir_all(root).unwrap();
    }
    fn frames(out: Vec<u8>) -> Vec<Value> {
        String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
    #[test]
    fn changing_same_source_keeps_verified_history_and_generation() {
        let (mut service, root, _) = fixture();
        let generation = service.generation;
        let entries = service.watch.as_ref().unwrap().previous.clone();
        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |_, _, _| Err("source_changing"))
            .unwrap();
        assert!(
            output.is_empty(),
            "a retry must not clear the client timeline"
        );
        assert_eq!(service.generation, generation);
        assert_eq!(service.watch.as_ref().unwrap().previous, entries);
        service.request_with_refresh(json!({"id":"h","method":"history","params":{"generation":generation,"before":"message:m7"}}).to_string().as_bytes(), &mut output, |_, _, _| Err("source_changing")).unwrap();
        let replies = frames(output);
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0]["result"]["entries"].as_array().unwrap().len(), 7);
        assert_eq!(replies[0]["result"]["generation"], generation);
        cleanup(&service, root);
    }
    #[test]
    fn changing_new_identity_clears_previous_occupant_and_recovers_with_snapshot() {
        let (mut service, root, identity) = fixture();
        let generation = service.generation;
        *identity.lock().unwrap() = OTHER.to_owned();
        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |_, _, _| Err("source_changing"))
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies[0]["event"], "timeline.unavailable");
        assert_eq!(replies[0]["data"]["code"], "source_changing");
        assert!(service.watch.as_ref().unwrap().identity.is_none());
        assert!(service.watch.as_ref().unwrap().previous.is_empty());
        assert!(
            service
                .watch
                .as_ref()
                .unwrap()
                .follower
                .transcript
                .entries
                .is_empty()
        );
        let mut output = Vec::new();
        service.request(json!({"id":"h","method":"history","params":{"generation":generation,"before":"message:m7"}}).to_string().as_bytes(), &mut output).unwrap();
        let replies = frames(output);
        assert_eq!(replies[0]["event"], "timeline.snapshot");
        assert_eq!(replies[0]["data"]["identity"]["native_session_id"], OTHER);
        assert_eq!(replies[1]["error"]["code"], "stale_cursor");
        cleanup(&service, root);
    }
    #[test]
    fn counter_only_changes_emit_an_update() {
        let (mut service, root, _) = fixture();
        let generation = service.generation;
        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |follower, _, _| {
                follower.transcript.unknown_records += 1;
                Ok(true)
            })
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies[0]["event"], "timeline.updated");
        assert_eq!(replies[0]["data"]["entries"], json!([]));
        assert_eq!(replies[0]["data"]["unknown_records"], 1);
        assert_eq!(replies[0]["data"]["generation"], generation);
        cleanup(&service, root);
    }
    #[test]
    fn repeated_source_changing_signals_delay_while_keeping_history_and_recovers() {
        let (mut service, root, identity) = fixture();
        let generation = service.generation;
        let entries = service.watch.as_ref().unwrap().previous.clone();
        assert!(!entries.is_empty());

        for _ in 0..9 {
            let mut output = Vec::new();
            service
                .poll_with_refresh(&mut output, |_, _, _| Err("source_changing"))
                .unwrap();
            assert!(output.is_empty());
            assert_eq!(service.generation, generation);
            assert_eq!(service.watch.as_ref().unwrap().previous, entries);
        }

        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |_, _, _| Err("source_changing"))
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0]["event"], "timeline.updated");
        assert_eq!(replies[0]["data"]["delayed"], true);
        assert_eq!(replies[0]["data"]["generation"], generation);
        assert_eq!(replies[0]["data"]["entries"], json!([]));
        assert_eq!(service.watch.as_ref().unwrap().previous, entries);

        let mut output = Vec::new();
        service
            .request_with_refresh(
                json!({"id":"h","method":"history","params":{"generation":generation,"before":"message:m7"}}).to_string().as_bytes(),
                &mut output,
                |_, _, _| Err("source_changing"),
            )
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies[0]["result"]["entries"].as_array().unwrap().len(), 7);
        assert_eq!(replies[0]["result"]["generation"], generation);

        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |_, _, _| Ok(false))
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0]["event"], "timeline.updated");
        assert_eq!(replies[0]["data"]["delayed"], false);
        assert_eq!(service.generation, generation);

        *identity.lock().unwrap() = OTHER.to_owned();
        let mut output = Vec::new();
        service
            .poll_with_refresh(&mut output, |_, _, _| Err("source_changing"))
            .unwrap();
        let replies = frames(output);
        assert_eq!(replies[0]["event"], "timeline.unavailable");
        assert_eq!(replies[0]["data"]["code"], "source_changing");
        assert!(service.watch.as_ref().unwrap().identity.is_none());
        assert!(service.watch.as_ref().unwrap().previous.is_empty());

        cleanup(&service, root);
    }
}
