use herdcats_bridge::{
    adapter::Adapter,
    agy::AgyAdapter,
    follower::{AgentType, Follower},
};
use std::{fs, path::PathBuf};
const ID: &str = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
fn root(label: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("hc-agy-{label}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&p);
    fs::create_dir_all(&p).unwrap();
    p.canonicalize().unwrap()
}
#[test]
fn synthetic_history_links_results_and_preserves_pending_done_tools() {
    let p = root("fixture");
    let file = p.join("transcript.jsonl");
    fs::write(
        &file,
        include_bytes!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl"),
    )
    .unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Agy);
    f.refresh(&file, ID).unwrap();
    let tool = f
        .transcript
        .entries
        .iter()
        .find(|e| e.id == "agy:13:tool:0")
        .unwrap();
    assert_eq!(tool.status.as_deref(), Some("failed"));
    let question = f
        .transcript
        .entries
        .iter()
        .find(|e| e.id == "agy:9:tool:0")
        .unwrap();
    assert_eq!(question.status.as_deref(), Some("completed"));
    assert!(question.details.as_deref().unwrap().contains("Gamma"));
    assert!(!question.record_refs.is_empty());
    assert!(
        !f.read_content(&question.record_refs[0], 0)
            .unwrap()
            .0
            .is_empty()
    );
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn partial_append_rewrite_and_unknown_records_are_bounded_and_reset() {
    let p = root("partial");
    let file = p.join("transcript.jsonl");
    let row = r#"{"type":"USER_INPUT","step_index":0,"status":"DONE","content":"hello"}"#;
    fs::write(&file, row).unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Agy);
    f.refresh(&file, ID).unwrap();
    assert!(f.transcript.entries.is_empty());
    fs::write(&file, format!("{row}\n")).unwrap();
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.transcript.entries[0].text, "hello");
    let generation = f.generation;
    fs::write(
        &file,
        "{\"type\":\"FUTURE\",\"step_index\":1,\"content\":\"unknown\"}\n",
    )
    .unwrap();
    f.refresh(&file, ID).unwrap();
    assert!(f.generation > generation);
    assert_eq!(f.transcript.unknown_records, 1);
    assert_eq!(f.transcript.entries[0].kind, "record");
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn exact_alias_reference_never_uses_cwd_or_symlinks() {
    let p = root("resolve");
    let adapter = AgyAdapter::new(Some(p.clone()));
    let mut pane: herdcats_bridge::herdr::Pane=serde_json::from_value(serde_json::json!({"pane_id":"p1","terminal_id":"t1","agent":"agy","agent_status":"idle","cwd":"/same","agent_session":{"agent":"agy","source":"herdr:antigravity_cli","kind":"id","value":ID}})).unwrap();
    assert!(adapter.resolve_and_open(&pane).is_err());
    let logs = p.join(ID).join(".system_generated/logs");
    fs::create_dir_all(&logs).unwrap();
    fs::write(logs.join("transcript.jsonl"), b"\n").unwrap();
    assert_eq!(adapter.resolve_and_open(&pane).unwrap().0, ID);
    pane.agent_session.as_mut().unwrap().source = "herdr:agy".into();
    assert!(adapter.resolve_and_open(&pane).is_err());
    pane.agent_session.as_mut().unwrap().source = "herdr:antigravity_cli".into();
    fs::remove_file(logs.join("transcript.jsonl")).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", logs.join("transcript.jsonl")).unwrap();
    assert!(adapter.resolve_and_open(&pane).is_err());
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn active_source_verification_rejects_rotation_and_rewrite_but_accepts_append() {
    let p = root("verify");
    let path = p.join("transcript.jsonl");
    let old = "{\"type\":\"USER_INPUT\",\"step_index\":0,\"content\":\"old\"}\n";
    fs::write(&path, old).unwrap();
    let mut f = Follower::for_agent(AgentType::Agy);
    f.refresh(&path, ID).unwrap();
    assert!(f.verify_source(fs::File::open(&path).unwrap()).is_ok());
    fs::write(&path, format!("{old}\n")).unwrap();
    assert!(f.verify_source(fs::File::open(&path).unwrap()).is_ok());
    fs::write(&path, old.replace("old", "new")).unwrap();
    assert!(f.verify_source(fs::File::open(&path).unwrap()).is_err());
    fs::rename(&path, p.join("rotated")).unwrap();
    fs::write(&path, old).unwrap();
    assert!(f.verify_source(fs::File::open(&path).unwrap()).is_err());
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn question_confirmation_requires_unique_matching_generic_answer() {
    let history: Vec<serde_json::Value> =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl")
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
    assert!(!herdcats_bridge::agy::completed_question(
        &history[..2],
        "agy:1:tool:0",
        1
    ));
    assert!(herdcats_bridge::agy::completed_question(
        &history[..3],
        "agy:1:tool:0",
        1
    ));
    assert!(!herdcats_bridge::agy::completed_question(
        &history[..3],
        "agy:9:tool:0",
        2
    ));
    assert!(herdcats_bridge::agy::completed_question(
        &history[..11],
        "agy:9:tool:0",
        2
    ));
}
#[test]
fn command_confirmation_requires_actual_result_not_dialog_disappearance() {
    let h: Vec<serde_json::Value> =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl")
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
    assert!(!herdcats_bridge::agy::completed_call(
        &h[..14],
        "agy:13:tool:0",
        "run_command"
    ));
    assert!(herdcats_bridge::agy::completed_call(
        &h,
        "agy:13:tool:0",
        "run_command"
    ));
    assert!(herdcats_bridge::agy::completed_call(
        &h[..7],
        "agy:5:tool:0",
        "run_command"
    ));
}
#[test]
fn two_panes_in_same_folder_bind_independent_native_ids() {
    let p = root("two-panes");
    let ids = [ID, "22222222-2222-2222-2222-222222222222"];
    for (n, id) in ids.iter().enumerate() {
        let logs = p.join(id).join(".system_generated/logs");
        fs::create_dir_all(&logs).unwrap();
        fs::write(
            logs.join("transcript.jsonl"),
            format!("{{\"type\":\"USER_INPUT\",\"step_index\":0,\"content\":\"pane{n}\"}}\n"),
        )
        .unwrap();
    }
    let a = AgyAdapter::new(Some(p.clone()));
    for (n, id) in ids.iter().enumerate() {
        let pane=serde_json::from_value(serde_json::json!({"pane_id":format!("p{n}"),"terminal_id":format!("t{n}"),"agent":"agy","agent_status":"idle","cwd":"/same/folder","agent_session":{"agent":"antigravity_cli","source":"herdr:antigravity_cli","kind":"id","value":id}})).unwrap();
        let (session, file) = a.resolve_and_open(&pane).unwrap();
        let mut f = a.new_follower(true);
        f.refresh_file(file, &session).unwrap();
        assert_eq!(f.transcript.entries[0].text, format!("pane{n}"));
    }
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn pending_tool_is_not_completed_by_running_generic_or_done_planner() {
    let h: Vec<serde_json::Value> =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl")
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
    let mut t = herdcats_bridge::claude::Transcript::default();
    t.apply_agy(&h[1], 0, 100, false).unwrap();
    assert_eq!(t.entries[0].status.as_deref(), Some("running"));
    let mut r = h[2].clone();
    r["status"] = serde_json::json!("RUNNING");
    t.apply_agy(&r, 100, 100, false).unwrap();
    assert_eq!(t.entries[0].status.as_deref(), Some("running"));
    t.apply_agy(&h[2], 200, 100, false).unwrap();
    assert_eq!(t.entries[0].status.as_deref(), Some("completed"));
}
#[test]
fn intermediate_symlink_cannot_redirect_pinned_root() {
    let p = root("parent-swap");
    let dir = p.join(ID);
    let logs = dir.join(".system_generated/logs");
    fs::create_dir_all(&logs).unwrap();
    fs::write(logs.join("transcript.jsonl"), b"\n").unwrap();
    let a = AgyAdapter::new(Some(p.clone()));
    let pane=serde_json::from_value(serde_json::json!({"pane_id":"p","terminal_id":"t","agent":"agy","agent_status":"idle","agent_session":{"agent":"agy","source":"herdr:antigravity_cli","kind":"id","value":ID}})).unwrap();
    fs::rename(&dir, p.join("moved")).unwrap();
    std::os::unix::fs::symlink(p.join("moved"), &dir).unwrap();
    assert!(a.resolve_and_open(&pane).is_err());
    fs::remove_dir_all(p).unwrap();
}
#[test]
fn unfamiliar_and_thinking_content_obey_ios_wire_contract() {
    let mut t = herdcats_bridge::claude::Transcript::default();
    t.apply_agy(&serde_json::json!({"type":"PLANNER_RESPONSE","step_index":1,"thinking":"consider carefully"}),0,100,true).unwrap();
    t.apply_agy(
        &serde_json::json!({"type":"FUTURE","step_index":2,"content":"unfamiliar"}),
        100,
        100,
        true,
    )
    .unwrap();
    assert!(
        t.entries
            .iter()
            .all(|e| ["message", "tool", "image", "record"].contains(&e.kind.as_str()))
    );
    assert!(
        t.entries
            .iter()
            .filter(|e| e.kind == "record")
            .all(|e| e.content_ref.is_some())
    );
}

#[test]
fn user_metadata_envelopes_strip_only_complete_outer_wrappers_and_keep_raw_source() {
    let p = root("user-envelope");
    let file = p.join("transcript.jsonl");
    let request = "  Keep leading and trailing spaces.  \nLiteral </USER_REQUEST> remains.\n<USER_REQUEST>\nnested literal\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nliteral metadata example\n</ADDITIONAL_METADATA>";
    let wrapped = format!(
        "<USER_REQUEST>\n{request}\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nSynthetic workspace metadata\n</ADDITIONAL_METADATA>\n\n<USER_SETTINGS_CHANGE>\nSynthetic settings\n</USER_SETTINGS_CHANGE>"
    );
    let without_settings = "<USER_REQUEST>\nsecond request\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nSynthetic metadata\n</ADDITIONAL_METADATA>";
    let rows = [
        serde_json::json!({"type":"USER_INPUT","step_index":0,"content":wrapped}),
        serde_json::json!({"type":"USER_INPUT","step_index":1,"content":without_settings}),
        serde_json::json!({"type":"PLANNER_RESPONSE","step_index":2,"content":wrapped}),
    ];
    let raw = rows
        .iter()
        .map(|row| format!("{row}\n"))
        .collect::<String>();
    fs::write(&file, &raw).unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Agy);
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.transcript.entries[0].text, request);
    assert_eq!(f.transcript.entries[1].text, "second request");
    assert_eq!(f.transcript.entries[2].text, wrapped);
    let reference = &f.transcript.entries[0].record_refs[0];
    let (source, _) = f.read_content(reference, 0).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&source).unwrap(),
        rows[0]
    );
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn plain_literal_and_malformed_user_envelopes_are_unchanged() {
    let examples = [
        "plain user text",
        "<USER_REQUEST>\nliteral user tags\n</USER_REQUEST>",
        "prefix <USER_REQUEST>\nrequest\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nmetadata\n</ADDITIONAL_METADATA>",
        "<USER_REQUEST>\nrequest\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nunterminated",
        "<USER_REQUEST>\nrequest\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nmetadata\n</ADDITIONAL_METADATA>\ntrailing literal text",
        "<USER_REQUEST>\nrequest\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nmetadata\n</ADDITIONAL_METADATA>\n\n<USER_SETTINGS_CHANGE>\nunterminated",
        "<USER_REQUEST>\nrequest\n</USER_REQUEST>\n\n<ADDITIONAL_METADATA>\nmetadata\n</ADDITIONAL_METADATA>\n\n<USER_SETTINGS_CHANGE>\nx\n</USER_SETTINGS_CHANGE>\nextra",
    ];
    for (index, text) in examples.iter().enumerate() {
        let mut t = herdcats_bridge::claude::Transcript::default();
        t.apply_agy(
            &serde_json::json!({"type":"USER_INPUT","step_index":index,"content":text}),
            0,
            100,
            true,
        )
        .unwrap();
        assert_eq!(t.entries[0].text, *text);
    }
}

#[test]
fn user_envelopes_accept_live_single_newlines_double_newlines_and_crlf() {
    for newline in ["\n", "\r\n"] {
        for gap in [1, 2] {
            for settings in [false, true] {
                let request = format!("  hi  {newline}literal </USER_REQUEST>{newline}");
                let separator = newline.repeat(gap);
                let mut envelope = format!(
                    "<USER_REQUEST>{newline}{request}{newline}</USER_REQUEST>{separator}<ADDITIONAL_METADATA>{newline}synthetic metadata{newline}</ADDITIONAL_METADATA>"
                );
                if settings {
                    envelope.push_str(&format!("{separator}<USER_SETTINGS_CHANGE>{newline}synthetic settings{newline}</USER_SETTINGS_CHANGE>"));
                }
                let mut transcript = herdcats_bridge::claude::Transcript::default();
                transcript
                    .apply_agy(
                        &serde_json::json!({"type":"USER_INPUT","step_index":0,"content":envelope}),
                        0,
                        100,
                        true,
                    )
                    .unwrap();
                assert_eq!(
                    transcript.entries[0].text, request,
                    "newline={newline:?}, gap={gap}, settings={settings}"
                );
            }
        }
    }
}
