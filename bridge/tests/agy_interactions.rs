use herdcats_bridge::{
    approval_screen, hooks::Agent, question_keys, question_match, question_screen,
};
use serde_json::{Value, json};
const APPROVAL: &str = "Command\nRequesting permission for:\n   printf SAFE\n\nRun this command?\n> 1. Yes, run command\n  2. Yes, and always allow in this conversation for commands that start with 'printf'\n  3. Yes, and always allow for commands that start with 'printf' (Persist to settings.json)\n  4. No, cancel\n\n↑/↓ Navigate · tab Amend · ctrl+g edit/expand command";
#[test]
fn agy_approval_exact_command_and_scope_navigation() {
    let d = approval_screen::parse(Agent::Agy, APPROVAL, "printf SAFE").unwrap();
    assert!(approval_screen::parse(Agent::Agy, APPROVAL, "printf OTHER").is_none());
    assert_eq!(
        approval_screen::agy_plan(&d, 3).unwrap(),
        vec![
            ("down".into(), Some(1)),
            ("down".into(), Some(2)),
            ("down".into(), Some(3)),
            ("enter".into(), None)
        ]
    );
    assert!(
        approval_screen::parse(
            Agent::Agy,
            &APPROVAL.replace("in this conversation", "everywhere"),
            "printf SAFE"
        )
        .is_none()
    );
    assert!(
        approval_screen::parse(
            Agent::Agy,
            &APPROVAL.replace("Command\n", "URL\n"),
            "printf SAFE"
        )
        .is_none()
    );
}
fn fixture() -> Vec<Value> {
    include_str!("../../ios/docs/research/fixtures/agy-1.4.7-synthetic-interactions.jsonl")
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect()
}
#[test]
fn agy_done_planner_remains_pending_until_generic_result() {
    let history = fixture();
    let qs = question_match::pending_agy_questions(&history[..2]);
    assert_eq!(qs.len(), 1);
    assert_eq!(qs[0].request_id, "agy:1:tool:0");
    assert_eq!(qs[0].questions[0].options[1].label, "Blue");
    assert!(question_match::pending_agy_questions(&history[..3]).is_empty());
    let screen = "Question 1/1: Which probe color?\n> 1. (Recommended) Red\n  2. Blue\n  3. Write-in...\n  ↑/↓ Navigate · enter Submit · esc Skip";
    let parsed = question_screen::parse(qs[0].kind, screen, &qs[0]).unwrap();
    let plan = question_keys::plan(
        qs[0].kind,
        &qs[0],
        &parsed,
        &json!({"answers":[{"index":0,"options":[2]}]}),
    )
    .unwrap();
    assert_eq!(plan.len(), 2);
    assert_eq!(
        plan[0].input,
        question_keys::Input::Keys(vec!["down".into()])
    );
    assert_eq!(
        plan[1].input,
        question_keys::Input::Keys(vec!["enter".into()])
    );
    assert!(question_screen::parse(qs[0].kind, &screen.replace("Blue", "Green"), &qs[0]).is_none());
}
#[test]
fn agy_write_in_and_multi_select_are_guarded() {
    let qs = question_match::pending_agy_questions(&fixture()[..10]);
    let p = &qs[0];
    let screen = "Question 1/2: Which label?\n> 1. (Recommended) Alpha\n  2. Beta\n  3. Write-in...\n  ↑/↓ Navigate · enter Submit · esc Skip";
    let parsed = question_screen::parse(p.kind, screen, p).unwrap();
    let plan = question_keys::plan(
        p.kind,
        p,
        &parsed,
        &json!({"answers":[{"index":0,"options":[],"text":"Gamma"},{"index":1,"options":[1,3]}]}),
    )
    .unwrap();
    assert!(plan.iter().all(|s| match &s.input {
        question_keys::Input::Keys(keys) => keys.len() == 1,
        _ => true,
    }));
    assert!(
        plan.iter()
            .any(|s| s.input == question_keys::Input::Text("Gamma".into()))
    );
    assert_eq!(
        plan.iter()
            .filter(|s| s.input == question_keys::Input::Keys(vec!["space".into()]))
            .count(),
        2
    );
    let multi = "Question 2/2: Which probe features?\n> 1. [x] (Recommended) One\n  2. [ ] Two\n  3. [ ] Three\n  4. Write-in...\n  ↑/↓ Navigate · ← Back · space Toggle · enter Submit All · esc Skip";
    assert!(question_screen::parse(p.kind, multi, p).is_some());
    let editor = "Question 1/2: Which label?\n  1. (Recommended) Alpha\n  2. Beta\n> 3. Write-in...\n  Your answer: Gamma\n  enter Submit · esc Back";
    assert_eq!(
        question_screen::parse(p.kind, editor, p)
            .unwrap()
            .free_text
            .unwrap()
            .text,
        "Gamma"
    );
}

#[test]
fn agy_command_candidates_decode_typed_nested_json_and_retire_on_error() {
    use herdcats_bridge::approval_match::pending_agy_commands;
    let history = fixture();
    let pending = pending_agy_commands("conversation", &history[..6]);
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].request_id, "agy:5:tool:0");
    assert_eq!(
        pending[0].tool_input,
        json!({"command":"printf HERDCATS_APPROVAL_PROBE_OK"})
    );
    assert!(pending_agy_commands("conversation", &history[..7]).is_empty());
    assert_eq!(
        pending_agy_commands("conversation", &history[..14]).len(),
        1
    );
    assert!(pending_agy_commands("conversation", &history).is_empty());
    let mut malformed = history[..6].to_vec();
    malformed[5]["tool_calls"][0]["args"]["CommandLine"] = json!("printf NOT_JSON");
    assert!(pending_agy_commands("conversation", &malformed).is_empty());
    assert!(pending_agy_commands("", &history[..6]).is_empty());
}

#[test]
fn agy_questions_reject_malformed_arguments_and_ambiguous_step_rewrites() {
    let mut h = fixture()[..2].to_vec();
    let original = h[1].clone();
    h[1]["tool_calls"][0]["args"]["questions"] =
        json!([{"question":"bad","options":["one"],"is_multi_select":false}]);
    assert!(question_match::pending_agy_questions(&h).is_empty());
    h[1] = original.clone();
    h.push(original);
    assert!(question_match::pending_agy_questions(&h).is_empty());
}

#[test]
fn agy_rejects_stale_partial_and_duplicate_screens() {
    let p = question_match::pending_agy_questions(&fixture()[..2]).remove(0);
    let screen = "Question 1/1: Which probe color?\n> 1. (Recommended) Red\n  2. Blue\n  3. Write-in...\n  ↑/↓ Navigate · enter Submit · esc Skip";
    assert!(question_screen::parse(p.kind, &format!("{screen}\n{screen}"), &p).is_none());
    assert!(
        question_screen::parse(p.kind, &screen.replace("esc Skip", "esc Unknown"), &p).is_none()
    );
    let edited = screen.replace("> 1.", "  1.").replace("  2.", "> 2.");
    let parsed = question_screen::parse(p.kind, &edited, &p).unwrap();
    assert!(
        question_keys::plan(
            p.kind,
            &p,
            &parsed,
            &json!({"answers":[{"index":0,"options":[2]}]})
        )
        .is_err()
    );
    assert!(
        approval_screen::parse(
            Agent::Agy,
            &format!("{APPROVAL}\n{APPROVAL}"),
            "printf SAFE"
        )
        .is_none()
    );
}

#[test]
fn agy_navigation_verifies_every_intermediate_question_state() {
    let p = question_match::pending_agy_questions(&fixture()[..10]).remove(0);
    let screen = "Question 1/2: Which label?\n> 1. (Recommended) Alpha\n  2. Beta\n  3. Write-in...\n  ↑/↓ Navigate · enter Submit · esc Skip";
    let parsed = question_screen::parse(p.kind, screen, &p).unwrap();
    let plan = question_keys::plan(
        p.kind,
        &p,
        &parsed,
        &json!({"answers":[{"index":0,"options":[],"text":"Gamma"},{"index":1,"options":[1,3]}]}),
    )
    .unwrap();
    let after_down = screen.replace("> 1.", "  1.").replace("  2.", "> 2.");
    let state = question_screen::parse(p.kind, &after_down, &p).unwrap();
    assert!(plan[0].expected.matches(Some(&state)));
    assert!(!plan[1].expected.matches(Some(&state)));
    let other = after_down.replace("> 2.", "  2.").replace("  3.", "> 3.");
    let state = question_screen::parse(p.kind, &other, &p).unwrap();
    assert!(plan[1].expected.matches(Some(&state)));
    let editor = other.replace(
        "↑/↓ Navigate · enter Submit · esc Skip",
        "Your answer:\n  enter Submit · esc Back",
    );
    let state = question_screen::parse(p.kind, &editor, &p).unwrap();
    assert!(plan[2].expected.matches(Some(&state)));
    let typed = editor.replace("Your answer:", "Your answer: Gamma");
    let state = question_screen::parse(p.kind, &typed, &p).unwrap();
    assert!(plan[3].expected.matches(Some(&state)));
    let multi = "Question 2/2: Which probe features?\n> 1. [ ] (Recommended) One\n  2. [ ] Two\n  3. [ ] Three\n  4. Write-in...\n  ↑/↓ Navigate · ← Back · space Toggle · enter Submit All · esc Skip";
    let state = question_screen::parse(p.kind, multi, &p).unwrap();
    assert!(plan[4].expected.matches(Some(&state)));
    let checked = multi.replace("[ ] (Recommended) One", "[x] (Recommended) One");
    let state = question_screen::parse(p.kind, &checked, &p).unwrap();
    assert!(plan[5].expected.matches(Some(&state)));
}

#[test]
fn agy_live_select_and_write_in_footers_match_cursor_and_question_position() {
    let p = question_match::pending_agy_questions(&fixture()[..10]).remove(0);
    let first = "Question 1/2: Which label?\n> 1. (Recommended) Alpha\n  2. Beta\n  3. Write-in...\n  ↑/↓ Navigate · → Next · enter Select · esc Skip";
    assert!(question_screen::parse(p.kind, first, &p).is_some());
    let other = first
        .replace("> 1.", "  1.")
        .replace("  3.", "> 3.")
        .replace("enter Select", "enter Write-in");
    assert!(question_screen::parse(p.kind, &other, &p).is_some());
    assert!(
        question_screen::parse(p.kind, &first.replace("enter Select", "enter Write-in"), &p)
            .is_none()
    );
    let mut calls = fixture()[..2].to_vec();
    let extra = calls[1]["tool_calls"][0].clone();
    calls[1]["tool_calls"].as_array_mut().unwrap().push(extra);
    assert!(question_match::pending_agy_questions(&calls).is_empty());
}

#[test]
fn agy_review_footer_is_exact_and_quoted_history_cannot_claim_current_dialog() {
    let current = APPROVAL
        .replace("Command\n", "Command\n────────────────────────\n\n")
        .replace("edit/expand command", "edit/expand command · ctrl+r Review");
    assert!(approval_screen::parse(Agent::Agy, &current, "printf SAFE").is_some());
    assert!(approval_screen::parse(Agent::Agy, &current, "printf OTHER").is_none());
    assert!(
        approval_screen::parse(
            Agent::Agy,
            &current.replace("ctrl+r Review", "ctrl+x Unknown"),
            "printf SAFE"
        )
        .is_none()
    );
    assert!(
        approval_screen::parse(
            Agent::Agy,
            &current.replace("in this conversation", "in every conversation"),
            "printf SAFE"
        )
        .is_none()
    );
    let quoted = format!("Historical example:\n```text\n{APPROVAL}\n```\n");
    assert!(approval_screen::parse(Agent::Agy, &quoted, "printf SAFE").is_none());
    let combined = format!("{quoted}\n{current}");
    let dialog = approval_screen::parse(Agent::Agy, &combined, "printf SAFE").unwrap();
    assert_eq!(dialog.title, "Command");
    assert_eq!(dialog.options.len(), 4);
}

#[test]
fn agy_question_fenced_history_is_not_a_live_picker_or_ambiguity() {
    let pending = question_match::pending_agy_questions(&fixture()[..2]).remove(0);
    let live = "Question 1/1: Which probe color?\n> 1. (Recommended) Red\n  2. Blue\n  3. Write-in...\n↑/↓ Navigate · enter Select · esc Skip";
    for (open, close) in [("```text", "```"), ("~~~text", "~~~")] {
        let quoted = format!("Historical example:\n{open}\n{live}\n{close}\n");
        assert!(question_screen::parse(pending.kind, &quoted, &pending).is_none());
        assert!(question_screen::parse(pending.kind, &format!("{quoted}\n{live}"), &pending).is_some());
        assert!(question_screen::parse(pending.kind, &format!("{open}\n{live}"), &pending).is_none());
    }
    assert!(question_screen::parse(pending.kind, &format!("{live}\n{live}"), &pending).is_none());
}

fn agy_question_history(questions: Vec<Value>) -> Vec<Value> {
    vec![json!({"type":"PLANNER_RESPONSE","source":"MODEL","step_index":1,"status":"DONE","created_at":"2026-10-25T08:39:44Z",
        "tool_calls":[{"name":"ask_question","args":{"questions":serde_json::to_string(&questions).unwrap()}}]})]
}
fn agy_question_value(text: &str, labels: Vec<String>) -> Value {
    json!({"question":text,"options":labels,"is_multi_select":false})
}
#[test]
fn agy_pending_questions_match_client_count_and_utf8_byte_boundaries() {
    let ordinary = agy_question_value("Question?", vec!["Choice".into()]);
    for (questions, accepted) in [
        (vec![ordinary.clone(); 8], true), (vec![ordinary; 9], false),
        (vec![agy_question_value("Question?", vec!["Choice".into(); 32])], true),
        (vec![agy_question_value("Question?", vec!["Choice".into(); 33])], false),
        (vec![agy_question_value(&"é".repeat(2048), vec!["Choice".into()])], true),
        (vec![agy_question_value(&format!("{}a", "é".repeat(2048)), vec!["Choice".into()])], false),
        (vec![agy_question_value("Question?", vec!["é".repeat(512)])], true),
        (vec![agy_question_value("Question?", vec![format!("{}a", "é".repeat(512))])], false),
    ] {
        assert_eq!(!question_match::pending_agy_questions(&agy_question_history(questions)).is_empty(), accepted);
    }
}

#[test]
fn agy_client_wire_limits_include_optional_header_and_description_bytes() {
    let mut pending = question_match::pending_agy_questions(&fixture()[..2]).remove(0);
    pending.questions[0].header = Some("é".repeat(512));
    pending.questions[0].options[0].description = Some("é".repeat(2048));
    assert!(pending.client_compatible());
    pending.questions[0].header.as_mut().unwrap().push('a');
    assert!(!pending.client_compatible());
    pending.questions[0].header.as_mut().unwrap().pop();
    pending.questions[0].options[0].description.as_mut().unwrap().push('a');
    assert!(!pending.client_compatible());
}
