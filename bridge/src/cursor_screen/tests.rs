use super::*;

const BAR_TOP: &str = " ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄";
const BAR_BOTTOM: &str = " ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀";
const RULE: &str = "───────────────────────────────────────────────────────────────────────────";
const BG: &str = "\u{1b}[48;2;47;50;57m";

fn composer(rows: &[&str], footer: &[&str]) -> String {
    let mut screen = vec!["", "  Reply with exactly the word PONG and nothing else.", "", "  PONG", "", BAR_TOP];
    screen.extend(rows);
    screen.push(BAR_BOTTOM);
    screen.extend(footer);
    screen.join("\n")
}
/// The faint placeholder as Cursor paints it: dim arrow and text, with the
/// first letter under the reverse-video cursor.
fn faint(text: &str) -> String {
    let (first, rest) = text.split_at(1);
    format!(
        " \u{1b}[0m{BG} \u{1b}[0m\u{1b}[2m{BG}→ \u{1b}[0m\u{1b}[7m{BG}{first}\u{1b}[0m\u{1b}[2m{BG}{rest}\u{1b}[0m{BG}    \u{1b}[0m"
    )
}
/// Typed text is plain; only the cursor cell is reverse.
fn typed(text: &str) -> String {
    format!(" \u{1b}[0m{BG} → {text}\u{1b}[0m\u{1b}[7m{BG} \u{1b}[0m{BG}    \u{1b}[0m")
}
fn plain(styled: &str) -> String {
    styled.lines().map(|line| {
        let mut out = String::new();
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' {
                for c in chars.by_ref() { if c == 'm' { break; } }
            } else { out.push(c); }
        }
        out.trim_end().to_owned()
    }).collect::<Vec<_>>().join("\n")
}
const FOOTER: [&str; 2] = ["  Claude Opus 5.5 300K Medium · 8.4%", "  /private/tmp/herdcats-cursor-probe"];

fn idle(text: &str) -> (String, String) {
    let styled = composer(&[&faint(text)], &FOOTER);
    (plain(&styled), styled)
}
fn classify_styled(styled: &str) -> Screen { classify(&plain(styled), styled) }

fn card(command_row: &str, allowlist: &str) -> String {
    format!(
        "\n  $ printf X 0ms\n\n{RULE}\n{command_row}\n\n Run this command?\n Shell allowlist is empty\n  → Run (once) (y)\n    {allowlist}\n    Run Everything (shift+tab)\n    Skip & tell the agent what to do instead (esc or n)\n"
    )
}
const OK_CARD_ROW: &str = " $  printf HERDCATS_APPROVAL_PROBE_OK in .";

#[test]
fn faint_placeholders_are_the_only_empty_composer() {
    for placeholder in PLACEHOLDERS {
        let (screen, styled) = idle(placeholder);
        assert_eq!(classify(&screen, &styled), Screen::Idle { mode: None }, "{placeholder}");
    }
}

#[test]
fn typed_text_that_spells_a_placeholder_is_a_draft() {
    let styled = composer(&[&typed("Add a follow-up")], &FOOTER);
    assert_eq!(classify_styled(&styled), Screen::Draft);
    // Without styling the placeholder cannot be told from text: fail closed.
    let (screen, _) = idle("Add a follow-up");
    assert_eq!(classify(&screen, &screen), Screen::Draft);
    for draft in ["draft text here", "/model grok", "x"] {
        assert_eq!(classify_styled(&composer(&[&typed(draft)], &FOOTER)), Screen::Draft, "{draft}");
    }
    // Wrapped multi-row drafts are drafts too.
    let wrapped = composer(&[&typed("first row of a long prompt"), "    second row"], &FOOTER);
    assert_eq!(classify_styled(&wrapped), Screen::Draft);
}

#[test]
fn mode_line_is_reported_and_other_footers_are_tolerated() {
    let styled = composer(&[&faint("Add a follow-up")], &["  Plan (shift+tab to cycle)", FOOTER[0], FOOTER[1]]);
    assert_eq!(classify_styled(&styled), Screen::Idle { mode: Some("Plan".into()) });
    // The host's custom statusline prints arbitrary footer text.
    let custom = composer(&[&faint("Add a follow-up")], &["  Grok 4.5 High High  ░░░░░░░░░░ 6%  73% left  herdcats-cursor-probe"]);
    assert_eq!(classify_styled(&custom), Screen::Idle { mode: None });
    // Too many rows below the composer is an unrecognized layout.
    let tall = composer(&[&faint("Add a follow-up")], &["a", "b", "c", "d", "e"]);
    assert_eq!(classify_styled(&tall), Screen::Unknown);
}

#[test]
fn running_turn_is_busy_even_with_an_empty_looking_composer() {
    let busy = format!(
        "\n  $ printf X 0ms\n    ctrl+b twice to send to background\n\n ⠰⠳ Running  19 tokens\n{BAR_TOP}\n  → Add a follow-up                                        ctrl+c to stop\n{BAR_BOTTOM}\n  1 task\n  Claude Opus 5.5 300K Medium · 8.9%\n  /private/tmp/herdcats-cursor-probe"
    );
    assert_eq!(classify(&busy, &busy), Screen::Busy);
}

#[test]
fn supported_shell_card_parses_with_exact_options() {
    let screen = card(OK_CARD_ROW, "Add Shell(printf) to allowlist? (tab)");
    let Screen::Approval(dialog) = classify(&screen, &screen) else { panic!("expected card") };
    assert_eq!(dialog.detail, ["printf HERDCATS_APPROVAL_PROBE_OK"]);
    assert_eq!(dialog.environment.as_deref(), Some("."));
    assert_eq!(dialog.selected, Some(0));
    let labels: Vec<_> = dialog.options.iter().map(|o| o.label_lines.join(" ")).collect();
    assert_eq!(labels, [
        "Run (once) (y)",
        "Add Shell(printf) to allowlist? (tab)",
        "Run Everything (shift+tab)",
        "Skip & tell the agent what to do instead (esc or n)",
    ]);
    assert!(dialog.options.iter().enumerate().all(|(i, o)| o.number as usize == i + 1 && o.key == OptionKey::Navigate(i)));
    // Compound commands list every prefix in the allowlist label.
    let compound = card(" $  printf a ; echo b in .", "Add Shell(printf), Shell(echo) to allowlist? (tab)");
    assert!(matches!(classify(&compound, &compound), Screen::Approval(_)));
    // A command that itself contains " in " splits at the last one.
    let tricky = card(" $  echo in the garden in .", "Add Shell(echo) to allowlist? (tab)");
    let Screen::Approval(dialog) = classify(&tricky, &tricky) else { panic!() };
    assert_eq!(dialog.detail, ["echo in the garden"]);
}

#[test]
fn selection_moves_without_changing_dialog_identity() {
    let first = card(OK_CARD_ROW, "Add Shell(printf) to allowlist? (tab)");
    let moved = first.replace("  → Run (once) (y)", "    Run (once) (y)").replace("    Skip &", "  → Skip &");
    let (Screen::Approval(a), Screen::Approval(b)) = (classify(&first, &first), classify(&moved, &moved)) else { panic!() };
    assert_eq!((a.selected, b.selected), (Some(0), Some(3)));
    assert!(a.same_dialog(&b));
    let other = card(" $  rm other in .", "Add Shell(printf) to allowlist? (tab)");
    let Screen::Approval(c) = classify(&other, &other) else { panic!() };
    assert!(!a.same_dialog(&c));
}

#[test]
fn unsupported_or_ambiguous_cards_never_parse() {
    let allow = "Add Shell(printf) to allowlist? (tab)";
    // Wrapped command and a cwd suffix pushed onto its own row.
    let wrapped = card(" $  printf 'ALPHA BRAVO\n    CHARLIE DELTA' ; echo in x\n    in .", allow);
    assert_eq!(classify(&wrapped, &wrapped), Screen::UnsupportedCard);
    // No cwd suffix, unknown notice, wrong or reordered labels, two selections.
    assert_eq!(classify(&card(" $  printf X", allow), ""), Screen::UnsupportedCard);
    let notice = card(OK_CARD_ROW, allow).replace("Shell allowlist is empty", "Shell allowlist: ls");
    assert_eq!(classify(&notice, &notice), Screen::UnsupportedCard);
    let renamed = card(OK_CARD_ROW, allow).replace("Run Everything (shift+tab)", "Run Everything (ctrl+r)");
    assert_eq!(classify(&renamed, &renamed), Screen::UnsupportedCard);
    let persistent = card(OK_CARD_ROW, "Add everything to allowlist? (tab)");
    assert_eq!(classify(&persistent, &persistent), Screen::UnsupportedCard);
    let double = card(OK_CARD_ROW, allow).replace("    Run Everything", "  → Run Everything");
    assert_eq!(classify(&double, &double), Screen::UnsupportedCard);
    // An example card quoted in conversation, with the composer below, is history.
    let quoted = format!("{}\n{}", card(OK_CARD_ROW, allow), composer(&[&faint("Add a follow-up")], &FOOTER));
    let (screen, styled) = (plain(&quoted), quoted);
    assert!(!matches!(classify(&screen, &styled), Screen::Approval(_)));
    // Oversized command.
    let big = card(&format!(" $  {} in .", "x".repeat(70_000)), allow);
    assert!(parse_card(&big).is_none());
}

#[test]
fn deny_feedback_question_and_overlays_are_recognized_and_block() {
    let feedback = " │ $  printf X in .                                                      │\n └───────────────────────────────────────────────────────────────────────┘\n ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n  → Tell the agent what to do instead (Enter to send,      ctrl+c to stop\n    empty to skip, Esc to cancel)\n ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀";
    assert_eq!(classify(feedback, feedback), Screen::DenyFeedback);
    let question = " ┌───────────────────────────────────────────────────────────────────────┐\n │ README clarifications                                                 │\n │ Question 1 of 2                                                       │\n │   › [ ] Alpha                                                         │\n │ ↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to │\n │ skip                                                                  │\n └───────────────────────────────────────────────────────────────────────┘";
    assert_eq!(classify(question, question), Screen::Question);
    for overlay in [
        " Available models                                            Max mode: OFF\n\n Filter:\n\n →  Grok 4.5                 High (Tab to modify)\n\n Type to filter • Enter to select • Tab to edit",
        " Grok 4.7 — Edit Parameters                                  Max mode: OFF\n\n  Effort\n    ○ Low\n\n ↑/↓ to navigate • Enter to select • Esc to go back",
    ] {
        assert_eq!(classify(overlay, overlay), Screen::Overlay);
    }
    assert_eq!(classify("", ""), Screen::Unknown);
    assert_eq!(classify("$ ls\nfoo", "$ ls\nfoo"), Screen::Unknown);
}

#[test]
fn history_that_mentions_a_card_or_form_does_not_block_a_real_idle_composer() {
    let mut screen = vec![
        "  The card said \"Run this command?\" and the form said Question 1 of 2.".to_owned(),
        "  Press Space select, then Enter next/submit.".to_owned(),
    ];
    screen.extend((0..50).map(|n| format!("  filler {n}")));
    let tail = composer(&[&faint("Add a follow-up")], &FOOTER);
    let styled = format!("{}\n{tail}", screen.join("\n"));
    assert_eq!(classify_styled(&styled), Screen::Idle { mode: None });
}
