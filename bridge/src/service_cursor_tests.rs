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

const CURSOR_RULE: &str = "───────────────────────────────────────────────────────────────────────────";
const CURSOR_TOP: &str = " ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄";
const CURSOR_BOTTOM: &str = " ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀";
const CURSOR_FOOTER: &str = "  Claude Opus 5.5 300K Medium · 8.4%\n  /private/tmp/herdcats-cursor-probe";
fn cursor_card(command: &str, selected: usize) -> String {
    let rows = ["Run (once) (y)", "Add Shell(printf) to allowlist? (tab)", "Run Everything (shift+tab)", "Skip & tell the agent what to do instead (esc or n)"];
    let options: Vec<_> = rows.iter().enumerate()
        .map(|(i, label)| format!("{}{label}", if i == selected { "  → " } else { "    " })).collect();
    format!("\n  $ {command} Waiting for approval...\n\n{CURSOR_RULE}\n $  {command} in .\n\n Run this command?\n Shell allowlist is empty\n{}\n", options.join("\n"))
}
/// (plain, styled) idle composer; the placeholder is faint like the real one.
fn cursor_idle() -> (String, String) {
    let plain = format!("\n  PONG\n\n{CURSOR_TOP}\n  → Add a follow-up\n{CURSOR_BOTTOM}\n{CURSOR_FOOTER}");
    let bg = "\u{1b}[48;2;47;50;57m";
    let row = format!(" \u{1b}[0m{bg} \u{1b}[0m\u{1b}[2m{bg}→ \u{1b}[0m\u{1b}[7m{bg}A\u{1b}[0m\u{1b}[2m{bg}dd a follow-up\u{1b}[0m{bg}   \u{1b}[0m");
    let styled = plain.replace("  → Add a follow-up", &row);
    (plain, styled)
}
fn cursor_draft() -> (String, String) {
    let plain = format!("\n  PONG\n\n{CURSOR_TOP}\n  → half-typed message\n{CURSOR_BOTTOM}\n{CURSOR_FOOTER}");
    (plain.clone(), plain)
}
const CURSOR_QUESTION: &str = "\n ┌───────────────────────────────────────────────────────────────────────┐\n │ README clarifications                                                 │\n │ Question 1 of 2                                                       │\n │   › [ ] Alpha                                                         │\n │ ↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to │\n │ skip                                                                  │\n └───────────────────────────────────────────────────────────────────────┘";
fn prompt_params(service: &Service, text: &str) -> Value {
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    json!({"text":text,"expect":{"identity":identity,"generation":service.generation}})
}
fn prompts(herdr: &SharedHerdr) -> usize {
    herdr.lock().unwrap().inputs.iter().filter(|i| i["method"] == "agent.prompt").count()
}
fn set_screen(herdr: &SharedHerdr, status: &str, plain: &str, styled: &str) {
    let mut state = herdr.lock().unwrap();
    state.status = Some(status.into());
    state.screen = plain.into();
    state.ansi_screen = Some(styled.into());
    state.allow_question_input = true;
}

#[test]
fn cursor_prompt_needs_an_idle_empty_composer_on_screen() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let (plain, styled) = cursor_idle();
    set_screen(&herdr, "idle", &plain, &styled);
    let reply = service.prompt_submit(&prompt_params(&service, "hello there")).unwrap();
    assert_eq!(reply["submitted"], true);
    assert_eq!(prompts(&herdr), 1);
    let sent = herdr.lock().unwrap().inputs.iter().find(|i| i["method"] == "agent.prompt").cloned().unwrap();
    assert_eq!(sent["params"]["text"], "hello there");
    // Herdr's `done` is as good as `idle`; both still require the screen.
    set_screen(&herdr, "done", &plain, &styled);
    assert!(service.prompt_submit(&prompt_params(&service, "again")).is_ok());
    assert_eq!(prompts(&herdr), 2);
    cleanup(&service, root);
}

#[test]
fn cursor_pending_approval_card_blocks_prompts_whatever_herdr_reports() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let card = cursor_card("printf X", 0);
    for status in ["blocked", "idle", "done", "working"] {
        set_screen(&herdr, status, &card, &card);
        let err = service.prompt_submit(&prompt_params(&service, "run it")).unwrap_err();
        assert!(["approval_pending", "agent_busy"].contains(&err), "{status}: {err}");
        if status == "idle" || status == "done" { assert_eq!(err, "approval_pending"); }
    }
    // The skip feedback input and an unsupported card are pending decisions too.
    for screen in ["  Tell the agent what to do instead (Enter to send,\n  empty to skip, Esc to cancel)", "\n Run this command?\n Shell allowlist: ls\n  → Run (once) (y)"] {
        set_screen(&herdr, "done", screen, screen);
        assert_eq!(service.prompt_submit(&prompt_params(&service, "x")).unwrap_err(), "approval_pending");
    }
    assert_eq!(prompts(&herdr), 0, "nothing may be typed into a pending card");
    cleanup(&service, root);
}

#[test]
fn cursor_pending_question_form_blocks_prompts_even_when_herdr_says_done() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    for status in ["done", "idle"] {
        set_screen(&herdr, status, CURSOR_QUESTION, CURSOR_QUESTION);
        assert_eq!(service.prompt_submit(&prompt_params(&service, "answer")).unwrap_err(), "question_pending");
    }
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);
}

#[test]
fn cursor_prompts_fail_closed_on_drafts_busy_pickers_and_unknown_screens() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let (draft, styled) = cursor_draft();
    let (idle_plain, _) = cursor_idle();
    let cases = [
        (draft.as_str(), styled.as_str(), "composer_not_empty"),
        // Unstyled placeholder text cannot be told from a draft.
        (idle_plain.as_str(), idle_plain.as_str(), "composer_not_empty"),
        ("  → Add a follow-up   ctrl+c to stop", "  → Add a follow-up   ctrl+c to stop", "screen_unrecognized"),
        (" Available models\n Type to filter • Enter to select", " Available models\n Type to filter • Enter to select", "picker_open"),
        ("$ ls\nfoo", "$ ls\nfoo", "screen_unrecognized"),
        ("", "", "screen_unrecognized"),
    ];
    for (plain, styled, code) in cases {
        set_screen(&herdr, "idle", plain, styled);
        assert_eq!(service.prompt_submit(&prompt_params(&service, "hi")).unwrap_err(), code);
    }
    // A running turn is refused by status before the screen is even read.
    let (plain, styled) = cursor_idle();
    set_screen(&herdr, "working", &plain, &styled);
    assert_eq!(service.prompt_submit(&prompt_params(&service, "hi")).unwrap_err(), "agent_busy");
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);
}

#[test]
fn cursor_prompts_refuse_slash_commands_and_stale_scope_without_touching_the_pane() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let (plain, styled) = cursor_idle();
    set_screen(&herdr, "idle", &plain, &styled);
    for text in ["/model grok-4.7", "  /quit", "\n/new"] {
        assert_eq!(service.prompt_submit(&prompt_params(&service, text)).unwrap_err(), "slash_command_refused");
    }
    // A slash later in the text is ordinary prose.
    assert!(service.prompt_submit(&prompt_params(&service, "use a/b and /tmp")).is_ok());
    for bad in ["", "   ", "a\0b"] {
        assert_eq!(service.prompt_submit(&prompt_params(&service, bad)).unwrap_err(), "invalid_request");
    }
    let mut stale = prompt_params(&service, "hi");
    stale["expect"]["generation"] = json!(service.generation + 1);
    assert_eq!(service.prompt_submit(&stale).unwrap_err(), "stale");
    let mut other = prompt_params(&service, "hi");
    other["expect"]["identity"]["native_session_id"] = json!("33333333-3333-3333-3333-333333333333");
    assert_eq!(service.prompt_submit(&other).unwrap_err(), "stale");
    let mut huge = prompt_params(&service, &"x".repeat(65_537));
    assert_eq!(service.prompt_submit(&huge).unwrap_err(), "invalid_request");
    huge["text"] = json!(5);
    assert_eq!(service.prompt_submit(&huge).unwrap_err(), "invalid_request");
    assert_eq!(prompts(&herdr), 1, "only the prose prompt was typed");
    cleanup(&service, root);
}

#[test]
fn cursor_prompt_is_cursor_only() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    herdr.lock().unwrap().agent = Some("claude".into());
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.prompt_submit(&json!({"text":"hi"})).is_err());
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);
}

fn cursor_pending_fixture() -> (Service, PathBuf, SharedHerdr, PathBuf, String) {
    let (mut service, root, herdr, file) = cursor_fixture();
    let user = "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<user_query>\\nrun it\\n</user_query>\"}]}}\n";
    fs::write(&file, user).unwrap();
    let card = cursor_card("printf HERDCATS_CURSOR_PROBE", 0);
    set_screen(&herdr, "blocked", &card, &card);
    service.poll(&mut Vec::new()).unwrap();
    (service, root, herdr, file, user.into())
}
fn cursor_tool_record(command: &str) -> String {
    format!("{}\n", json!({"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":command}}]}}))
}

#[test]
fn cursor_card_is_advertised_from_the_screen_with_only_phone_safe_rows() {
    let (service, root, _herdr, file, user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().expect("pending card") else { panic!() };
    assert_eq!(pending.request.request_id, format!("cursor:{}:{:016x}", user.len(), {
        "printf HERDCATS_CURSOR_PROBE".bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3))
    }));
    let data = PendingInteraction::Approval(PendingApproval {
        identity: pending.identity.clone(), generation: pending.generation,
        request: pending.request.clone(), dialog: pending.dialog.clone(),
    }).data();
    assert_eq!(data["agent"], "cursor");
    assert_eq!(data["command"], "printf HERDCATS_CURSOR_PROBE");
    assert_eq!(data["selected"], 0);
    let numbers: Vec<_> = data["options"].as_array().unwrap().iter().map(|o| o["number"].as_u64().unwrap()).collect();
    assert_eq!(numbers, [1, 4], "allowlist and Run Everything stay in Terminal");
    assert_eq!(data["options"][0]["label_lines"], json!(["Run (once) (y)"]));
    assert_eq!(data["options"][1]["label_lines"], json!(["Skip & tell the agent what to do instead (esc or n)"]));
    assert!(data["options"].as_array().unwrap().iter().all(|o| o["key"] == "navigate"));
    let _ = file;
    cleanup(&service, root);
}

#[test]
fn cursor_unsupported_or_wrapped_cards_are_not_advertised() {
    let (mut service, root, herdr, file) = cursor_fixture();
    let _ = file;
    let wrapped = cursor_card("printf 'A B", 0).replace(" in .\n", "\n    C D' in .\n");
    set_screen(&herdr, "blocked", &wrapped, &wrapped);
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    cleanup(&service, root);
}

#[test]
fn cursor_run_once_sends_one_guarded_enter_and_confirms_by_screen_and_record() {
    let (service, root, herdr, file, user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().unwrap() else { panic!() };
    let (idle_plain, idle_styled) = cursor_idle();
    {
        let mut state = herdr.lock().unwrap();
        state.screens_after_input.push_back(std::collections::VecDeque::from([idle_plain.clone()]));
        state.ansi_screen = Some(idle_styled);
        state.transcript_after_inputs = Some((1, file.clone(), format!("{user}{}", cursor_tool_record("printf HERDCATS_CURSOR_PROBE"))));
    }
    let params = json!({"request_id":pending.request.request_id,"option":1,"label_lines":["Run (once) (y)"]});
    let reply = service.respond_interaction(&params).unwrap();
    assert_eq!(reply["sent"], "navigate");
    assert_eq!(reply["confirmed"], true);
    let keys: Vec<_> = herdr.lock().unwrap().keys.iter().map(|k| k["keys"][0].as_str().unwrap().to_owned()).collect();
    assert_eq!(keys, ["enter"]);
    cleanup(&service, root);
}

#[test]
fn cursor_card_that_clears_without_a_matching_record_is_unconfirmed() {
    let (service, root, herdr, _file, _user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().unwrap() else { panic!() };
    let (idle_plain, _) = cursor_idle();
    herdr.lock().unwrap().screens_after_input.push_back(std::collections::VecDeque::from([idle_plain]));
    let params = json!({"request_id":pending.request.request_id,"option":1,"label_lines":["Run (once) (y)"]});
    let started = Instant::now();
    let reply = service.respond_interaction(&params).unwrap();
    assert_eq!(reply["confirmed"], false);
    assert!(started.elapsed() >= Duration::from_secs(4), "waits the full record window");
    cleanup(&service, root);
}

#[test]
fn cursor_skip_walks_down_then_submits_the_empty_feedback_input() {
    let (service, root, herdr, file, user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().unwrap() else { panic!() };
    let (idle_plain, idle_styled) = cursor_idle();
    let feedback = "\n │ $  printf HERDCATS_CURSOR_PROBE in .                                  │\n └───────────────────────────────────────────────────────────────────────┘\n ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n  → Tell the agent what to do instead (Enter to send,      ctrl+c to stop\n    empty to skip, Esc to cancel)\n ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀";
    {
        let mut state = herdr.lock().unwrap();
        for n in 1..4 {
            state.screens_after_input.push_back(std::collections::VecDeque::from([cursor_card("printf HERDCATS_CURSOR_PROBE", n)]));
        }
        state.screens_after_input.push_back(std::collections::VecDeque::from([feedback.to_owned()]));
        state.screens_after_input.push_back(std::collections::VecDeque::from([idle_plain.clone()]));
        state.ansi_screen = Some(idle_styled);
        state.transcript_after_inputs = Some((5, file.clone(), format!("{user}{}", cursor_tool_record("printf HERDCATS_CURSOR_PROBE"))));
    }
    let params = json!({"request_id":pending.request.request_id,"option":4,
        "label_lines":["Skip & tell the agent what to do instead (esc or n)"]});
    let reply = service.respond_interaction(&params).unwrap();
    assert_eq!(reply["confirmed"], true);
    let keys: Vec<_> = herdr.lock().unwrap().keys.iter().map(|k| k["keys"][0].as_str().unwrap().to_owned()).collect();
    assert_eq!(keys, ["down", "down", "down", "enter", "enter"]);
    cleanup(&service, root);
}

#[test]
fn cursor_hidden_scopes_and_label_mismatches_never_send_a_key() {
    let (service, root, herdr, _file, _user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().unwrap() else { panic!() };
    let id = &pending.request.request_id;
    for params in [
        json!({"request_id":id,"option":2,"label_lines":["Add Shell(printf) to allowlist? (tab)"]}),
        json!({"request_id":id,"option":3,"label_lines":["Run Everything (shift+tab)"]}),
        json!({"request_id":id,"option":1,"label_lines":["Run Everything (shift+tab)"]}),
        json!({"request_id":id,"option":1}),
        json!({"request_id":id,"option":9,"label_lines":["Run (once) (y)"]}),
        json!({"request_id":"cursor:0:0","option":1,"label_lines":["Run (once) (y)"]}),
    ] {
        assert!(service.respond_interaction(&params).is_err(), "{params}");
    }
    assert!(herdr.lock().unwrap().keys.is_empty());
    cleanup(&service, root);
}

#[test]
fn cursor_response_is_stale_when_the_card_changed_or_vanished() {
    let (service, root, herdr, _file, _user) = cursor_pending_fixture();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().unwrap() else { panic!() };
    let params = json!({"request_id":pending.request.request_id,"option":1,"label_lines":["Run (once) (y)"]});
    // The desk user moved on to a different command's card.
    let other = cursor_card("rm -rf other", 0);
    set_screen(&herdr, "blocked", &other, &other);
    assert_eq!(service.respond_interaction(&params).unwrap_err().data()["code"], "stale");
    // The card disappeared (answered at the desk).
    let (idle, _) = cursor_idle();
    set_screen(&herdr, "blocked", &idle, &idle);
    assert!(service.respond_interaction(&params).is_err());
    // The pane no longer reports blocked.
    let card = cursor_card("printf HERDCATS_CURSOR_PROBE", 0);
    set_screen(&herdr, "working", &card, &card);
    assert!(service.respond_interaction(&params).is_err());
    assert!(herdr.lock().unwrap().keys.is_empty());
    cleanup(&service, root);
}

#[test]
fn cursor_identical_retry_card_gets_a_new_request_id_once_the_record_lands() {
    let (mut service, root, herdr, file, user) = cursor_pending_fixture();
    let first = match service.watch.as_ref().unwrap().pending.as_ref().unwrap() {
        PendingInteraction::Approval(p) => p.request.request_id.clone(),
        _ => panic!(),
    };
    fs::write(&file, format!("{user}{}", cursor_tool_record("printf HERDCATS_CURSOR_PROBE"))).unwrap();
    let card = cursor_card("printf HERDCATS_CURSOR_PROBE", 0);
    set_screen(&herdr, "blocked", &card, &card);
    service.poll(&mut Vec::new()).unwrap();
    let second = match service.watch.as_ref().unwrap().pending.as_ref().unwrap() {
        PendingInteraction::Approval(p) => p.request.request_id.clone(),
        _ => panic!(),
    };
    assert_ne!(first, second);
    cleanup(&service, root);
}

#[test]
fn cursor_ready_guard_for_model_changes_also_requires_agent_mode() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let (plain, styled) = cursor_idle();
    set_screen(&herdr, "idle", &plain, &styled);
    assert!(service.cursor_ready(&identity, true).is_ok());
    // Plan, Ask and Debug modes change what a model switch means: refused.
    let plan = plain.replace(CURSOR_FOOTER, &format!("  Plan (shift+tab to cycle)\n{CURSOR_FOOTER}"));
    let plan_styled = styled.replace(CURSOR_FOOTER, &format!("  Plan (shift+tab to cycle)\n{CURSOR_FOOTER}"));
    set_screen(&herdr, "idle", &plan, &plan_styled);
    assert_eq!(service.cursor_ready(&identity, true).unwrap_err(), "mode_not_agent");
    assert!(service.cursor_ready(&identity, false).is_ok(), "prompts are fine in any mode");
    // A pending card or form blocks both.
    for (screen, code) in [(cursor_card("printf X", 0), "approval_pending"), (CURSOR_QUESTION.to_owned(), "question_pending")] {
        set_screen(&herdr, "done", &screen, &screen);
        assert_eq!(service.cursor_ready(&identity, true).unwrap_err(), code);
        assert_eq!(service.cursor_ready(&identity, false).unwrap_err(), code);
    }
    cleanup(&service, root);
}

#[test]
fn cursor_card_with_a_non_empty_allowlist_notice_is_advertised() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    let card = cursor_card("printf HERDCATS_CURSOR_PROBE", 0)
        .replace("Shell allowlist is empty", "Not in allowlist: printf");
    set_screen(&herdr, "blocked", &card, &card);
    service.poll(&mut Vec::new()).unwrap();
    let PendingInteraction::Approval(pending) = service.watch.as_ref().unwrap().pending.as_ref().expect("pending card") else { panic!() };
    assert_eq!(pending.dialog.reason_lines, ["Not in allowlist: printf"]);
    assert_eq!(pending.request.tool_input["command"], "printf HERDCATS_CURSOR_PROBE");
    cleanup(&service, root);
}

const FORM_TOP: &str = " ┌───────────────────────────────────────────────────────────────────────┐";
const FORM_BOTTOM: &str = " └───────────────────────────────────────────────────────────────────────┘";
fn form_row(text: &str) -> String { format!(" │ {text:<69} │") }
fn cursor_form(position: &str, prompt: &str, options: &[&str]) -> String {
    let mut rows = vec![FORM_TOP.to_owned(), form_row("README clarifications"), form_row(""), form_row(position), form_row(""), form_row(prompt), form_row("")];
    rows.extend(options.iter().map(|o| form_row(o)));
    rows.push(form_row(""));
    rows.push(form_row("↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to"));
    rows.push(form_row("skip"));
    rows.push(FORM_BOTTOM.to_owned());
    format!("\n  Asking.\n\n{}", rows.join("\n"))
}
fn q1(cursor: usize, checked: &[usize], other: &str) -> String {
    let labels = ["Alpha", "Beta"];
    let mut rows: Vec<String> = labels.iter().enumerate().map(|(i, l)| format!("{}[{}] {l}", if i + 1 == cursor { "  › " } else { "    " }, if checked.contains(&(i + 1)) { 'x' } else { ' ' })).collect();
    rows.push(format!("{}[{}] Other: {other}", if cursor == 3 { "  › " } else { "    " }, if checked.contains(&3) { 'x' } else { ' ' }));
    let refs: Vec<&str> = rows.iter().map(String::as_str).collect();
    cursor_form("Question 1 of 2", "1. Which label?", &refs)
}
fn q2(cursor: usize, checked: &[usize]) -> String {
    let labels = ["One", "Two", "Three"];
    let mut rows: Vec<String> = labels.iter().enumerate().map(|(i, l)| format!("{}[{}] {l}", if i + 1 == cursor { "  › " } else { "    " }, if checked.contains(&(i + 1)) { 'x' } else { ' ' })).collect();
    rows.push(format!("{}[ ] Other: (type to answer)", if cursor == 4 { "  › " } else { "    " }));
    let refs: Vec<&str> = rows.iter().map(String::as_str).collect();
    cursor_form("Question 2 of 2", "2. Which features? (multi-select)", &refs)
}
fn ask_question_record(prompt: &str) -> String {
    format!("{}\n", json!({"role":"assistant","message":{"content":[{"type":"tool_use","name":"AskQuestion","input":{"title":"README clarifications","questions":[{"id":"q","prompt":prompt,"options":[{"id":"a","label":"Alpha"}]}]}}]}}))
}
fn cursor_question_fixture(screen: &str) -> (Service, PathBuf, SharedHerdr, PathBuf, String) {
    let (mut service, root, herdr, file) = cursor_fixture();
    let user = "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<user_query>\\nask me\\n</user_query>\"}]}}\n";
    fs::write(&file, user).unwrap();
    // Herdr reports a live question form as done, not blocked.
    set_screen(&herdr, "done", screen, screen);
    service.poll(&mut Vec::new()).unwrap();
    (service, root, herdr, file, user.into())
}
fn pending_question(service: &Service) -> &PendingQuestionEvent {
    match service.watch.as_ref().unwrap().pending.as_ref().expect("pending question") {
        PendingInteraction::Question(q) => q,
        _ => panic!("expected question"),
    }
}
fn queue(herdr: &SharedHerdr, screens: Vec<String>) {
    let mut state = herdr.lock().unwrap();
    for screen in screens {
        state.screens_after_input.push_back(std::collections::VecDeque::from([screen]));
    }
}
fn sent_keys(herdr: &SharedHerdr) -> Vec<String> {
    herdr.lock().unwrap().inputs.iter().map(|i| match i["method"].as_str().unwrap() {
        "pane.send_keys" => i["params"]["keys"][0].as_str().unwrap().to_owned(),
        "pane.send_text" => format!("text:{}", i["params"]["text"].as_str().unwrap()),
        other => other.to_owned(),
    }).collect()
}

#[test]
fn cursor_question_form_is_found_from_the_screen_while_herdr_says_done() {
    let (service, root, _herdr, _file, user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let event = pending_question(&service);
    assert!(event.fresh);
    assert_eq!(event.request.kind, QuestionKind::CursorAsk);
    assert!(event.request.request_id.starts_with(&format!("cursor-q:{}:1of2:", user.len())));
    let data = PendingInteraction::Question(PendingQuestionEvent {
        identity: event.identity.clone(), generation: event.generation, request: event.request.clone(),
        screen: event.screen.clone(), fresh: event.fresh,
    }).data();
    assert_eq!(data["question_kind"], "cursor");
    assert_eq!(data["agent"], "cursor");
    assert_eq!(data["step"], json!({"kind":"cursor_question","index":0,"total":2}));
    assert_eq!(data["questions"][0]["text"], "Which label?");
    assert_eq!(data["questions"][0]["header"], "README clarifications");
    assert_eq!(data["questions"][0]["allows_other"], true);
    assert_eq!(data["questions"][0]["options"], json!([
        {"number":1,"label":"Alpha","description":null},{"number":2,"label":"Beta","description":null}]));
    // The phone's composer closes while the form is up.
    assert_eq!(service.watch.as_ref().unwrap().status, "blocked");
    cleanup(&service, root);
}

#[test]
fn cursor_question_is_only_advertised_when_questions_are_opted_in() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    service.include_questions = false;
    set_screen(&herdr, "done", &q1(1, &[], "(type to answer)"), &q1(1, &[], "(type to answer)"));
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    assert_eq!(service.watch.as_ref().unwrap().status, "done");
    cleanup(&service, root);
}

#[test]
fn cursor_single_select_answer_walks_arrows_space_enter_and_confirms_the_next_question() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let id = pending_question(&service).request.request_id.clone();
    queue(&herdr, vec![q1(2, &[], "(type to answer)"), q1(2, &[2], "(type to answer)"), q2(1, &[])]);
    let reply = service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[2]}]})).unwrap();
    assert_eq!(reply["confirmed"], true, "the next question is showing");
    assert_eq!(sent_keys(&herdr), ["down", "space", "enter"]);
    cleanup(&service, root);
}

#[test]
fn cursor_write_in_types_on_the_other_row_and_multi_select_checks_in_order() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let id = pending_question(&service).request.request_id.clone();
    queue(&herdr, vec![q1(2, &[], "(type to answer)"), q1(3, &[], "(type to answer)"), q1(3, &[3], "Gamma"), q2(1, &[])]);
    let reply = service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[],"text":"Gamma"}]})).unwrap();
    assert_eq!(reply["confirmed"], true);
    assert_eq!(sent_keys(&herdr), ["down", "down", "text:Gamma", "enter"]);
    cleanup(&service, root);

    // Multi-select on the second (last) question: One and Three, then Enter submits.
    let (service, root, herdr, file, user) = cursor_question_fixture(&q2(1, &[]));
    let id = pending_question(&service).request.request_id.clone();
    assert!(id.contains(":2of2:"));
    {
        let mut state = herdr.lock().unwrap();
        for screen in [q2(1, &[1]), q2(2, &[1]), q2(3, &[1]), q2(3, &[1, 3]), "\n  Done.\n".to_owned()] {
            state.screens_after_input.push_back(std::collections::VecDeque::from([screen]));
        }
        // The submitted form is recorded once Cursor appends the call.
        state.transcript_after_inputs = Some((5, file.clone(), format!("{user}{}", ask_question_record("Which features?"))));
    }
    let reply = service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[1,3]}]})).unwrap();
    assert_eq!(reply["confirmed"], true, "form closed and the AskQuestion call was recorded");
    assert_eq!(sent_keys(&herdr), ["space", "down", "down", "space", "enter"]);
    cleanup(&service, root);
}

#[test]
fn cursor_last_question_without_a_recorded_call_is_unconfirmed() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q2(1, &[]));
    let id = pending_question(&service).request.request_id.clone();
    queue(&herdr, vec![q2(1, &[1]), "\n  Done.\n".to_owned()]);
    let started = Instant::now();
    let reply = service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[1]}]})).unwrap();
    assert_eq!(reply["confirmed"], false);
    assert!(started.elapsed() >= Duration::from_secs(4));
    assert_eq!(sent_keys(&herdr), ["space", "enter"]);
    cleanup(&service, root);
}

#[test]
fn cursor_question_that_the_desk_already_touched_is_not_answerable() {
    for touched in [q1(2, &[], "(type to answer)"), q1(1, &[1], "(type to answer)"), q1(1, &[], "typing")] {
        let (service, root, herdr, _file, _user) = cursor_question_fixture(&touched);
        let event = pending_question(&service);
        assert!(!event.fresh);
        let id = event.request.request_id.clone();
        let error = service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[1]}]})).unwrap_err();
        assert_eq!(error.data()["code"], "in_progress");
        assert!(sent_keys(&herdr).is_empty());
        cleanup(&service, root);
    }
}

#[test]
fn cursor_question_responses_validate_before_any_key_and_skip_stays_in_terminal() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let id = pending_question(&service).request.request_id.clone();
    for params in [
        json!({"request_id":id,"skip":true}),                                          // Esc would discard the whole form
        json!({"request_id":id,"answers":[]}),
        json!({"request_id":id,"answers":[{"index":1,"options":[1]}]}),                // only one question per request
        json!({"request_id":id,"answers":[{"index":0,"options":[3]}]}),                // beyond the options
        json!({"request_id":id,"answers":[{"index":0,"options":[1,2]}]}),              // radio
        json!({"request_id":id,"answers":[{"index":0,"options":[1],"text":"x"}]}),     // radio plus write-in
        json!({"request_id":id,"answers":[{"index":0,"options":[]}]}),
        json!({"request_id":id,"answers":[{"index":0,"options":[],"text":"a\nb"}]}),
        json!({"request_id":id,"answers":[{"index":0,"options":[],"text":"x".repeat(501)}]}),
        json!({"request_id":"cursor-q:0:1of2:00","answers":[{"index":0,"options":[1]}]}),
    ] {
        assert!(service.respond_interaction(&params).is_err(), "{params}");
    }
    assert!(sent_keys(&herdr).is_empty());
    cleanup(&service, root);
}

#[test]
fn cursor_question_response_is_stale_when_the_form_changed_or_left() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let id = pending_question(&service).request.request_id.clone();
    let params = json!({"request_id":id,"answers":[{"index":0,"options":[1]}]});
    // Answered at the desk: the form moved to question 2.
    let next = q2(1, &[]);
    set_screen(&herdr, "done", &next, &next);
    assert!(service.respond_interaction(&params).is_err());
    // The form is gone.
    let (idle, _) = cursor_idle();
    set_screen(&herdr, "done", &idle, &idle);
    assert!(service.respond_interaction(&params).is_err());
    // The pane is working again.
    let form = q1(1, &[], "(type to answer)");
    set_screen(&herdr, "working", &form, &form);
    assert!(service.respond_interaction(&params).is_err());
    assert!(sent_keys(&herdr).is_empty());
    cleanup(&service, root);
}

#[test]
fn cursor_question_stops_when_a_step_leaves_the_expected_screen() {
    let (service, root, herdr, _file, _user) = cursor_question_fixture(&q1(1, &[], "(type to answer)"));
    let id = pending_question(&service).request.request_id.clone();
    // The first key lands on the wrong row; nothing further may be sent.
    queue(&herdr, vec![q1(3, &[], "(type to answer)")]);
    assert!(service.respond_interaction(&json!({"request_id":id,"answers":[{"index":0,"options":[2]}]})).is_err());
    assert_eq!(sent_keys(&herdr), ["down"]);
    cleanup(&service, root);
}

#[test]
fn cursor_question_card_does_not_collide_with_an_approval_card() {
    let (mut service, root, herdr, _file) = cursor_fixture();
    let card = cursor_card("printf X", 0);
    set_screen(&herdr, "blocked", &card, &card);
    service.poll(&mut Vec::new()).unwrap();
    assert!(matches!(service.watch.as_ref().unwrap().pending, Some(PendingInteraction::Approval(_))));
    cleanup(&service, root);
}

/// Cursor's composer in a brand-new chat: a faint "Plan, search, build anything".
fn cursor_new_chat() -> (String, String) {
    let plain = format!("\n  Cursor Agent\n  v2026.10.22-27dcf5f\n\n{CURSOR_TOP}\n  → Plan, search, build anything\n{CURSOR_BOTTOM}\n{CURSOR_FOOTER}");
    let bg = "\u{1b}[48;2;47;50;57m";
    let row = format!(" \u{1b}[0m{bg} \u{1b}[0m\u{1b}[2m{bg}→ \u{1b}[0m\u{1b}[7m{bg}P\u{1b}[0m\u{1b}[2m{bg}lan, search, build anything\u{1b}[0m{bg}   \u{1b}[0m");
    let styled = plain.replace("  → Plan, search, build anything", &row);
    (plain, styled)
}
/// A pane whose chat Herdr reports but whose transcript Cursor has not created yet.
fn cursor_fresh_fixture() -> (Service, PathBuf, SharedHerdr, PathBuf) {
    let (mut service, root, herdr, file) = cursor_fixture();
    fs::remove_file(&file).unwrap();
    let (plain, styled) = cursor_new_chat();
    set_screen(&herdr, "idle", &plain, &styled);
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(service.watch.as_ref().unwrap().unavailable, Some("transcript_unavailable"));
    (service, root, herdr, file)
}
fn fresh_params(service: &Service, text: &str) -> Value {
    json!({"text":text,"pane_id":"w1:p1","generation":service.generation})
}

#[test]
fn cursor_first_message_of_a_new_chat_is_sent_by_pane_before_any_transcript_exists() {
    let (mut service, root, herdr, _file) = cursor_fresh_fixture();
    let params = fresh_params(&service, "hello from the phone");
    assert_eq!(service.prompt_submit(&params).unwrap()["submitted"], true);
    assert_eq!(prompts(&herdr), 1);
    let sent = herdr.lock().unwrap().inputs.iter().find(|i| i["method"] == "agent.prompt").cloned().unwrap();
    assert_eq!(sent["params"]["text"], "hello from the phone");
    assert_eq!(sent["params"]["target"], "w1:p1");
    cleanup(&service, root);
}

#[test]
fn cursor_first_message_keeps_every_screen_guard() {
    let (mut service, root, herdr, _file) = cursor_fresh_fixture();
    let params = fresh_params(&service, "hi");
    let card = cursor_card("printf X", 0);
    let (new_plain, new_styled) = cursor_new_chat();
    let draft = new_plain.replace("→ Plan, search, build anything", "→ half typed");
    for (status, plain, styled, code) in [
        ("done", card.as_str(), card.as_str(), "approval_pending"),
        ("done", CURSOR_QUESTION, CURSOR_QUESTION, "question_pending"),
        ("idle", draft.as_str(), draft.as_str(), "composer_not_empty"),
        // Typed text that spells the placeholder is still a draft: no faint styling.
        ("idle", new_plain.as_str(), new_plain.as_str(), "composer_not_empty"),
        ("working", new_plain.as_str(), new_styled.as_str(), "agent_busy"),
        ("idle", "$ ls", "$ ls", "screen_unrecognized"),
    ] {
        set_screen(&herdr, status, plain, styled);
        assert_eq!(service.prompt_submit(&params).unwrap_err(), code);
    }
    assert_eq!(prompts(&herdr), 0, "nothing is typed into a pane that is not ready");
    cleanup(&service, root);
}

#[test]
fn cursor_first_message_refuses_slash_commands_and_stale_requests_without_touching_the_pane() {
    let (mut service, root, herdr, _file) = cursor_fresh_fixture();
    for text in ["/model x", "  /quit"] {
        assert_eq!(service.prompt_submit(&fresh_params(&service, text)).unwrap_err(), "slash_command_refused");
    }
    for text in ["", "   ", "a\0b"] {
        assert_eq!(service.prompt_submit(&fresh_params(&service, text)).unwrap_err(), "invalid_request");
    }
    let mut wrong_pane = fresh_params(&service, "hi");
    wrong_pane["pane_id"] = json!("w9:p9");
    assert_eq!(service.prompt_submit(&wrong_pane).unwrap_err(), "stale");
    let mut wrong_generation = fresh_params(&service, "hi");
    wrong_generation["generation"] = json!(service.generation + 1);
    assert_eq!(service.prompt_submit(&wrong_generation).unwrap_err(), "stale");
    let mut no_pane = fresh_params(&service, "hi");
    no_pane.as_object_mut().unwrap().remove("pane_id");
    assert_eq!(service.prompt_submit(&no_pane).unwrap_err(), "stale");
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);
}

#[test]
fn cursor_pane_scoped_prompt_is_only_for_the_exact_missing_transcript_state() {
    // Once the transcript exists the chat has an identity: a pane-scoped request is stale.
    let (mut service, root, herdr, file) = cursor_fresh_fixture();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n").unwrap();
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().identity.is_some());
    assert_eq!(service.prompt_submit(&fresh_params(&service, "hi")).unwrap_err(), "stale");
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);

    // Other unavailable states (two chats with this ID, a root problem) never take this path.
    let (mut service, root, herdr, file) = cursor_fresh_fixture();
    let projects = file.ancestors().nth(4).unwrap().to_path_buf();
    let id = file.file_stem().unwrap().to_str().unwrap().to_owned();
    for project in ["one", "two"] {
        let dir = projects.join(project).join("agent-transcripts").join(&id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(format!("{id}.jsonl")), "{}\n").unwrap();
    }
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(service.watch.as_ref().unwrap().unavailable, Some("ambiguous_session"));
    assert_eq!(service.prompt_submit(&fresh_params(&service, "hi")).unwrap_err(), "timeline_unavailable");
    assert_eq!(prompts(&herdr), 0);
    cleanup(&service, root);
}
