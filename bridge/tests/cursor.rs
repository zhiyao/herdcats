use herdcats_bridge::{
    adapter::Adapter,
    cursor::CursorAdapter,
    follower::{AgentType, Follower},
};
use std::{fs, io::Write, os::unix::fs::MetadataExt, path::PathBuf};
const ID: &str = "437b5e77-58e6-410f-ab91-ed34a0280045";
const OTHER: &str = "05840e65-35fe-4d90-9279-80044ea353fe";
const FIXTURE: &str =
    include_str!("../../ios/docs/research/fixtures/cursor-2026.10.22-synthetic-interactions.jsonl");
const MARKER: &str = "{\"type\":\"turn_ended\",\"status\":\"success\"}\n";
fn root(label: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!("hc-cursor-{label}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&p);
    fs::create_dir_all(&p).unwrap();
    p.canonicalize().unwrap()
}
fn user(text: &str) -> String {
    format!(
        "{}\n",
        serde_json::json!({"role":"user","message":{"content":[{"type":"text","text":
            format!("<timestamp>Tuesday, Oct 27, 2026, 9:00 AM (UTC+8)</timestamp>\n<user_query>\n{text}\n</user_query>")}]}})
    )
}
fn assistant(text: &str) -> String {
    format!(
        "{}\n",
        serde_json::json!({"role":"assistant","message":{"content":[{"type":"text","text":text}]}})
    )
}
fn pane(agent: &str, source: &str, kind: &str, value: &str) -> herdcats_bridge::herdr::Pane {
    serde_json::from_value(serde_json::json!({"pane_id":"p1","terminal_id":"t1","agent":agent,
        "agent_status":"idle","cwd":"/same/folder",
        "agent_session":{"agent":"cursor","source":source,"kind":kind,"value":value}}))
    .unwrap()
}
fn transcript(root: &std::path::Path, project: &str, id: &str) -> PathBuf {
    let dir = root.join(project).join("agent-transcripts").join(id);
    fs::create_dir_all(&dir).unwrap();
    dir.join(format!("{id}.jsonl"))
}

#[test]
fn synthetic_history_maps_messages_tools_and_hides_the_marker() {
    let p = root("fixture");
    let file = p.join("t.jsonl");
    fs::write(&file, FIXTURE).unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Cursor);
    f.refresh(&file, ID).unwrap();
    let entries = &f.transcript.entries;
    let first = &entries[0];
    assert_eq!((first.role.as_deref(), first.kind.as_str()), (Some("user"), "message"));
    assert!(first.text.starts_with("Run the shell command: printf HERDCATS_APPROVAL_PROBE_OK"));
    assert!(!first.text.contains("<user_query>") && !first.text.contains("<timestamp>"));
    // Text precedes the calls from the same record; ids are record-offset based.
    assert_eq!(entries[1].role.as_deref(), Some("assistant"));
    let shell: Vec<_> = entries.iter().filter(|e| e.tool_name.as_deref() == Some("Shell")).collect();
    assert_eq!(shell.len(), 2);
    assert!(shell[0].details.as_deref().unwrap().contains("printf HERDCATS_APPROVAL_PROBE_OK"));
    assert!(shell[1].details.as_deref().unwrap().contains("smart_mode_block_reason"));
    assert!(shell.iter().all(|e| e.status.as_deref() == Some("completed")));
    let questions: Vec<_> = entries.iter().filter(|e| e.tool_name.as_deref() == Some("AskQuestion")).collect();
    assert_eq!(questions.len(), 2);
    assert!(questions[0].details.as_deref().unwrap().contains("allow_multiple"));
    assert_eq!(f.transcript.unknown_records, 0);
    assert!(entries.iter().all(|e| !e.text.contains("turn_ended")));
    assert!(entries.iter().all(|e| e.id.starts_with("cursor:")));
    let ids: std::collections::HashSet<_> = entries.iter().map(|e| &e.id).collect();
    assert_eq!(ids.len(), entries.len());
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn trailing_turn_ended_overwritten_in_place_is_not_a_rewrite() {
    let p = root("marker");
    let file = p.join("t.jsonl");
    let first = format!("{}{}", user("one"), assistant("ONE"));
    fs::write(&file, format!("{first}{MARKER}")).unwrap();
    let mut f = Follower::with_content_for_agent(AgentType::Cursor);
    assert!(f.refresh(&file, ID).unwrap());
    let generation = f.generation;
    let inode = fs::metadata(&file).unwrap().ino();
    assert_eq!(f.offset as usize, first.len(), "marker is never consumed");
    // Nothing changed: the unchanged marker causes no work and no change.
    assert!(!f.refresh(&file, ID).unwrap());
    // Same inode, as observed live: the next prompt overwrites the marker line.
    let next = user("two");
    let mut handle = fs::OpenOptions::new().write(true).open(&file).unwrap();
    std::io::Seek::seek(&mut handle, std::io::SeekFrom::Start(first.len() as u64)).unwrap();
    handle.write_all(next.as_bytes()).unwrap();
    handle.set_len((first.len() + next.len()) as u64).unwrap();
    assert_eq!(fs::metadata(&file).unwrap().ino(), inode);
    assert!(f.refresh(&file, ID).unwrap());
    assert_eq!(f.generation, generation, "overwriting the marker must not reset");
    let texts: Vec<_> = f.transcript.entries.iter().map(|e| e.text.as_str()).collect();
    assert_eq!(texts, ["one", "ONE", "two"]);
    // The finished turn appends another marker, again held back.
    let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
    handle.write_all(assistant("TWO").as_bytes()).unwrap();
    handle.write_all(MARKER.as_bytes()).unwrap();
    assert!(f.refresh(&file, ID).unwrap());
    assert_eq!(f.generation, generation);
    assert_eq!(f.transcript.entries.len(), 4);
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn torn_final_line_is_held_back_but_a_bad_middle_line_fails() {
    let p = root("torn");
    let file = p.join("t.jsonl");
    let first = format!("{}{}", user("one"), assistant("ONE"));
    // A write observed mid-overwrite: new bytes followed by the old marker tail.
    let torn = format!("{first}{{\"role\":\"user\",\"mes{}", &MARKER[20..]);
    fs::write(&file, &torn).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.transcript.entries.len(), 2);
    let generation = f.generation;
    fs::write(&file, format!("{first}{}{MARKER}", user("two"))).unwrap();
    assert!(f.refresh(&file, ID).unwrap());
    assert_eq!(f.generation, generation);
    assert_eq!(f.transcript.entries.len(), 3);
    // Garbage with a complete record after it is real corruption.
    fs::write(&file, format!("{first}not json\n{}", assistant("late"))).unwrap();
    assert_eq!(f.refresh(&file, ID), Err("invalid_transcript"));
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn shrinking_below_consumed_prefix_or_editing_it_resets_generation() {
    let p = root("reset");
    let file = p.join("t.jsonl");
    let body = format!("{}{}", user("one"), assistant("ONE"));
    fs::write(&file, format!("{body}{MARKER}")).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    f.refresh(&file, ID).unwrap();
    let generation = f.generation;
    fs::write(&file, user("one")).unwrap();
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.generation, generation + 1);
    fs::write(&file, user("edited")).unwrap();
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.generation, generation + 2);
    assert_eq!(f.transcript.entries[0].text, "edited");
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn action_guard_accepts_marker_rewrite_but_rejects_prefix_edits() {
    let p = root("verify");
    let file = p.join("t.jsonl");
    let body = user("old");
    fs::write(&file, format!("{body}{MARKER}")).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    f.refresh(&file, ID).unwrap();
    assert!(f.verify_source(fs::File::open(&file).unwrap()).is_ok());
    fs::write(&file, format!("{body}{}", assistant("more"))).unwrap();
    assert!(f.verify_source(fs::File::open(&file).unwrap()).is_ok());
    fs::write(&file, user("new")).unwrap();
    assert!(f.verify_source(fs::File::open(&file).unwrap()).is_err());
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn user_envelope_strips_only_the_complete_outer_wrapper() {
    let p = root("envelope");
    let file = p.join("t.jsonl");
    let literal = "keep </user_query> and <timestamp>x</timestamp> inside\n  spaces  ";
    let verbatim = [
        "plain text without a wrapper",
        "<user_query>\nunterminated",
        "<timestamp>t</timestamp>\n<user_query>\nbody\n</user_query>\ntrailing",
        "<timestamp>multi\nline</timestamp>\n<user_query>\nbody\n</user_query>",
    ];
    let mut raw = user(literal);
    for text in verbatim {
        raw.push_str(&format!(
            "{}\n",
            serde_json::json!({"role":"user","message":{"content":[{"type":"text","text":text}]}})
        ));
    }
    fs::write(&file, raw).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    f.refresh(&file, ID).unwrap();
    assert_eq!(f.transcript.entries[0].text, literal);
    for (i, text) in verbatim.iter().enumerate() {
        assert_eq!(f.transcript.entries[i + 1].text, *text);
    }
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn unfamiliar_records_and_blocks_are_counted_and_preserved_only_with_content() {
    let p = root("unknown");
    let file = p.join("t.jsonl");
    let raw = format!(
        "{}{}{}{}",
        user("hi"),
        serde_json::json!({"role":"assistant","message":{"content":[
            {"type":"thinking","thinking":"hmm"},{"type":"text","text":"answer"}]}}),
        "\n{\"type\":\"future\",\"x\":1}\n",
        serde_json::json!({"role":"tool","message":{"content":[]}}).to_string() + "\n",
    );
    fs::write(&file, &raw).unwrap();
    let mut plain = Follower::for_agent(AgentType::Cursor);
    plain.refresh(&file, ID).unwrap();
    assert_eq!(plain.transcript.unknown_records, 3);
    assert!(plain.transcript.entries.iter().all(|e| e.kind == "message"));
    let mut rich = Follower::with_content_for_agent(AgentType::Cursor);
    rich.refresh(&file, ID).unwrap();
    let records: Vec<_> = rich.transcript.entries.iter().filter(|e| e.kind == "record").collect();
    assert_eq!(records.len(), 3);
    assert!(records.iter().all(|e| e.content_ref.is_some()));
    let (bytes, _) = rich.read_content(records[1].content_ref.as_ref().unwrap(), 0).unwrap();
    assert!(String::from_utf8(bytes).unwrap().contains("future"));
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn oversized_and_excessive_calls_are_hard_errors() {
    let p = root("limits");
    let file = p.join("t.jsonl");
    fs::write(&file, assistant(&"x".repeat(1024 * 1024 + 1))).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    assert_eq!(f.refresh(&file, ID), Err("record_too_large"));
    let calls: Vec<_> = (0..129).map(|_| serde_json::json!({"type":"tool_use","name":"Shell","input":{}})).collect();
    fs::write(&file, format!("{}\n", serde_json::json!({"role":"assistant","message":{"content":calls}}))).unwrap();
    let mut f = Follower::for_agent(AgentType::Cursor);
    assert_eq!(f.refresh(&file, ID), Err("transcript_identity_limit"));
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn lookup_is_by_exact_chat_id_across_projects_and_never_by_slug_or_mtime() {
    let p = root("lookup");
    // Two panes in one folder bind to distinct chats, whatever the project name.
    fs::write(transcript(&p, "private-tmp-same-folder", ID), user("pane0")).unwrap();
    fs::write(transcript(&p, "private-tmp-same-folder-1234567", OTHER), user("pane1")).unwrap();
    // A different project with a newer file must not win.
    fs::write(transcript(&p, "decoy", "11111111-1111-1111-1111-111111111111"), user("decoy")).unwrap();
    let a = CursorAdapter::new(Some(p.clone()));
    for (n, id) in [ID, OTHER].iter().enumerate() {
        let (session, file) = a
            .resolve_and_open(&pane("cursor", "herdr:cursor", "id", id))
            .unwrap();
        assert_eq!(session, *id);
        let mut f = a.new_follower(true);
        f.refresh_file(file, &session).unwrap();
        assert_eq!(f.transcript.entries[0].text, format!("pane{n}"));
    }
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn duplicate_chat_ids_are_ambiguous_and_delayed_creation_recovers() {
    let p = root("ambiguous");
    let a = CursorAdapter::new(Some(p.clone()));
    let pane = pane("cursor", "herdr:cursor", "id", ID);
    assert_eq!(a.resolve_and_open(&pane).err(), Some("transcript_unavailable"));
    fs::write(transcript(&p, "one", ID), user("a")).unwrap();
    assert!(a.resolve_and_open(&pane).is_ok());
    fs::write(transcript(&p, "two", ID), user("b")).unwrap();
    assert_eq!(a.resolve_and_open(&pane).err(), Some("ambiguous_session"));
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn identity_fields_are_exact_and_missing_sessions_fail_closed() {
    let p = root("identity");
    fs::write(transcript(&p, "proj", ID), user("a")).unwrap();
    let a = CursorAdapter::new(Some(p.clone()));
    assert!(a.supports("cursor") && !a.supports("agy") && !a.supports("Cursor"));
    assert!(a.resolve_and_open(&pane("cursor", "herdr:cursor", "id", ID)).is_ok());
    let err = |pane| a.resolve_and_open(&pane).err();
    assert_eq!(err(pane("cursor", "herdr:agy", "id", ID)), Some("unsupported_session_source"));
    assert_eq!(err(pane("cursor", "herdr:cursor", "path", ID)), Some("invalid_session_reference"));
    assert_eq!(err(pane("cursor", "herdr:cursor", "id", "../../etc/passwd")), Some("invalid_session_reference"));
    assert_eq!(err(pane("claude", "herdr:cursor", "id", ID)), Some("unsupported_agent"));
    let mut wrong_agent = pane("cursor", "herdr:cursor", "id", ID);
    wrong_agent.agent_session.as_mut().unwrap().agent = "claude".into();
    assert_eq!(err(wrong_agent), Some("unsupported_session_source"));
    // After `--resume` Herdr reports no session; no guess is made from the cwd.
    let mut resumed = pane("cursor", "herdr:cursor", "id", ID);
    resumed.agent_session = None;
    assert_eq!(err(resumed), Some("session_reference_unavailable"));
    fs::remove_dir_all(p).unwrap();
}

#[test]
fn symlinks_cannot_redirect_the_pinned_root_or_the_transcript() {
    let p = root("symlink");
    let outside = root("symlink-outside");
    fs::write(transcript(&outside, "proj", ID), user("outside")).unwrap();
    let a = CursorAdapter::new(Some(p.clone()));
    let pane = pane("cursor", "herdr:cursor", "id", ID);
    // A project directory that is a symlink is never traversed.
    std::os::unix::fs::symlink(outside.join("proj"), p.join("linked")).unwrap();
    assert_eq!(a.resolve_and_open(&pane).err(), Some("transcript_unavailable"));
    // Nor is a symlinked transcript file.
    let real = transcript(&p, "proj", ID);
    std::os::unix::fs::symlink(outside.join("proj/agent-transcripts").join(ID).join(format!("{ID}.jsonl")), &real).unwrap();
    assert_eq!(a.resolve_and_open(&pane).err(), Some("transcript_unavailable"));
    fs::remove_file(&real).unwrap();
    fs::write(&real, user("inside")).unwrap();
    assert!(a.resolve_and_open(&pane).is_ok());
    // Renaming the root and planting a symlink cannot redirect the pinned anchor.
    let moved = p.with_extension("moved");
    fs::rename(&p, &moved).unwrap();
    std::os::unix::fs::symlink(outside.clone(), &p).unwrap();
    let mut f = a.new_follower(false);
    let (session, file) = a.resolve_and_open(&pane).unwrap();
    f.refresh_file(file, &session).unwrap();
    assert_eq!(f.transcript.entries[0].text, "inside");
    fs::remove_file(&p).unwrap();
    fs::remove_dir_all(moved).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn unavailable_root_is_reported_and_retried() {
    let p = root("late-root");
    let missing = p.join("projects");
    let a = CursorAdapter::new(Some(missing.clone()));
    assert!(a.is_available());
    let pane = pane("cursor", "herdr:cursor", "id", ID);
    assert_eq!(a.resolve_and_open(&pane).err(), Some("transcript_root_unavailable"));
    fs::create_dir_all(&missing).unwrap();
    fs::write(transcript(&missing, "proj", ID), user("later")).unwrap();
    assert!(a.resolve_and_open(&pane).is_ok());
    assert!(!CursorAdapter::new(None).is_available());
    fs::remove_dir_all(p).unwrap();
}
