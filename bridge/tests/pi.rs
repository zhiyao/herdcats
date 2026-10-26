use herdcats_bridge::{
    adapter::Adapter,
    follower::{AgentType, Follower},
    pi::PiAdapter,
};
use std::{fs, path::PathBuf};
const ID: &str = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
fn root() -> PathBuf {
    use std::sync::atomic::{AtomicUsize, Ordering};
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let p = std::env::temp_dir().join(format!(
        "hc-pi-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(p.join("project")).unwrap();
    p.canonicalize().unwrap()
}
#[test]
fn pi_adapter_uses_only_herdr_session_reference_and_pinned_root() {
    let p = root();
    let path = p.join("project").join(format!("{ID}.jsonl"));
    fs::write(
        &path,
        format!("{{\"type\":\"session\",\"version\":3,\"id\":\"{ID}\",\"cwd\":\"/same\"}}\n"),
    )
    .unwrap();
    let adapter = PiAdapter::new(Some(p.clone()));
    let pane = |source: &str, kind: &str, value: &str| {
        serde_json::from_value(serde_json::json!({"pane_id":"p1","terminal_id":"t1","agent":"pi","agent_status":"idle","foreground_cwd":"/wrong","agent_session":{"agent":"pi","source":source,"kind":kind,"value":value}})).unwrap()
    };
    assert_eq!(
        adapter
            .resolve_and_open(&pane("herdr:pi", "id", ID))
            .unwrap()
            .0,
        ID
    );
    assert_eq!(
        adapter
            .resolve_and_open(&pane("herdr:pi", "path", path.to_str().unwrap()))
            .unwrap()
            .0,
        ID
    );
    assert!(
        adapter
            .resolve_and_open(&pane("herdr:pi", "id", "newest"))
            .is_err()
    );
    assert!(
        adapter
            .resolve_and_open(&pane("herdr:other", "id", ID))
            .is_err()
    );
    let outside = p.join("outside");
    fs::write(&outside, b"private fixture\n").unwrap();
    let symlink = p.join("project").join("bad.jsonl");
    std::os::unix::fs::symlink(&outside, &symlink).unwrap();
    assert!(
        adapter
            .resolve_and_open(&pane("herdr:pi", "path", symlink.to_str().unwrap()))
            .is_err()
    );
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn pi_messages_upsert_streaming_tool_calls_and_results_without_private_content_fixture() {
    let p = root();
    let path = p.join("session.jsonl");
    let rows = [
        serde_json::json!({"type":"session","version":3,"id":ID,"cwd":"/synthetic"}),
        serde_json::json!({"type":"message","id":"u1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello fixture"} ]}}),
        serde_json::json!({"type":"message","id":"a1","parentId":"u1","timestamp":"2026-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"thinking"},{"type":"toolCall","id":"call-1","name":"read","arguments":{"path":"/tmp/synthetic"}}],"stopReason":"toolUse"}}),
        serde_json::json!({"type":"message","id":"r1","parentId":"a1","timestamp":"2026-01-01T00:00:02Z","message":{"role":"toolResult","toolCallId":"call-1","toolName":"read","content":[{"type":"text","text":"fixture result"}],"isError":false}}),
    ];
    fs::write(
        &path,
        rows.iter()
            .map(|r| serde_json::to_string(r).unwrap() + "\n")
            .collect::<String>(),
    )
    .unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Pi);
    f.refresh(&path.canonicalize().unwrap(), ID).unwrap();
    assert_eq!(
        f.transcript
            .entries
            .iter()
            .find(|e| e.id == "pi:u1")
            .unwrap()
            .text,
        "hello fixture"
    );
    let call = f
        .transcript
        .entries
        .iter()
        .find(|e| e.id == "pi:tool:call-1")
        .unwrap();
    assert_eq!(call.status.as_deref(), Some("completed"));
    assert!(call.details.is_some());
    assert_eq!(call.text, "fixture result");
    assert!(!call.record_refs.is_empty());
    assert!(
        !f.read_content(&call.record_refs[0], 0)
            .unwrap()
            .0
            .is_empty()
    );
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn pending_leaf_requires_safe_parents_and_valid_persisted_identity() {
    let root = root();
    let path = root
        .join("project")
        .join(format!("2026-10-26T13-31-11-402Z_{ID}.jsonl"));
    let pane = |path: &std::path::Path| {
        serde_json::from_value(serde_json::json!({"pane_id":"p","terminal_id":"t","agent":"pi","agent_status":"idle","agent_session":{"agent":"pi","source":"herdr:pi","kind":"path","value":path}})).unwrap()
    };
    let adapter = PiAdapter::new(Some(root.clone()));
    let (id, file, resolved) = adapter.resolve_pi_live(&pane(&path)).unwrap();
    assert_eq!(id, ID);
    assert!(file.is_none());
    assert_eq!(resolved, path);
    assert!(adapter.resolve_and_open(&pane(&path)).is_err());
    assert!(
        adapter
            .resolve_pi_live(&pane(&root.join("missing").join(format!("{ID}.jsonl"))))
            .is_err()
    );
    fs::write(&path, "invalid fixture").unwrap();
    assert!(adapter.resolve_pi_live(&pane(&path)).is_err());
    fs::write(&path, format!("{{\"type\":\"session\",\"id\":\"{ID}\"}}\n")).unwrap();
    assert!(adapter.resolve_pi_live(&pane(&path)).unwrap().1.is_some());
    fs::write(
        &path,
        "{\"type\":\"session\",\"id\":\"00000000-0000-0000-0000-000000000000\"}\n",
    )
    .unwrap();
    assert!(adapter.resolve_pi_live(&pane(&path)).is_err());
    fs::remove_file(&path).unwrap();
    std::os::unix::fs::symlink(root.join("absent"), &path).unwrap();
    assert!(adapter.resolve_pi_live(&pane(&path)).is_err());
    fs::remove_file(&path).unwrap();
    fs::rename(root.join("project"), root.join("old")).unwrap();
    std::os::unix::fs::symlink(root.join("old"), root.join("project")).unwrap();
    assert!(adapter.resolve_pi_live(&pane(&path)).is_err());
    let custom = root.join("custom.jsonl");
    fs::write(
        &custom,
        format!("{{\"type\":\"session\",\"id\":\"{ID}\"}}\n"),
    )
    .unwrap();
    assert_eq!(adapter.resolve_pi_live(&pane(&custom)).unwrap().0, ID);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pi_plain_text_messages_do_not_make_the_timeline_unavailable() {
    let mut transcript = herdcats_bridge::claude::Transcript::default();
    for role in ["system", "user", "assistant"] {
        transcript.apply_pi(&serde_json::json!({
            "type":"message", "id":format!("plain-{role}"),
            "message":{"role":role,"content":"Plain text fixture"}
        }), ID).unwrap();
    }
    assert_eq!(transcript.entries.len(), 3);
    assert!(transcript.entries.iter().all(|entry| entry.text == "Plain text fixture"));
}

#[test]
fn pi_live_branch_accepts_system_text_after_model_changes() {
    let mut follower = Follower::for_agent(AgentType::Pi);
    let entries = serde_json::json!([
        {"type":"model_change","id":"model","provider":"fixture","modelId":"new"},
        {"type":"thinking_level_change","id":"effort","thinkingLevel":"high"},
        {"type":"message","id":"notice","message":{"role":"system","content":"Model changed"}},
        {"type":"message","id":"user","message":{"role":"user","content":[{"type":"text","text":"Hello"}]}}
    ]);
    follower.refresh_pi_entries(entries.as_array().unwrap(), ID).unwrap();
    assert_eq!(follower.transcript.entries.len(), 2);
    assert_eq!(follower.transcript.entries[0].role.as_deref(), Some("system"));
    assert_eq!(follower.transcript.entries[1].text, "Hello");
}
