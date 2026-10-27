fn cursor_fixture() -> (Service, PathBuf, SharedHerdr, PathBuf) {
    let (service, root, session, herdr) = fixture_with_herdr();
    let projects = root.join("cursor-projects");
    let id = session.lock().unwrap().clone();
    let dir = projects.join("some-hashed-slug-1234567/agent-transcripts").join(&id);
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join(format!("{id}.jsonl"));
    fs::write(
        &file,
        include_bytes!("../../ios/docs/research/fixtures/cursor-2026.10.22-synthetic-interactions.jsonl"),
    )
    .unwrap();
    herdr.lock().unwrap().agent = Some("cursor".into());
    let mut service = service.with_cursor_root(projects.canonicalize().unwrap());
    service.include_content = true;
    service.include_approvals = true;
    service.include_questions = true;
    (service, root, herdr, file)
}
#[test]
fn cursor_timeline_binds_the_exact_chat_and_streams_the_fixture() {
    let (mut service, root, _herdr, _file) = cursor_fixture();
    let mut out = Vec::new();
    service.poll(&mut out).unwrap();
    let watch = service.watch.as_ref().unwrap();
    let identity = watch.identity.as_ref().unwrap();
    assert_eq!(identity.agent, "cursor");
    assert_eq!(identity.native_session_id, SESSION);
    assert!(watch.previous.iter().any(|e| e.tool_name.as_deref() == Some("AskQuestion")));
    assert!(watch.previous[0].text.starts_with("Run the shell command"));
    let frames = String::from_utf8(out).unwrap();
    assert!(frames.contains("\"timeline.snapshot\"") && frames.contains("\"agent\":\"cursor\""));
    cleanup(&service, root);
}
#[test]
fn cursor_turn_marker_overwrite_streams_an_update_without_a_new_generation() {
    let (mut service, root, _herdr, file) = cursor_fixture();
    let finished = fs::read_to_string(&file).unwrap();
    let marker = "{\"type\":\"turn_ended\",\"status\":\"success\"}\n";
    assert!(finished.ends_with(marker));
    service.poll(&mut Vec::new()).unwrap();
    let generation = service.generation;
    let before = service.watch.as_ref().unwrap().previous.len();
    let next = format!(
        "{}\n",
        json!({"role":"user","message":{"content":[{"type":"text","text":"<user_query>\nnext\n</user_query>"}]}})
    );
    let body = &finished[..finished.len() - marker.len()];
    fs::write(&file, format!("{body}{next}")).unwrap();
    let mut out = Vec::new();
    service.poll(&mut out).unwrap();
    assert_eq!(service.generation, generation);
    let watch = service.watch.as_ref().unwrap();
    assert_eq!(watch.previous.len(), before + 1);
    assert_eq!(watch.previous.last().unwrap().text, "next");
    assert!(String::from_utf8(out).unwrap().contains("\"timeline.updated\""));
    cleanup(&service, root);
}
#[test]
fn cursor_session_replacement_missing_session_and_delayed_creation_fail_closed() {
    let (mut service, root, herdr, file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let original = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let other = "33333333-3333-3333-3333-333333333333";
    // Herdr moved the pane to a chat whose transcript does not exist yet.
    herdr.lock().unwrap().session_override = Some(other.into());
    let generation = service.generation;
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().identity.is_none());
    assert_eq!(service.watch.as_ref().unwrap().unavailable, Some("transcript_unavailable"));
    assert!(service.generation > generation);
    // The chat's transcript appears later: the timeline recovers on its own.
    let dir = file.ancestors().nth(4).unwrap().join("p2/agent-transcripts").join(other);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(format!("{other}.jsonl")),
        "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"independent\"}]}}\n",
    )
    .unwrap();
    service.poll(&mut Vec::new()).unwrap();
    let watch = service.watch.as_ref().unwrap();
    assert!(watch.identity.as_ref() != Some(&original));
    assert_eq!(watch.previous[0].text, "independent");
    cleanup(&service, root);
}
#[test]
fn cursor_never_advertises_cards_or_model_control_before_those_sections() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.include_model_control = true;
    {
        let mut state = herdr.lock().unwrap();
        state.status = Some("blocked".into());
        state.screen = " $  printf X in .\n\n Run this command?\n  → Run (once) (y)\n    Skip & tell the agent what to do instead (esc or n)".into();
    }
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    assert!(service.model_status().is_err());
    assert!(herdr.lock().unwrap().keys.is_empty());
    cleanup(&service, root);
}
#[test]
fn cursor_capability_follows_adapter_availability() {
    let (mut service, root, _herdr, _file) = cursor_fixture();
    let mut out = Vec::new();
    service
        .request(br#"{"id":"i","method":"initialize","params":{"protocol":1}}"#, &mut out)
        .unwrap();
    let reply: Value = serde_json::from_slice(out.split(|b| *b == b'\n').next().unwrap()).unwrap();
    assert_eq!(reply["result"]["capabilities"]["cursor"], true);
    assert!(Service::new(root.join("h.sock"), root.join("projects")).adapter_for("cursor").is_some());
    cleanup(&service, root);
}
