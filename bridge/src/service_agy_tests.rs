fn agy_fixture() -> (Service, PathBuf, SharedHerdr) {
    let (service, root, session, herdr) = fixture_with_herdr();
    let brain = root.join("brain");
    let logs = brain
        .join(session.lock().unwrap().as_str())
        .join(".system_generated/logs");
    fs::create_dir_all(&logs).unwrap();
    fs::write(
        logs.join("transcript.jsonl"),
        include_bytes!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl"),
    )
    .unwrap();
    herdr.lock().unwrap().agent = Some("agy".into());
    let mut service = service.with_agy_root(brain.canonicalize().unwrap());
    service.include_content = true;
    service.include_approvals = true;
    service.include_questions = true;
    (service, root, herdr)
}
#[test]
fn agy_alias_history_and_session_replacement_invalidate_actions() {
    let (mut service, root, herdr) = agy_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let watch = service.watch.as_ref().unwrap();
    assert_eq!(watch.identity.as_ref().unwrap().agent, "antigravity_cli");
    assert!(watch.previous.iter().any(|e| e.id == "agy:13:tool:0"));
    let generation = service.generation;
    herdr.lock().unwrap().session_override = Some("11111111-1111-1111-1111-111111111111".into());
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().identity.is_none());
    assert!(
        service
            .respond_interaction(&json!({"request_id":"agy:13:tool:0","option":1}))
            .is_err()
    );
    assert!(herdr.lock().unwrap().keys.is_empty());
    assert!(service.generation > generation);
    cleanup(&service, root);
}
#[test]
fn agy_command_denial_walks_guarded_arrows_and_confirms_once() {
    let (mut service, root, herdr) = agy_fixture();
    let session = service.client.snapshot().unwrap().panes[0]
        .agent_session
        .as_ref()
        .unwrap()
        .value
        .clone();
    let path = root
        .join("brain")
        .join(session)
        .join(".system_generated/logs/transcript.jsonl");
    let fixture =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl");
    fs::write(
        path,
        format!(
            "{}\n",
            fixture.lines().take(14).collect::<Vec<_>>().join("\n")
        ),
    )
    .unwrap();
    let screen = "Command\nRequesting permission for:\n   printf HERDCATS_DENIAL_PROBE\n\nRun this command?\n> 1. Yes, run command\n  2. Yes, and always allow in this conversation for commands that start with 'printf'\n  3. Yes, and always allow for commands that start with 'printf' (Persist to settings.json)\n  4. No, cancel\n\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command";
    {
        let mut state = herdr.lock().unwrap();
        state.status = Some("blocked".into());
        state.screen = screen.into();
        state.allow_question_input = true;
        let mut previous = screen.to_owned();
        for n in 1..4 {
            let next = previous
                .replace(&format!("> {n}."), &format!("  {n}."))
                .replace(&format!("  {}.", n + 1), &format!("> {}.", n + 1));
            state
                .screens_after_input
                .push_back(std::collections::VecDeque::from([next.clone()]));
            previous = next;
        }
        state
            .screens_after_input
            .push_back(std::collections::VecDeque::from(["Denied".into()]));
    }
    service.poll(&mut Vec::new()).unwrap();
    let PendingInteraction::Approval(pending) =
        service.watch.as_ref().unwrap().pending.as_ref().unwrap()
    else {
        panic!("expected approval")
    };
    let params =
        json!({"request_id":pending.request.request_id,"option":4,"label_lines":["No, cancel"]});
    let reply = service.respond_interaction(&params).unwrap();
    assert_eq!(reply["confirmed"], false);
    assert_eq!(herdr.lock().unwrap().keys.len(), 4);
    assert!(service.respond_interaction(&params).is_err());
    assert_eq!(herdr.lock().unwrap().keys.len(), 4);
    cleanup(&service, root);
}
#[test]
fn agy_delayed_source_is_retried_and_model_catalog_is_capability_gated() {
    let (mut service, root, herdr) = agy_fixture();
    service.poll(&mut Vec::new()).unwrap();
    let original = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let logs = root
        .join("brain")
        .join("22222222-2222-2222-2222-222222222222/.system_generated/logs");
    herdr.lock().unwrap().session_override = Some("22222222-2222-2222-2222-222222222222".into());
    service.poll(&mut Vec::new()).unwrap();
    assert!(service.watch.as_ref().unwrap().identity.is_none());
    fs::create_dir_all(&logs).unwrap();
    fs::write(
        logs.join("transcript.jsonl"),
        "{\"step_index\":0,\"type\":\"USER_INPUT\",\"content\":\"independent\"}\n",
    )
    .unwrap();
    service.poll(&mut Vec::new()).unwrap();
    let watch = service.watch.as_ref().unwrap();
    assert!(watch.identity.as_ref() != Some(&original));
    assert_eq!(watch.previous.len(), 1);
    assert_eq!(watch.previous[0].text, "independent");
    assert_eq!(
        service.model_status().unwrap_err(),
        "unsupported_capability"
    );
    cleanup(&service, root);
}
#[test]
fn agy_model_catalog_and_setter_require_captured_scope_and_idle_pair() {
    let (mut service, root, herdr) = agy_fixture();
    service.poll(&mut Vec::new()).unwrap();
    service.include_model_control = true;
    *service.agy_catalog_cache.borrow_mut() = Some((
        Instant::now(),
        model_control::parse_agy_models(
            "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\ngemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)",
        ),
    ));
    herdr.lock().unwrap().screen="────────────────────\n\n────────────────────\n? for shortcuts       Gemini 3.8 Flash · low".into();
    let status = service.model_status().unwrap();
    assert_eq!(status["model"]["id"], "gemini-3.8-flash");
    assert_eq!(status["model"]["label"], "Gemini 3.8 Flash");
    assert_eq!(status["models"].as_array().unwrap().len(), 1);
    assert_eq!(status["efforts"].as_array().unwrap().len(), 2);
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let mut params = json!({"model":"gemini-3.8-flash-low","expect":{"model":"gemini-3.8-flash-low","effort":"low","identity":identity,"generation":service.generation}});
    assert_eq!(service.model_set(&params).unwrap()["confirmed"], true);
    params["expect"]["generation"] = json!(service.generation + 1);
    assert_eq!(service.model_set(&params).unwrap_err(), "stale");
    params["expect"]["generation"] = json!(service.generation);
    herdr.lock().unwrap().status = Some("working".into());
    assert_eq!(service.model_set(&params).unwrap_err(), "agent_busy");
    assert!(herdr.lock().unwrap().inputs.is_empty());
    cleanup(&service, root);
}

fn agy_idle_question_fixture(status: &str) -> (Service, PathBuf, SharedHerdr, PathBuf) {
    let (service, root, herdr) = agy_fixture();
    let native = service.client.snapshot().unwrap().panes[0]
        .agent_session
        .as_ref()
        .unwrap()
        .value
        .clone();
    let path = root
        .join("brain")
        .join(native)
        .join(".system_generated/logs/transcript.jsonl");
    let fixture =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl");
    fs::write(
        &path,
        format!(
            "{}\n",
            fixture.lines().take(2).collect::<Vec<_>>().join("\n")
        ),
    )
    .unwrap();
    let mut state = herdr.lock().unwrap();
    state.status = Some(status.into());
    state.screen="Question 1/1: Which probe color?\n> 1. (Recommended) Red\n  2. Blue\n  3. Write-in...\n  ↑/↓ Navigate · enter Select · esc Skip\nesc to cancel             Gemini 3.8 Flash · high".into();
    drop(state);
    (service, root, herdr, path)
}
#[test]
fn agy_misclassified_question_emits_pending_and_blocks_timeline_and_models() {
    for status in ["idle", "done", "working"] {
        let (mut service, root, herdr, _) = agy_idle_question_fixture(status);
        let mut out = Vec::new();
        service.poll(&mut out).unwrap();
        let emitted = frames(out);
        assert_eq!(
            emitted
                .iter()
                .find(|f| f["event"] == "timeline.snapshot")
                .unwrap()["data"]["agent_status"],
            "blocked"
        );
        assert!(matches!(
            service.watch.as_ref().unwrap().pending,
            Some(PendingInteraction::Question(_))
        ));
        let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
        assert_eq!(
            service.composer_clear(&identity, "agy").unwrap_err(),
            "agent_busy"
        );
        service.include_model_control = true;
        assert_eq!(service.model_set(&json!({"effort":"low","expect":{"identity":identity,"generation":service.generation}})).unwrap_err(),"agent_busy");
        assert!(herdr.lock().unwrap().inputs.is_empty());
        cleanup(&service, root);
    }
}
#[test]
fn agy_interaction_opt_out_still_blocks_composition_and_dismissal_restores_status() {
    let (mut service, root, herdr, _) = agy_idle_question_fixture("idle");
    service.include_questions = false;
    service.include_approvals = false;
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(service.watch.as_ref().unwrap().status, "blocked");
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    herdr.lock().unwrap().screen = "Not a question".into();
    service.poll(&mut Vec::new()).unwrap();
    assert_ne!(service.watch.as_ref().unwrap().status, "idle"); // unresolved source + uncertain screen fail closed
    cleanup(&service, root);
}
#[test]
fn agy_idle_question_response_delivers_once_and_confirms_result() {
    let (mut service, root, herdr, path) = agy_idle_question_fixture("idle");
    service.poll(&mut Vec::new()).unwrap();
    let selected = herdr
        .lock()
        .unwrap()
        .screen
        .replace("> 1.", "  1.")
        .replace("  2.", "> 2.");
    script_question(&herdr, vec![selected, "Finished".into()]);
    let fixture =
        include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl");
    herdr.lock().unwrap().transcript_after_inputs = Some((
        2,
        path,
        format!(
            "{}\n",
            fixture.lines().take(3).collect::<Vec<_>>().join("\n")
        ),
    ));
    let result = service
        .respond_interaction(
            &json!({"request_id":"agy:1:tool:0","answers":[{"index":0,"options":[2]}]}),
        )
        .unwrap();
    assert_eq!(result["confirmed"], true);
    assert_eq!(herdr.lock().unwrap().inputs.len(), 2);
    assert!(
        service
            .respond_interaction(
                &json!({"request_id":"agy:1:tool:0","answers":[{"index":0,"options":[2]}]})
            )
            .is_err()
    );
    assert_eq!(herdr.lock().unwrap().inputs.len(), 2);
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(service.watch.as_ref().unwrap().status, "idle");
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    cleanup(&service, root);
}
#[test]
fn agy_idle_question_stale_dismissal_or_replacement_never_sends_next_key() {
    for replace in [false, true] {
        let (mut service, root, herdr, _) = agy_idle_question_fixture("idle");
        service.poll(&mut Vec::new()).unwrap();
        let selected = herdr
            .lock()
            .unwrap()
            .screen
            .replace("> 1.", "  1.")
            .replace("  2.", "> 2.");
        script_question(
            &herdr,
            vec![if replace {
                selected
            } else {
                "Dismissed".into()
            }],
        );
        if replace {
            herdr.lock().unwrap().terminal_after_input = Some("replacement".into());
        }
        assert!(
            service
                .respond_interaction(
                    &json!({"request_id":"agy:1:tool:0","answers":[{"index":0,"options":[2]}]})
                )
                .is_err()
        );
        assert_eq!(herdr.lock().unwrap().inputs.len(), 1);
        cleanup(&service, root);
    }
}
#[test]
fn agy_idle_approval_uses_same_verified_gate_and_rechecks_each_step() {
    for replacement in [false, true] {
        let (mut service, root, herdr) = agy_fixture();
        let native = service.client.snapshot().unwrap().panes[0]
            .agent_session
            .as_ref()
            .unwrap()
            .value
            .clone();
        let path = root
            .join("brain")
            .join(native)
            .join(".system_generated/logs/transcript.jsonl");
        let fixture =
            include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl");
        fs::write(
            &path,
            format!(
                "{}\n",
                fixture.lines().take(14).collect::<Vec<_>>().join("\n")
            ),
        )
        .unwrap();
        let screen = "Command\nRequesting permission for:\n   printf HERDCATS_DENIAL_PROBE\n\nRun this command?\n> 1. Yes, run command\n  2. Yes, and always allow in this conversation for commands that start with 'printf'\n  3. Yes, and always allow for commands that start with 'printf' (Persist to settings.json)\n  4. No, cancel\n\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command";
        {
            let mut h = herdr.lock().unwrap();
            h.status = Some("idle".into());
            h.screen = screen.into();
        }
        service.poll(&mut Vec::new()).unwrap();
        assert_eq!(service.watch.as_ref().unwrap().status, "blocked");
        let selected = screen.replace("> 1.", "  1.").replace("  2.", "> 2.");
        script_question(&herdr, vec![selected, "Finished".into()]);
        if replacement {
            herdr.lock().unwrap().terminal_after_input = Some("replacement".into());
        } else {
            herdr.lock().unwrap().transcript_after_inputs = Some((2, path, fixture.into()));
        }
        let result=service.respond_interaction(&json!({"request_id":"agy:13:tool:0","option":2,"label_lines":["Yes, and always allow in this conversation for commands that start with 'printf'"]}));
        if replacement {
            assert!(result.is_err());
            assert_eq!(herdr.lock().unwrap().inputs.len(), 1);
        } else {
            assert_eq!(result.unwrap()["confirmed"], true);
            assert_eq!(herdr.lock().unwrap().inputs.len(), 2);
        }
        cleanup(&service, root);
    }
}
#[test]
fn agy_idle_ambiguous_or_unmatched_source_cannot_authorize_cards_or_models() {
    let (mut service, root, herdr, path) = agy_idle_question_fixture("idle");
    let mut rows: Vec<Value> = fs::read_to_string(&path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let call = rows[1]["tool_calls"][0].clone();
    rows[1]["tool_calls"].as_array_mut().unwrap().push(call);
    fs::write(
        &path,
        rows.iter().map(|r| format!("{r}\n")).collect::<String>(),
    )
    .unwrap();
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(service.watch.as_ref().unwrap().status, "unknown");
    assert!(service.watch.as_ref().unwrap().pending.is_none());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    assert_eq!(
        service.composer_clear(&identity, "agy").unwrap_err(),
        "agent_busy"
    );
    assert!(herdr.lock().unwrap().inputs.is_empty());
    cleanup(&service, root);
}
#[test]
fn claude_and_codex_idle_questions_remain_status_gated() {
    for kind in ["claude", "codex_plan"] {
        let (mut service, root, herdr, _) = question_fixture(kind);
        herdr.lock().unwrap().status = Some("idle".into());
        service.poll(&mut Vec::new()).unwrap();
        assert!(service.watch.as_ref().unwrap().pending.is_none());
        assert_eq!(service.watch.as_ref().unwrap().status, "idle");
        cleanup(&service, root);
    }
}
#[test]
fn agy_idle_question_dismissed_or_rewritten_before_tap_sends_nothing() {
    for rewrite in [false, true] {
        let (mut service, root, herdr, path) = agy_idle_question_fixture("idle");
        service.poll(&mut Vec::new()).unwrap();
        if rewrite {
            let text = fs::read_to_string(&path)
                .unwrap()
                .replace("synthetic interface test", "rewritten interface test");
            fs::write(&path, text).unwrap();
        } else {
            herdr.lock().unwrap().screen = "Dismissed".into();
        }
        assert!(
            service
                .respond_interaction(
                    &json!({"request_id":"agy:1:tool:0","answers":[{"index":0,"options":[2]}]})
                )
                .is_err()
        );
        assert!(herdr.lock().unwrap().inputs.is_empty());
        cleanup(&service, root);
    }
}

#[test]
fn agy_review_footer_emits_current_command_with_all_four_exact_scope_labels() {
    let (mut service, root, herdr) = agy_fixture();
    let native = service.client.snapshot().unwrap().panes[0]
        .agent_session
        .as_ref()
        .unwrap()
        .value
        .clone();
    let path = root
        .join("brain")
        .join(native)
        .join(".system_generated/logs/transcript.jsonl");
    fs::write(path, format!("{}\n", json!({"step_index":46,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-25T08:41:54Z","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"printf SAFE\""}}]}))).unwrap();
    let labels = [
        "Yes, run command",
        "Yes, and always allow in this conversation for commands that start with 'printf'",
        "Yes, and always allow for commands that start with 'printf' (Persist to settings.json)",
        "No, cancel",
    ];
    let options = labels
        .iter()
        .enumerate()
        .map(|(i, label)| format!("{}{}. {label}", if i == 0 { "> " } else { "  " }, i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    let historical = format!(
        "```text\nCommand\nRequesting permission for:\n   printf SAFE\n\nRun this command?\n{options}\n\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command\n```\n"
    );
    herdr.lock().unwrap().screen = format!(
        "{historical}\nCommand\n────────────────────────\n\nRequesting permission for:\n   printf SAFE\n\nRun this command?\n{options}\n\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command · ctrl+r Review"
    );
    let mut out = Vec::new();
    service.poll(&mut out).unwrap();
    let events = frames(out);
    let pending = &events
        .iter()
        .find(|event| event["event"] == "interaction.pending")
        .expect("current approval event")["data"];
    assert_eq!(pending["kind"], "approval");
    assert_eq!(pending["request_id"], "agy:46:tool:0");
    assert_eq!(pending["title"], "Command");
    assert_eq!(pending["command"], "printf SAFE");
    assert_eq!(pending["options"].as_array().unwrap().len(), 4);
    for (option, label) in pending["options"].as_array().unwrap().iter().zip(labels) {
        assert_eq!(option["label_lines"], json!([label]));
    }
    assert!(herdr.lock().unwrap().inputs.is_empty());
    cleanup(&service, root);
}

fn agy_catalog_test_cli(service: &Service, root: &std::path::Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    let executable = root.join("fake-agy");
    fs::write(&executable, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
    *service.agy_executable.borrow_mut() = Some(executable);
}

#[test]
fn agy_model_status_reports_catalog_failures_instead_of_empty_success() {
    for (body, error) in [
        ("printf '1.4.8\\n'", "agy_unsupported_version"),
        (
            "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; fi",
            "agy_catalog_empty",
        ),
        (
            "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'malformed\\n'; fi",
            "agy_catalog_invalid",
        ),
    ] {
        let (mut service, root, herdr) = agy_fixture();
        service.poll(&mut Vec::new()).unwrap();
        service.include_model_control = true;
        herdr.lock().unwrap().screen = "────────────────────\n\n────────────────────\n? for shortcuts       Gemini 3.8 Flash · low".into();
        agy_catalog_test_cli(&service, &root, body);
        assert_eq!(service.model_status().unwrap_err(), error);
        assert!(service.agy_catalog_cache.borrow().is_none());
        agy_catalog_test_cli(
            &service,
            &root,
            "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\n'; fi",
        );
        assert_eq!(service.agy_catalog().unwrap_err(), error);
        *service.agy_catalog_error.borrow_mut() =
            Some((Instant::now() - Duration::from_secs(2), error));
        assert_eq!(service.agy_catalog().unwrap_err(), error);
        *service.agy_catalog_error.borrow_mut() =
            Some((Instant::now() - Duration::from_secs(61), error));
        assert_eq!(service.agy_catalog().unwrap().len(), 1);
        assert!(herdr.lock().unwrap().inputs.is_empty());
        cleanup(&service, root);
    }
}

#[test]
fn agy_model_status_retry_discovers_once_and_failure_cache_only_throttles_polling() {
    let (mut service, root, herdr) = agy_fixture();
    service.poll(&mut Vec::new()).unwrap();
    service.include_model_control = true;
    service.initialized = true;
    herdr.lock().unwrap().screen = "────────────────────\n\n────────────────────\n? for shortcuts       Gemini 3.8 Flash · low".into();
    let counter = root.join("catalog-attempts");
    agy_catalog_test_cli(
        &service,
        &root,
        &format!("printf x >> '{}'\nprintf '1.4.8\\n'", counter.display()),
    );
    for attempt in 1..=2 {
        let mut out = Vec::new();
        service
            .request(
                &serde_json::to_vec(&json!({"id":"status","method":"model.status","params":{}}))
                    .unwrap(),
                &mut out,
            )
            .unwrap();
        let responses = frames(out);
        assert_eq!(
            responses.iter().find(|f| f["id"] == "status").unwrap()["error"]["code"],
            "agy_unsupported_version"
        );
        assert_eq!(fs::read(&counter).unwrap().len(), attempt);
        assert_eq!(
            service.agy_catalog().unwrap_err(),
            "agy_unsupported_version"
        );
        assert_eq!(fs::read(&counter).unwrap().len(), attempt);
    }
    agy_catalog_test_cli(
        &service,
        &root,
        "if [ \"$1\" = --version ]; then printf '1.4.7\\n'; else printf 'gemini-3.8-flash-low\\tGemini 3.8 Flash (Low)\\n'; fi",
    );
    let mut out = Vec::new();
    service
        .request(
            &serde_json::to_vec(&json!({"id":"retry","method":"model.status","params":{}}))
                .unwrap(),
            &mut out,
        )
        .unwrap();
    let responses = frames(out);
    let reply = responses.iter().find(|f| f["id"] == "retry").unwrap();
    assert_eq!(reply["result"]["models"].as_array().unwrap().len(), 1);
    assert!(herdr.lock().unwrap().inputs.is_empty());
    cleanup(&service, root);
}

#[test]
fn agy_normalized_wire_roundtrip_keeps_native_override_and_stale_guards() {
    let (mut service, root, herdr) = agy_fixture();
    service.include_model_control = true;
    *service.agy_catalog_cache.borrow_mut() = Some((Instant::now(), model_control::parse_agy_models(
        "flash-low\tFlash (Low)\nflash-medium\tFlash (Medium)\nflash-high\tFlash (High)")));
    herdr.lock().unwrap().screen = "────────────────────\n\n────────────────────\n? for shortcuts       Flash · high".into();
    let mut out = Vec::new();
    service.poll(&mut out).unwrap();
    let events = frames(out);
    let updated = events.iter().find(|f| f["event"] == "model.updated").unwrap();
    assert_eq!(updated["data"]["model"]["id"], "flash");
    assert_eq!(updated["data"]["model"]["label"], "Flash");
    let snapshot = events.iter().find(|f| f["event"] == "timeline.snapshot").unwrap();
    assert_eq!(snapshot["data"]["model"]["id"], "flash");
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    for target in [Some("flash"), Some("flash-high"), None] {
        let params = json!({"model":target,"effort":"high","expect":{"model":"flash","effort":"high","identity":identity,"generation":service.generation}});
        let result = service.model_set(&params).unwrap();
        assert_eq!(result["applied"]["model"]["id"], "flash");
        assert_eq!(result["applied"]["model"]["label"], "Flash");
        let watch = service.watch.as_ref().unwrap();
        assert_eq!(watch.model_override.as_ref().unwrap().applied.as_ref().unwrap().0, "flash-high");
        assert_eq!(watch.model_override.as_ref().unwrap().scanned_at_set.as_ref().unwrap().0, "flash-high");
        assert_eq!(service.model_status().unwrap()["model"]["id"], "flash");
    }
    for (model, effort, generation) in [("flash-low", "high", service.generation), ("flash", "low", service.generation), ("flash", "high", service.generation + 1)] {
        let params = json!({"model":"flash","expect":{"model":model,"effort":effort,"identity":identity,"generation":generation}});
        assert_eq!(service.model_set(&params).unwrap_err(), "stale");
    }
    assert!(herdr.lock().unwrap().inputs.is_empty());
    cleanup(&service, root);
}

#[test]
fn agy_family_switch_and_effort_only_send_exact_discovered_commands() {
    let (mut service, root, herdr) = agy_fixture();
    service.include_model_control = true;
    *service.agy_catalog_cache.borrow_mut() = Some((Instant::now(), model_control::parse_agy_models(
        "flash-low\tFlash (Low)\nflash-high\tFlash (High)\nargon-medium\tArgon (Medium)\nargon-high\tArgon (High)\nsolo-medium\tSolo (Medium)")));
    agy_catalog_test_cli(&service, &root, "printf '1.4.7\\n'");
    let screen = |label: &str, effort: &str, ack: &str| format!("{ack}\n────────────────────\n>\n────────────────────\n? for shortcuts       {label} · {effort}");
    herdr.lock().unwrap().screen = screen("Flash", "high", "");
    service.poll(&mut Vec::new()).unwrap();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let mut expected_model = "flash";
    let mut expected_effort = "high";
    for (model, effort, native, family, label, level, command) in [
        (Some("argon"), None, "argon-high", "argon", "Argon", "high", "/model argon-high"),
        (Some("solo"), None, "solo-medium", "solo", "Solo", "medium", "/model solo-medium"),
        (Some("flash-high"), None, "flash-high", "flash", "Flash", "high", "/model flash-high"),
        (None, Some("low"), "flash-low", "flash", "Flash", "low", "/effort low"),
    ] {
        let ack = if model.is_some() { format!("Model set to {label} ({})", model_control::effort_label(level)) } else { format!("Effort set to {level}") };
        {
            let mut state = herdr.lock().unwrap();
            state.allow_question_input = true;
            state.screens_after_input.push_back([screen(label, level, &ack)].into());
        }
        let result = service.model_set(&json!({"model":model,"effort":effort,"expect":{"model":expected_model,"effort":expected_effort,"identity":identity,"generation":service.generation}})).unwrap();
        assert_eq!(result["confirmed"], true);
        assert_eq!(result["applied"]["model"]["id"], family);
        assert_eq!(result["applied"]["model"]["label"], label);
        assert_eq!(result["applied"]["effort"], level);
        assert_eq!(herdr.lock().unwrap().inputs.last().unwrap()["params"]["text"], command);
        assert_eq!(service.watch.as_ref().unwrap().model_override.as_ref().unwrap().applied.as_ref().unwrap().0, native);
        let mut out = Vec::new();
        service.poll(&mut out).unwrap();
        let events = frames(out);
        let updated = events.iter().find(|f| f["event"] == "model.updated").unwrap();
        assert_eq!(updated["data"]["model"]["id"], family);
        assert_eq!(updated["data"]["effort"], level);
        let status = service.model_status().unwrap();
        assert_eq!(status["model"]["id"], family);
        expected_model = family;
        expected_effort = level;
    }
    let count = herdr.lock().unwrap().inputs.len();
    herdr.lock().unwrap().terminal_id = Some("replacement".into());
    assert_eq!(service.model_set(&json!({"model":"argon","expect":{"model":"flash","effort":"low","identity":identity,"generation":service.generation}})).unwrap_err(), "stale");
    assert_eq!(herdr.lock().unwrap().inputs.len(), count);
    cleanup(&service, root);
}

#[test]
fn agy_gpt_oss_full_label_footer_switches_away_and_back_with_native_guards() {
    let (mut service, root, herdr) = agy_fixture();
    service.include_model_control = true;
    *service.agy_catalog_cache.borrow_mut() = Some((Instant::now(), model_control::parse_agy_models(
        "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\ngemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\ngemini-3.8-flash-high\tGemini 3.8 Flash (High)\ngpt-oss-120b-medium\tGPT-OSS 120B (Medium)")));
    agy_catalog_test_cli(&service, &root, "printf '1.4.7\\n'");
    let screen = |label: &str, full: bool, ack: &str| format!("{ack}\n────────────────────\n>\n────────────────────\n? for shortcuts       {}", if full {format!("{label} (Medium)")} else {format!("{label} · medium")});
    let gpt_screen = screen("GPT-OSS 120B", true, "Model set to GPT-OSS 120B (Medium)");
    herdr.lock().unwrap().screen = gpt_screen.clone();
    let mut out = Vec::new();
    service.poll(&mut out).unwrap();
    let events = frames(out);
    for kind in ["timeline.snapshot", "model.updated"] {
        let event = events.iter().find(|f| f["event"] == kind).unwrap();
        assert_eq!(event["data"]["model"]["id"], "gpt-oss-120b");
        assert_eq!(event["data"]["model"]["label"], "GPT-OSS 120B");
        assert_eq!(event["data"]["effort"], "medium");
    }
    let status = service.model_status().unwrap();
    assert_eq!(status["efforts"], json!([{"id":"medium","label":"Medium"}]));
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let params = json!({"model":"gemini-3.8-flash","expect":{"model":"gpt-oss-120b","effort":"medium","identity":identity,"generation":service.generation}});
    herdr.lock().unwrap().screen = gpt_screen.replace("\n>\n", "\n> draft\n");
    assert_eq!(service.model_set(&params).unwrap_err(), "composer_not_empty");
    herdr.lock().unwrap().screen = gpt_screen;
    let mut stale = params.clone();
    stale["expect"]["model"] = json!("gemini-3.8-flash-medium");
    assert_eq!(service.model_set(&stale).unwrap_err(), "stale");
    assert!(herdr.lock().unwrap().inputs.is_empty());
    let mut expected = "gpt-oss-120b";
    for (family, native, label, full) in [
        ("gemini-3.8-flash", "gemini-3.8-flash-medium", "Gemini 3.8 Flash", false),
        ("gpt-oss-120b", "gpt-oss-120b-medium", "GPT-OSS 120B", true),
        ("gemini-3.8-flash", "gemini-3.8-flash-medium", "Gemini 3.8 Flash", false),
    ] {
        {
            let mut state = herdr.lock().unwrap();
            state.allow_question_input = true;
            let ack = format!("Model set to {label} (Medium)");
            state.screens_after_input.push_back([screen(label, full, &ack)].into());
        }
        let result = service.model_set(&json!({"model":family,"expect":{"model":expected,"effort":"medium","identity":identity,"generation":service.generation}})).unwrap();
        assert_eq!(result["confirmed"], true);
        assert_eq!(result["applied"]["model"]["id"], family);
        assert_eq!(result["applied"]["effort"], "medium");
        assert_eq!(herdr.lock().unwrap().inputs.last().unwrap()["params"]["text"], format!("/model {native}"));
        assert_eq!(service.watch.as_ref().unwrap().model_override.as_ref().unwrap().applied.as_ref().unwrap().0, native);
        let mut out = Vec::new();
        service.poll(&mut out).unwrap();
        assert!(frames(out).iter().any(|event| event["event"] == "model.updated" && event["data"]["model"]["id"] == family));
        assert_eq!(service.model_status().unwrap()["model"]["id"], family);
        expected = family;
    }
    assert_eq!(herdr.lock().unwrap().inputs.len(), 3);
    cleanup(&service, root);
}
