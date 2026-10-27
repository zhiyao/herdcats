use super::*;

const TOP: &str = " ┌───────────────────────────────────────────────────────────────────────┐";
const BOTTOM: &str = " └───────────────────────────────────────────────────────────────────────┘";
const HINT_ROWS: [&str; 2] = [
    "↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to",
    "skip",
];

/// One boxed row, padded to the live width like Cursor draws it.
fn row(text: &str) -> String {
    format!(" │ {text:<69} │")
}
fn form(title: &str, position: &str, prompt: &[&str], options: &[&str]) -> String {
    let mut rows = vec![TOP.to_owned(), row(title), row(""), row(position), row("")];
    rows.extend(prompt.iter().map(|p| row(p)));
    rows.push(row(""));
    rows.extend(options.iter().map(|o| row(o)));
    rows.push(row(""));
    rows.extend(HINT_ROWS.iter().map(|h| row(h)));
    rows.push(BOTTOM.to_owned());
    format!("\n  Use your AskQuestion tool.\n\n{}", rows.join("\n"))
}
fn simple() -> String {
    form("README clarifications", "Question 1 of 2", &["1. Which label?"],
        &["  › [ ] Alpha", "    [ ] Beta", "    [ ] Other: (type to answer)"])
}

#[test]
fn parses_a_fresh_single_select_question() {
    let parsed = parse_form(&simple()).expect("form");
    assert_eq!((parsed.index, parsed.total, parsed.multi), (0, 2, false));
    assert_eq!(parsed.title, "README clarifications");
    assert_eq!(parsed.prompt, "Which label?");
    assert_eq!(parsed.options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Alpha", "Beta"]);
    assert!(parsed.options.iter().all(|o| !o.checked));
    assert_eq!((parsed.cursor, parsed.other_checked, parsed.other_text.as_str()), (1, false, ""));
}

#[test]
fn parses_multi_select_checks_the_cursor_row_and_typed_write_in() {
    let screen = form("Clarifying Questions", "Question 2 of 3",
        &["2. Which toppings do you want on your pizza? (multi-select)"],
        &["    [x] Cheese", "    [ ] Ham", "    [x] Olives", "  › [x] Other: Anchovies"]);
    let parsed = parse_form(&screen).expect("form");
    assert_eq!((parsed.index, parsed.total, parsed.multi), (1, 3, true));
    assert_eq!(parsed.prompt, "Which toppings do you want on your pizza?");
    assert_eq!(parsed.options.iter().map(|o| o.checked).collect::<Vec<_>>(), [true, false, true]);
    assert_eq!((parsed.cursor, parsed.other_checked, parsed.other_text.as_str()), (4, true, "Anchovies"));
}

#[test]
fn wrapped_prompts_and_option_labels_join_with_a_space() {
    // Captured from cursor-agent 2026.10.22.
    let screen = form("Clarifying Questions", "Question 1 of 3",
        &["1. Which color would you like for the flag that we are discussing in", "this conversation today, given that it must be visible from far away?"],
        &["  › [ ] Red", "    [ ] Blue", "    [ ] Sky blue with white stripes and a thin yellow border around", "        the edge", "    [ ] Other: (type to answer)"]);
    let parsed = parse_form(&screen).expect("form");
    assert_eq!(parsed.prompt, "Which color would you like for the flag that we are discussing in this conversation today, given that it must be visible from far away?");
    assert_eq!(parsed.options[2].label, "Sky blue with white stripes and a thin yellow border around the edge");
    assert_eq!(parsed.options.len(), 3);
}

#[test]
fn single_select_is_a_radio_and_the_typed_text_survives_unchecking_it() {
    let moved = form("Q", "Question 3 of 3", &["3. Which size?"],
        &["    [x] Small", "    [ ] Large", "  › [ ] Other: Medium"]);
    let parsed = parse_form(&moved).expect("form");
    assert!(!parsed.other_checked);
    assert_eq!(parsed.other_text, "Medium");
    // Two checks in a radio is not a screen this reader knows.
    let two = form("Q", "Question 1 of 1", &["1. Pick?"], &["  › [x] A", "    [x] B", "    [ ] Other: (type to answer)"]);
    assert!(parse_form(&two).is_none());
    // But the same two checks are fine in a multi-select.
    let multi = form("Q", "Question 1 of 1", &["1. Pick? (multi-select)"], &["  › [x] A", "    [x] B", "    [ ] Other: (type to answer)"]);
    assert!(parse_form(&multi).is_some());
}

#[test]
fn the_hint_may_wrap_anywhere_but_must_be_the_known_hint() {
    let narrow = simple().replace(&row(HINT_ROWS[0]), &row("↑/↓ option · ←/→ question ·")).replace(&row("skip"), &row("Space select · Enter next/submit · Esc to skip"));
    assert!(parse_form(&narrow).is_some());
    let other = simple().replace("Esc to", "Esc cancels");
    assert!(parse_form(&other).is_none());
}

#[test]
fn malformed_or_unanchored_boxes_are_not_forms() {
    let ok = simple();
    for broken in [
        ok.replace("Question 1 of 2", "Question 3 of 2"),          // number past total
        ok.replace("Question 1 of 2", "Question 1 of 9"),          // more questions than the client allows
        ok.replace("1. Which label?", "2. Which label?"),          // prompt number disagrees
        ok.replace("    [ ] Other: (type to answer)", "    [ ] Gamma"), // no write-in row
        ok.replace("  › [ ] Alpha", "    [ ] Alpha"),             // no cursor
        ok.replace("    [ ] Beta", "  › [ ] Beta"),                // two cursors
        ok.replace(&row("README clarifications"), &row("")),        // empty title
        ok.replace(BOTTOM, &format!("{BOTTOM}\n  trailing output")), // not the last thing drawn
        ok.replace(TOP, ""),                                        // no top border
        ok.replace(" │ Beta", " │ Beta ┃").replace(&row("    [ ] Beta"), "    [ ] Beta"), // a row outside the box
    ] {
        assert!(parse_form(&broken).is_none(), "{broken}");
    }
    assert!(parse_form("").is_none());
    assert!(parse_form("$ ls\nfoo").is_none());
    // A form quoted in history above a live composer is not a form.
    let quoted = format!("{ok}\n\n ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀");
    assert!(parse_form(&quoted).is_none());
}

#[test]
fn request_ids_are_stable_for_the_question_and_distinct_across_positions_and_asks() {
    let a = parse_form(&simple()).unwrap();
    assert_eq!(request_id(&a, 482), request_id(&parse_form(&simple()).unwrap(), 482));
    // Moving the cursor or checking a row does not change which question it is.
    let moved = parse_form(&simple().replace("  › [ ] Alpha", "    [ ] Alpha").replace("    [ ] Beta", "  › [x] Beta")).unwrap();
    assert_eq!(request_id(&a, 482), request_id(&moved, 482));
    // Another question, another position, or a later ask (longer transcript) differ.
    let next = parse_form(&simple().replace("Question 1 of 2", "Question 2 of 2").replace("1. Which", "2. Which")).unwrap();
    assert_ne!(request_id(&a, 482), request_id(&next, 482));
    assert_ne!(request_id(&a, 482), request_id(&a, 900));
    let other = parse_form(&simple().replace("Which label?", "Which name?")).unwrap();
    assert_ne!(request_id(&a, 482), request_id(&other, 482));
    assert_eq!(request_parts(&request_id(&a, 482)), Some((482, 1, 2)));
    for bad in ["", "cursor:1:2", "cursor-q:x:1of2:aa", "cursor-q:1:1-2:aa", "cursor-q:1:1of2", "cursor-q:1:1of2:aa:extra"] {
        assert_eq!(request_parts(bad), None, "{bad}");
    }
}

#[test]
fn pending_request_matches_only_the_same_question_on_screen() {
    let form = parse_form(&simple()).unwrap();
    let request = pending(&form, 482).expect("client compatible");
    assert_eq!(request.kind, QuestionKind::CursorAsk);
    assert_eq!(request.questions.len(), 1);
    assert_eq!(request.questions[0].header.as_deref(), Some("README clarifications"));
    assert!(request.questions[0].allows_other);
    assert_eq!(request.questions[0].options.iter().map(|o| o.label.as_str()).collect::<Vec<_>>(), ["Alpha", "Beta"]);
    let screen = parse(&simple(), &request).expect("same question");
    assert_eq!(screen.step, QuestionStep::CursorQuestion { index: 0, total: 2 });
    assert_eq!(screen.cursor, Some(QuestionCursor::Option(1)));
    assert_eq!(screen.options.len(), 3, "options plus the write-in row");
    assert!(screen.is_fresh(&request));
    // The desk user moved on: a checked row, typed text or a moved cursor is not fresh.
    for touched in [
        simple().replace("  › [ ] Alpha", "  › [x] Alpha"),
        simple().replace("  › [ ] Alpha", "    [ ] Alpha").replace("    [ ] Beta", "  › [ ] Beta"),
        simple().replace("(type to answer)", "typing"),
    ] {
        let screen = parse(&touched, &request).expect("still the same question");
        assert!(!screen.is_fresh(&request), "{touched}");
    }
    // A different question, position or option set never matches this request.
    for other in [
        simple().replace("Question 1 of 2", "Question 2 of 2").replace("1. Which", "2. Which"),
        simple().replace("Which label?", "Which name?"),
        simple().replace("Beta", "Gamma"),
        simple().replace("README clarifications", "Other title"),
        simple().replace("1. Which label?", "1. Which label? (multi-select)"),
    ] {
        assert!(parse(&other, &request).is_none(), "{other}");
    }
    assert!(parse("", &request).is_none());
}

#[test]
fn oversized_questions_stay_in_terminal() {
    let many: Vec<String> = (0..40).map(|i| format!("    [ ] Option {i}")).collect();
    let mut rows: Vec<&str> = many.iter().map(String::as_str).collect();
    rows[0] = "  › [ ] Option 0";
    rows.push("    [ ] Other: (type to answer)");
    let screen = form("Q", "Question 1 of 1", &["1. Pick one"], &rows);
    // The form parses, but the client contract allows at most 32 options.
    let parsed = parse_form(&screen);
    assert!(parsed.is_none_or(|f| pending(&f, 10).is_none()));
}
