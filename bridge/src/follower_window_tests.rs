//! Tail-first reading of append-only Claude and Codex transcripts.
use super::*;
use serde_json::json;
use std::io::Write;

const SESSION: &str = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
const THREAD: &str = "01a1b01e-9864-7d21-bb1b-ce55380eea50";

struct Temp(std::path::PathBuf);
impl Temp {
    fn new(name: &str) -> Self {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        Self(std::env::temp_dir().join(format!(
            "hc-window-{name}-{}-{}",
            std::process::id(),
            N.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        )))
    }
    fn write(&self, text: &str) {
        fs::write(&self.0, text).unwrap();
    }
    fn append(&self, text: &str) {
        fs::OpenOptions::new().append(true).open(&self.0).unwrap().write_all(text.as_bytes()).unwrap();
    }
    fn open(&self) -> fs::File {
        fs::File::open(&self.0).unwrap()
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn line(value: serde_json::Value) -> String {
    format!("{value}\n")
}
fn user(uuid: &str, text: &str) -> String {
    line(json!({"type":"user","uuid":uuid,"sessionId":SESSION,"message":{"role":"user","content":text}}))
}
fn tool_use(uuid: &str, id: &str) -> String {
    line(json!({"type":"assistant","uuid":uuid,"sessionId":SESSION,"message":{"role":"assistant","content":[
        {"type":"tool_use","id":id,"name":"Bash","input":{"command":"ls"}}]}}))
}
fn tool_result(uuid: &str, id: &str, output: &str) -> String {
    line(json!({"type":"user","uuid":uuid,"sessionId":SESSION,"message":{"role":"user","content":[
        {"type":"tool_result","tool_use_id":id,"content":output}]}}))
}
/// Routine metadata the timeline skips; stands in for screenshot-heavy bytes.
fn padding(bytes: usize) -> String {
    line(json!({"type":"attachment","sessionId":SESSION,"payload":"x".repeat(bytes)}))
}

fn small() -> Windows {
    Windows { tail: 2048, chunk: 1024, verify: 1024, head: 256 }
}
fn follower(agent: AgentType, content: bool, windows: Windows) -> Follower {
    let mut follower = if content { Follower::with_content_for_agent(agent) } else { Follower::for_agent(agent) };
    follower.windows = windows;
    follower
}
fn ids(entries: &[crate::claude::Entry]) -> Vec<String> {
    entries.iter().map(|e| e.id.clone()).collect()
}
/// Every entry the follower can serve, oldest first, after loading all older batches.
fn everything(follower: &mut Follower) -> Vec<crate::claude::Entry> {
    while follower.has_unread_older() {
        let before = follower.older().len();
        follower.load_older(before + 100).unwrap();
        assert!(follower.older().len() > before || !follower.has_unread_older(), "a batch must make progress");
    }
    follower.older().iter().chain(&follower.transcript.entries).cloned().collect()
}

#[test]
fn claude_transcript_beyond_the_old_size_limit_loads_its_newest_entries() {
    let temp = Temp::new("large");
    temp.write(&user("first", "first prompt"));
    let pad = padding(1024 * 1024 - 200);
    let mut size = 0;
    {
        let mut file = fs::OpenOptions::new().append(true).open(&temp.0).unwrap();
        while size <= MAX_SOURCE {
            file.write_all(pad.as_bytes()).unwrap();
            size += pad.len() as u64;
        }
    }
    temp.append(&user("last", "newest prompt"));
    let mut follower = Follower::default();
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    assert_eq!(ids(&follower.transcript.entries), ["message:last"]);
    assert!(follower.has_unread_older());
    // Older batches still reach the first prompt through the padding.
    assert_eq!(ids(&everything(&mut follower)), ["message:first", "message:last"]);
}

#[test]
fn appends_after_a_tail_load_are_followed_without_a_reset() {
    let temp = Temp::new("append");
    temp.write(&(0..100).map(|i| user(&format!("m{i}"), &format!("text {i}"))).collect::<String>());
    let mut follower = follower(AgentType::Claude, false, small());
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    let generation = follower.generation;
    assert!(follower.has_unread_older());
    assert!(!follower.refresh_file(temp.open(), SESSION).unwrap(), "nothing new");
    temp.append(&user("new", "appended"));
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    assert_eq!(follower.generation, generation);
    assert_eq!(follower.transcript.entries.last().unwrap().id, "message:new");
}

#[test]
fn appends_beyond_the_verify_window_keep_memory_bounded() {
    let temp = Temp::new("bounded");
    temp.write(&user("m0", "start"));
    let mut follower = follower(AgentType::Claude, false, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    for i in 1..200 {
        temp.append(&user(&format!("m{i}"), &format!("text {i}")));
        follower.refresh_file(temp.open(), SESSION).unwrap();
    }
    assert!(follower.bytes.len() as u64 <= 2 * small().verify, "verified bytes stay bounded");
    assert_eq!(follower.generation, 1);
    assert_eq!(ids(&everything(&mut follower)).len(), 200);
}

#[test]
fn a_rewrite_inside_the_verified_window_resets_the_timeline() {
    let temp = Temp::new("rewrite-window");
    let text: String = (0..100).map(|i| user(&format!("m{i}"), &format!("text {i:03}"))).collect();
    temp.write(&text);
    let mut follower = follower(AgentType::Claude, false, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    let generation = follower.generation;
    temp.write(&text.replace("text 099", "TEXT 099"));
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    assert_eq!(follower.generation, generation + 1);
    assert_eq!(follower.transcript.entries.last().unwrap().text, "TEXT 099");
}

#[test]
fn a_rewrite_of_the_file_head_resets_the_timeline() {
    let temp = Temp::new("rewrite-head");
    let text: String = (0..100).map(|i| user(&format!("m{i}"), &format!("text {i:03}"))).collect();
    temp.write(&text);
    let mut follower = follower(AgentType::Claude, false, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    let generation = follower.generation;
    temp.write(&text.replace("text 000", "TEXT 000"));
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    assert_eq!(follower.generation, generation + 1);
}

#[test]
fn truncation_resets_the_timeline() {
    let temp = Temp::new("truncate");
    temp.write(&(0..100).map(|i| user(&format!("m{i}"), "text")).collect::<String>());
    let mut follower = follower(AgentType::Claude, false, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    let generation = follower.generation;
    temp.write(&user("only", "fresh"));
    assert!(follower.refresh_file(temp.open(), SESSION).unwrap());
    assert_eq!(follower.generation, generation + 1);
    assert_eq!(ids(&follower.transcript.entries), ["message:only"]);
    assert!(!follower.has_unread_older());
}

#[test]
fn older_batches_reach_the_first_message_in_order_without_duplicates() {
    let temp = Temp::new("batches");
    let all: Vec<String> = (0..300).map(|i| format!("m{i}")).collect();
    temp.write(&all.iter().map(|id| user(id, &format!("text for {id}"))).collect::<String>());
    let mut follower = follower(AgentType::Claude, false, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    let expected: Vec<String> = all.iter().map(|id| format!("message:{id}")).collect();
    assert_eq!(ids(&everything(&mut follower)), expected);
}

#[test]
fn a_tool_result_after_the_window_start_completes_its_older_call() {
    let temp = Temp::new("claude-tool");
    let mut text = user("u0", "run it");
    text += &tool_use("a0", "toolu_1");
    text += &padding(3000);
    text += &tool_result("r0", "toolu_1", "listing");
    text += &user("u1", "thanks");
    temp.write(&text);
    let mut follower = follower(AgentType::Claude, true, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    assert!(
        follower.transcript.entries.iter().all(|e| e.kind != "record"),
        "a result whose call is in older bytes is not a raw record: {:?}",
        ids(&follower.transcript.entries)
    );
    let all = everything(&mut follower);
    let tool = all.iter().find(|e| e.id == "tool:toolu_1").unwrap();
    assert_eq!(tool.status.as_deref(), Some("completed"));
    assert_eq!(tool.text, "listing");
}

fn codex(value: serde_json::Value) -> String {
    line(json!({"timestamp":"2026-11-06T09:09:17.605Z","type":"response_item","payload":value}))
}

#[test]
fn a_codex_output_after_the_window_start_completes_its_older_call() {
    let temp = Temp::new("codex-tool");
    let mut text = line(json!({"type":"session_meta","payload":{"id":THREAD,"cwd":"/fixture/work"}}));
    text += &codex(json!({"type":"message","id":"msg_1","role":"user","content":[{"type":"input_text","text":"run it"}]}));
    text += &codex(json!({"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{\"cmd\":\"ls\"}"}));
    text += &line(json!({"type":"compacted","payload":"x".repeat(3000)}));
    text += &codex(json!({"type":"function_call_output","call_id":"call_1","output":"listing"}));
    text += &codex(json!({"type":"message","id":"msg_2","role":"assistant","content":[{"type":"output_text","text":"done"}]}));
    temp.write(&text);
    let mut follower = follower(AgentType::Codex, false, small());
    follower.refresh_file(temp.open(), THREAD).unwrap();
    assert!(
        follower.transcript.entries.iter().all(|e| e.id != "tool:call_1"),
        "no nameless tool for a call in older bytes"
    );
    let all = everything(&mut follower);
    assert_eq!(ids(&all), ["message:msg_1", "tool:call_1", "message:msg_2"]);
    assert_eq!(all[1].tool_name.as_deref(), Some("exec_command"));
    assert_eq!(all[1].status.as_deref(), Some("completed"));
    assert_eq!(all[1].text, "listing");
}

#[test]
fn entries_beyond_retention_move_to_older_batches() {
    let temp = Temp::new("spill");
    let count = crate::claude::MAX_ENTRIES + 150;
    temp.write(&(0..count).map(|i| user(&format!("m{i}"), "t")).collect::<String>());
    let mut follower = Follower::default();
    follower.refresh_file(temp.open(), SESSION).unwrap();
    assert_eq!(follower.transcript.entries.len(), crate::claude::MAX_ENTRIES);
    assert_eq!(follower.older().len(), 150);
    assert_eq!(follower.older()[0].id, "message:m0");
    assert!(!follower.has_unread_older());
}

#[test]
fn content_of_an_older_entry_is_readable() {
    let temp = Temp::new("content");
    let mut text = line(json!({"type":"user","uuid":"img","sessionId":SESSION,"message":{"role":"user","content":[
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGVsbG8="}}]}}));
    text += &padding(3000);
    text += &user("last", "newest");
    temp.write(&text);
    let mut follower = follower(AgentType::Claude, true, small());
    follower.refresh_file(temp.open(), SESSION).unwrap();
    let all = everything(&mut follower);
    let image = all.iter().find(|e| e.kind == "image").unwrap();
    let reference = image.content_ref.clone().unwrap();
    let (bytes, total) = follower.read_content(&reference, 0).unwrap();
    assert_eq!(bytes.len(), total);
    assert!(String::from_utf8(bytes).unwrap().contains("aGVsbG8="));
}

/// Older batches plus the live list must equal one pass over the whole file.
#[test]
fn windowed_entries_match_a_full_pass() {
    let temp = Temp::new("parity");
    let mut text = String::new();
    for turn in 0..40 {
        text += &user(&format!("u{turn}"), &format!("prompt {turn}"));
        text += &tool_use(&format!("a{turn}"), &format!("toolu_{turn}"));
        text += &tool_use(&format!("b{turn}"), &format!("toolu_{turn}b"));
        if turn % 3 == 0 {
            text += &padding(1500);
        }
        text += &tool_result(&format!("r{turn}"), &format!("toolu_{turn}"), &format!("out {turn}"));
        text += &tool_result(&format!("s{turn}"), &format!("toolu_{turn}b"), &format!("out {turn}b"));
    }
    temp.write(&text);
    for content in [false, true] {
        let full = Windows { tail: 1 << 30, ..small() };
        let mut whole = follower(AgentType::Claude, content, full);
        whole.refresh_file(temp.open(), SESSION).unwrap();
        let mut windowed = follower(AgentType::Claude, content, small());
        windowed.refresh_file(temp.open(), SESSION).unwrap();
        assert!(windowed.has_unread_older());
        assert_eq!(everything(&mut windowed), whole.transcript.entries, "content={content}");
    }
}

fn assert_matches_full_pass(temp: &Temp, agent: AgentType, session: &str) -> Vec<crate::claude::Entry> {
    let mut whole = follower(agent, true, Windows { tail: 1 << 30, ..small() });
    whole.refresh_file(temp.open(), session).unwrap();
    let mut windowed = follower(agent, true, small());
    windowed.refresh_file(temp.open(), session).unwrap();
    assert!(windowed.has_unread_older());
    let all = everything(&mut windowed);
    assert_eq!(all, whole.transcript.entries);
    all
}
fn codex_padding() -> String {
    line(json!({"type":"compacted","payload":"x".repeat(1500)}))
}

#[test]
fn late_codex_outputs_reach_a_call_many_batches_older_and_the_last_wins() {
    let temp = Temp::new("codex-late");
    let mut text = line(json!({"type":"session_meta","payload":{"id":THREAD,"cwd":"/fixture/work"}}));
    text += &codex(json!({"type":"custom_tool_call","id":"ct_1","call_id":"call_1","name":"exec","input":"run"}));
    text += &codex(json!({"type":"custom_tool_call_output","call_id":"call_1","output":"Script running"}));
    for _ in 0..8 { text += &codex_padding(); }
    // A background cell reports long after its call, from a middle batch.
    text += &codex(json!({"type":"custom_tool_call_output","call_id":"call_1","output":"first result"}));
    for _ in 0..8 { text += &codex_padding(); }
    text += &codex(json!({"type":"custom_tool_call_output","call_id":"call_1","output":"final result"}));
    text += &codex(json!({"type":"message","id":"msg_2","role":"assistant","content":[{"type":"output_text","text":"done"}]}));
    temp.write(&text);
    let all = assert_matches_full_pass(&temp, AgentType::Codex, THREAD);
    let tool = all.iter().find(|e| e.id == "tool:call_1").unwrap();
    assert_eq!(tool.text, "final result");
}

#[test]
fn a_codex_turn_abort_fails_a_call_still_running_in_an_older_batch() {
    let temp = Temp::new("codex-abort");
    let mut text = line(json!({"type":"session_meta","payload":{"id":THREAD,"cwd":"/fixture/work"}}));
    text += &codex(json!({"type":"function_call","id":"fc_1","call_id":"call_1","name":"exec_command","arguments":"{}"}));
    for _ in 0..8 { text += &codex_padding(); }
    text += &line(json!({"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn_1"}}));
    text += &codex(json!({"type":"message","id":"msg_2","role":"user","content":[{"type":"input_text","text":"next"}]}));
    temp.write(&text);
    let all = assert_matches_full_pass(&temp, AgentType::Codex, THREAD);
    let tool = all.iter().find(|e| e.id == "tool:call_1").unwrap();
    assert_eq!(tool.status.as_deref(), Some("failed"));
}

#[test]
fn a_claude_result_many_batches_after_its_call_completes_it() {
    let temp = Temp::new("claude-late");
    let mut text = user("u0", "run it");
    text += &tool_use("a0", "toolu_1");
    for _ in 0..8 { text += &padding(1500); }
    text += &tool_result("r0", "toolu_1", "late listing");
    for _ in 0..8 { text += &padding(1500); }
    text += &user("u1", "thanks");
    temp.write(&text);
    let all = assert_matches_full_pass(&temp, AgentType::Claude, SESSION);
    let tool = all.iter().find(|e| e.id == "tool:toolu_1").unwrap();
    assert_eq!(tool.text, "late listing");
}
