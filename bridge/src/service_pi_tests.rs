use serde_json::json;
#[test]
fn pi_actions_reject_wrong_instance_generation_and_model_before_socket_access() {
    let mut service = Service::with_resolvers(PathBuf::from("unused.sock"), None, None);
    let identity = Identity {
        pane_id: "pane".into(),
        terminal_id: "terminal".into(),
        agent: "pi".into(),
        native_session_id: "16246b9d-4c3d-54fc-b6d3-2a765d418491".into(),
        native_instance_id: Some("runtime-a".into()),
    };
    service.generation = 7;
    service.watch = Some(Watch {
        pane_id: "pane".into(),
        identity: Some(identity.clone()),
        follower: Follower::default(),
        generation: 7,
        previous: Vec::new(),
        unavailable: None,
        status: "idle".into(),
        unknown_records: 0,
        dropped_entries: 0,
        source_changing_count: 0,
        delayed: false,
        agent: Some("pi".into()),
        unavailable_agent: None,
        last_daemon_status: None,
        pending: None,
        approval_cache: None,
        question_cache: None,
        source_pane: None,
        model_stamp: None,
        last_model: None,
        model_override: None,
        pi_state: Some(json!({"revision":9,"instance_id":"runtime-a",
            "model":{"id":"provider/model-a","effort":"low"}})),
        pi_dialog: None,
    });
    let base = json!({"pane_id":"pane","expect":{"identity":identity,"generation":7,
        "model":"provider/model-a","effort":"low"},"model":"provider/model-b","effort":"high"});
    assert_eq!(service.pi_action("model.set", &base).unwrap_err(), "stale");
    let mut stale = base.clone();
    stale["expect"]["identity"]["native_instance_id"] = json!("runtime-old");
    assert_eq!(service.pi_action("model.set", &stale).unwrap_err(), "stale");
    let mut stale = base.clone();
    stale["expect"]["generation"] = json!(6);
    assert_eq!(service.pi_action("model.set", &stale).unwrap_err(), "stale");
    let mut stale = base;
    stale["expect"]["model"] = json!("provider/old-model");
    assert_eq!(service.pi_action("model.set", &stale).unwrap_err(), "stale");
}

#[test]
fn pi_fresh_session_prompt_persists_without_identity_or_generation_reset() {
    let root = PathBuf::from("/tmp").join(format!("pi-bootstrap-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("sessions/project")).unwrap();
    fs::create_dir_all(root.join("herdcats")).unwrap();
    let root = root.canonicalize().unwrap();
    let session = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
    let path = root.join(format!("sessions/project/2026-10-26_{session}.jsonl"));
    let socket = root.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let pane = json!({"pane_id":"pane","terminal_id":"terminal","agent":"pi","agent_status":"idle","agent_session":{"agent":"pi","source":"herdr:pi","kind":"path","value":path}});
    let h = thread::spawn(move || {
        for _ in 0..5 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            writeln!(stream,"{}",json!({"id":request["id"],"result":{"type":"session_snapshot","snapshot":{"protocol":22,"panes":[pane]}}})).unwrap();
        }
    });
    let listener = UnixListener::bind(root.join(format!("herdcats/{session}.sock"))).unwrap();
    let state_path = path.clone();
    let extension = thread::spawn(move || {
        let mut entries = json!([]);
        for index in 0..5 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut line)
                .unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let result = if request["method"] == "prompt" {
                assert_eq!(request["params"]["expect"]["instance_id"], "runtime");
                assert_eq!(request["params"]["text"], "first fixture prompt");
                fs::write(
                    &state_path,
                    format!("{{\"type\":\"session\",\"id\":\"{session}\"}}\n"),
                )
                .unwrap();
                entries = json!([{"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"first fixture prompt"}]}}]);
                json!({"accepted":true})
            } else {
                json!({"version":"1.4.0","session_id":session,"session_file":state_path,"instance_id":"runtime","revision":1,"entries":entries,"status":"idle"})
            };
            let mut result = result;
            if index == 3 {
                result["session_file"] = json!("/wrong/session.jsonl");
            }
            if index == 4 {
                result["session_id"] = json!("00000000-0000-0000-0000-000000000000");
            }
            writeln!(stream, "{}", json!({"result":result})).unwrap();
        }
    });
    let mut service = Service::with_resolvers(socket, None, None).with_pi_agent_dir(root.clone());
    service.initialized = true;
    service
        .request(
            br#"{"id":"w","method":"watch","params":{"pane_id":"pane"}}"#,
            &mut Vec::new(),
        )
        .unwrap();
    let identity = service
        .watch
        .as_ref()
        .unwrap()
        .identity
        .clone()
        .expect("fresh live identity");
    let generation = service.generation;
    assert!(!path.exists());
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
    service.pi_action("prompt", &json!({"pane_id":"pane","text":"first fixture prompt","expect":{"identity":identity,"generation":generation}})).unwrap();
    service.poll(&mut Vec::new()).unwrap();
    let watch = service.watch.as_ref().unwrap();
    assert!(watch.identity.as_ref() == Some(&identity));
    assert_eq!(service.generation, generation);
    assert_eq!(watch.follower.transcript.entries.len(), 1);
    assert_eq!(
        watch.follower.transcript.entries[0].text,
        "first fixture prompt"
    );
    let stale = json!({"pane_id":"pane","text":"stale fixture", "expect":{"identity":identity,"generation":generation + 1}});
    assert_eq!(service.pi_action("prompt", &stale).unwrap_err(), "stale");
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(
        service.watch.as_ref().unwrap().unavailable,
        Some("session_mismatch")
    );
    service.poll(&mut Vec::new()).unwrap();
    assert_eq!(
        service.watch.as_ref().unwrap().unavailable,
        Some("invalid_pi_response")
    );
    h.join().unwrap();
    extension.join().unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pi_model_success_includes_the_ios_session_envelope() {
    pi_model_reply_fixture(true, false);
}

#[test]
fn pi_legacy_applied_reply_is_confirmed_without_repeating_the_mutation() {
    pi_model_reply_fixture(false, false);
}

#[test]
fn pi_legacy_applied_reply_must_match_the_requested_effort() {
    pi_model_reply_fixture(false, true);
}

fn pi_model_reply_fixture(confirmed: bool, mismatched_effort: bool) {
    let root = PathBuf::from("/tmp").join(format!("pi-model-{}-{confirmed}-{mismatched_effort}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("sessions/project")).unwrap();
    fs::create_dir_all(root.join("herdcats")).unwrap();
    let root = root.canonicalize().unwrap();
    let session = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
    let path = root.join(format!("sessions/project/2026-10-26_{session}.jsonl"));
    fs::write(&path, format!("{{\"type\":\"session\",\"id\":\"{session}\"}}\n")).unwrap();
    let socket = root.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let pane = json!({"pane_id":"pane","terminal_id":"terminal","agent":"pi","agent_status":"idle","agent_session":{"agent":"pi","source":"herdr:pi","kind":"path","value":path}});
    let host = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        writeln!(stream,"{}",json!({"id":request["id"],"result":{"type":"session_snapshot","snapshot":{"protocol":22,"panes":[pane]}}})).unwrap();
    });
    let listener = UnixListener::bind(root.join(format!("herdcats/{session}.sock"))).unwrap();
    let extension = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["method"], "model.set");
        assert_eq!(request["params"]["expect"], json!({"session_id":session,"instance_id":"runtime-a","revision":9}));
        let mut result=json!({"applied":true,"model":{"id":"provider/model-b","label":"Model B","effort":if mismatched_effort {"low"} else {"high"}}});
        if confirmed { result["confirmed"]=json!(true); }
        writeln!(stream,"{}",json!({"result":result})).unwrap();
    });
    let mut service = Service::with_resolvers(socket, None, None).with_pi_agent_dir(root.clone());
    let identity = Identity {
        pane_id: "pane".into(),
        terminal_id: "terminal".into(),
        agent: "pi".into(),
        native_session_id: "16246b9d-4c3d-54fc-b6d3-2a765d418491".into(),
        native_instance_id: Some("runtime-a".into()),
    };
    service.generation = 7;
    service.watch = Some(Watch {
        pane_id: "pane".into(),
        identity: Some(identity.clone()),
        follower: Follower::default(),
        generation: 7,
        previous: Vec::new(),
        unavailable: None,
        status: "idle".into(),
        unknown_records: 0,
        dropped_entries: 0,
        source_changing_count: 0,
        delayed: false,
        agent: Some("pi".into()),
        unavailable_agent: None,
        last_daemon_status: None,
        pending: None,
        approval_cache: None,
        question_cache: None,
        source_pane: None,
        model_stamp: None,
        last_model: None,
        model_override: None,
        pi_state: Some(json!({"revision":9,"instance_id":"runtime-a",
            "session_file":path,"model":{"id":"provider/model-a","effort":"low"}})),
        pi_dialog: None,
    });

    let result = service.pi_action("model.set", &json!({"pane_id":"pane","expect":{"identity":identity,"generation":7,
        "model":"provider/model-a","effort":"low"},"model":"provider/model-b","effort":"high"}));
    host.join().unwrap();
    extension.join().unwrap();
    fs::remove_dir_all(root).unwrap();
    if mismatched_effort {
        assert_eq!(result.unwrap_err(), "unconfirmed");
        return;
    }
    let result=result.unwrap();
    assert_eq!(result["identity"], json!(identity));
    assert_eq!(result["generation"], 7);
    assert_eq!(result["confirmed"], true);
    assert_eq!(result["applied"]["model"]["id"], "provider/model-b");
    assert_eq!(result["applied"]["effort"], "high");
}

#[test]
fn pi_consecutive_effort_changes_publish_updates_without_reloading_watch() {
    let root = PathBuf::from("/tmp").join(format!("pi-repeat-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("sessions/project")).unwrap();
    fs::create_dir_all(root.join("herdcats")).unwrap();
    let root = root.canonicalize().unwrap();
    let session = "16246b9d-4c3d-54fc-b6d3-2a765d418491";
    let path = root.join(format!("sessions/project/2026-10-26_{session}.jsonl"));
    fs::write(&path, format!("{{\"type\":\"session\",\"id\":\"{session}\"}}\n")).unwrap();
    let socket = root.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let pane = json!({"pane_id":"pane","terminal_id":"terminal","agent":"pi","agent_status":"idle","agent_session":{"agent":"pi","source":"herdr:pi","kind":"path","value":path}});
    let host = thread::spawn(move || {
        for _ in 0..7 {
        let (mut stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let request: Value = serde_json::from_str(&line).unwrap();
        writeln!(stream,"{}",json!({"id":request["id"],"result":{"type":"session_snapshot","snapshot":{"protocol":22,"panes":[pane]}}})).unwrap();
        }
    });
    let listener = UnixListener::bind(root.join(format!("herdcats/{session}.sock"))).unwrap();
    let extension = thread::spawn(move || {
        let mut effort = json!("low");
        let mut revision = 1;
        for _ in 0..7 {
            let (mut stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            let result = if request["method"] == "model.set" {
                assert_eq!(request["params"]["expect"]["revision"], revision);
                effort = request["params"]["effort"].clone(); revision += 1;
                json!({"applied":true,"model":{"id":"provider/model-a","label":"Model A","effort":effort}})
            } else {
                json!({"version":"1.4.0","session_id":session,"session_file":path,"instance_id":"runtime-a","revision":revision,"entries":[],"status":"idle","model":{"id":"provider/model-a","label":"Model A","effort":effort}})
            };
            writeln!(stream,"{}",json!({"result":result})).unwrap();
        }
    });
    let mut service = Service::with_resolvers(socket, None, None).with_pi_agent_dir(root.clone());
    service.initialized = true;
    service.include_model_control = true;
    service.request(br#"{"id":"w","method":"watch","params":{"pane_id":"pane"}}"#, &mut Vec::new()).unwrap();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let generation = service.generation;
    let mut previous = "low";
    for effort in ["high", "low"] {
        let request = json!({"id":"change","method":"model.set","params":{"pane_id":"pane","effort":effort,
            "expect":{"identity":identity,"generation":generation,"model":"provider/model-a","effort":previous}}});
        let mut output=Vec::new();
        service.request(&serde_json::to_vec(&request).unwrap(), &mut output).unwrap();
        let frames:Vec<Value> = String::from_utf8(output).unwrap().lines().map(|s|serde_json::from_str(s).unwrap()).collect();
        assert!(frames.iter().any(|f|f["id"]=="change" && f["result"]["confirmed"]==true));
        assert!(frames.iter().any(|f|f["event"]=="model.updated" && f["data"]["effort"]==effort));
        assert!(!frames.iter().any(|f|f["event"]=="timeline.snapshot" || f["event"]=="timeline.unavailable"));
        assert_eq!(service.generation,generation);
        previous=effort;
    }
    host.join().unwrap(); extension.join().unwrap(); fs::remove_dir_all(root).unwrap();
}
