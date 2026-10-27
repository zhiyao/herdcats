use super::*;

const COMPOSER: &str = "\n ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n  → Plan, search, build anything\n ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\n";

/// Captured from cursor-agent 2026.10.22: cursor on the last of 46 rows.
fn picker_last() -> String {
    format!("{COMPOSER} Available models                                            Max mode: OFF\n\n Filter:\n\n    Gemini 3 Flash\n    Gemini 3.5 Flash\n    Claude Sonnet 4          No Thinking\n    GPT-5 Mini\n    Kimi K3                  Max\n    Kimi K2.7 Code\n    GLM 5.2                  High\n    GLM 5.3                  High\n    GLM 5.3 Flash            High\n →  DeepSeek V4.1 Flash 1017 High (Tab to modify)\n\n 37-46 of 46\n\n Type to filter • Enter to select • Tab to edit\n")
}
fn picker_top() -> String {
    format!("{COMPOSER} Available models                                            Max mode: OFF\n\n Filter:\n\n →  Auto (Tab to modify)\n    Grok 4.7                 500K Low Fast\n    Grok 4.6                 High\n    Composer 2.5             Fast\n    Claude Opus 5.5          300K Medium\n    Claude Opus 5            300K Low\n    Claude Opus 4.8          300K High\n    Gemini 4 Argon           Medium\n    Muse Wonder              300K High\n    GPT-5.6 Sol              272K Medium\n\n 1-10 of 46\n\n Type to filter • Enter to select • Tab to edit\n")
}

#[test]
fn picker_rows_split_at_the_fixed_label_column() {
    let picker = parse_picker(&picker_last()).expect("picker");
    assert_eq!(picker.window, Some((37, 46, 46)));
    assert_eq!(picker.rows.len(), 10);
    assert_eq!(picker.cursor_label(), Some("DeepSeek V4.1 Flash 1017"));
    // A 24-character label leaves one space before its parameters.
    let last = picker.rows.last().unwrap();
    assert_eq!((last.label.as_str(), last.params.as_str()), ("DeepSeek V4.1 Flash 1017", "High"));
    let by_label = |l: &str| picker.rows.iter().find(|r| r.label == l).unwrap().params.clone();
    assert_eq!(by_label("Claude Sonnet 4"), "No Thinking");
    assert_eq!(by_label("Kimi K3"), "Max");
    assert_eq!(by_label("Gemini 3 Flash"), "");
    assert_eq!(picker.cursor_index(), Some(45));
}

#[test]
fn picker_top_window_and_cursor_without_parameters() {
    let picker = parse_picker(&picker_top()).expect("picker");
    assert_eq!(picker.window, Some((1, 10, 46)));
    assert_eq!(picker.cursor_label(), Some("Auto"));
    assert_eq!(picker.cursor_index(), Some(0));
    assert_eq!(picker.rows[1].params, "500K Low Fast");
    assert_eq!(picker.rows[3].params, "Fast");
}

#[test]
fn filtered_picker_and_no_match_titles_parse() {
    let filtered = picker_top().replace("Available models", "Models matching \"opus\"     ").replace(" Filter:\n", " Filter: opus\n");
    let picker = parse_picker(&filtered).expect("picker");
    assert_eq!(picker.filter, "opus");
    let none = format!("{COMPOSER} Models matching \"grok-4.7-low\" (no matches)                 Max mode: OFF\n\n Filter: grok-4.7-low\n\n\n Type to filter • Enter to select • Tab to edit\n");
    let picker = parse_picker(&none).expect("picker");
    assert!(picker.no_matches && picker.rows.is_empty() && picker.cursor_label().is_none());
}

#[test]
fn malformed_pickers_are_rejected() {
    assert!(parse_picker("").is_none());
    assert!(parse_picker(COMPOSER).is_none());
    // Two cursors.
    assert!(parse_picker(&picker_top().replace("    Grok 4.7 ", " →  Grok 4.7 ")).is_none());
    // A window that disagrees with the rows shown.
    assert!(parse_picker(&picker_top().replace("1-10 of 46", "1-9 of 46")).is_none());
    assert!(parse_picker(&picker_top().replace("1-10 of 46", "1-10 of 500")).is_none());
    // A label longer than the column cannot be split from its parameters.
    assert!(parse_picker(&picker_top().replace("Grok 4.6                 High", "A label that is far too long High")).is_none());
    // A row that is neither a marker row nor a plain row.
    assert!(parse_picker(&picker_top().replace("    Grok 4.6 ", "  ?  Grok 4.6 ")).is_none());
}

fn editor(title: &str, body: &str) -> String {
    format!("{COMPOSER} {title} — Edit Parameters                               Max mode: OFF\n{body}\n ↑/↓ to navigate • Enter to select • Esc to go back\n")
}

#[test]
fn editor_reads_groups_radios_checkboxes_and_the_cursor() {
    let screen = editor("Claude Opus 5", "\n  Context\n  → ● 300K ✓\n    ○ 1M\n\n  Effort\n    ● Low ✓\n    ○ Medium\n    ○ High\n    ○ Extra High\n    ○ Max\n\n    ◉ Thinking\n\n    ◯ Fast\n");
    let editor = parse_editor(&screen).expect("editor");
    assert_eq!(editor.label, "Claude Opus 5");
    assert_eq!(editor.items.len(), 9);
    assert_eq!(editor.cursor, 0);
    assert_eq!(editor.current_effort(), Some("low"));
    assert_eq!(
        editor.efforts().unwrap().iter().map(|(id, _)| *id).collect::<Vec<_>>(),
        ["low", "medium", "high", "xhigh", "max"]
    );
    let fast = editor.items.last().unwrap();
    assert_eq!((fast.text.as_str(), &fast.kind, fast.group.as_deref()), ("Fast", &ItemKind::Check(false), None));
}

#[test]
fn reasoning_groups_count_as_effort_and_other_shapes_are_handled() {
    let gpt = parse_editor(&editor("GPT-5.6 Sol", "\n  Context\n  → ● 272K ✓\n    ○ 1M\n\n  Reasoning\n    ○ None\n    ○ Low\n    ● Medium ✓\n    ○ High\n    ○ Extra High\n    ○ Max\n\n    ◯ Fast\n")).unwrap();
    assert_eq!(gpt.current_effort(), Some("medium"));
    assert_eq!(gpt.efforts().unwrap().len(), 6);
    // Only an effort-less toggle: no efforts, never a guess.
    let composer = parse_editor(&editor("Composer 2.5", "\n\n  → ◉ Fast\n")).unwrap();
    assert!(composer.efforts().is_none() && composer.current_effort().is_none());
    // The cursor can start outside the effort group.
    let kimi = parse_editor(&editor("Kimi K3", "\n  Reasoning\n  → ○ Low\n    ○ High\n    ● Max ✓\n")).unwrap();
    assert_eq!((kimi.cursor, kimi.current_effort()), (0, Some("max")));
}

#[test]
fn malformed_editors_are_rejected() {
    let ok = editor("Kimi K3", "\n  Reasoning\n  → ○ Low\n    ○ High\n    ● Max ✓\n");
    assert!(parse_editor(&ok).is_some());
    assert!(parse_editor("").is_none());
    assert!(parse_editor(&ok.replace("  → ○ Low", "    ○ Low")).is_none(), "no cursor");
    assert!(parse_editor(&ok.replace("    ○ High", "  → ○ High")).is_none(), "two cursors");
    assert!(parse_editor(&ok.replace("    ○ High", "    ● High ✓")).is_none(), "two selected radios");
    assert!(parse_editor(&ok.replace(" ↑/↓ to navigate • Enter to select • Esc to go back\n", "")).is_none(), "no hint");
    assert!(parse_editor(&ok.replace("○ Low", "? Low")).is_none(), "unknown glyph");
    // An unknown effort word means the efforts are not offered at all.
    let odd = parse_editor(&ok.replace("○ High", "○ Turbo")).unwrap();
    assert!(odd.efforts().is_none());
    // Duplicate effort labels are ambiguous.
    let dup = parse_editor(&ok.replace("○ High", "○ Low")).unwrap();
    assert!(dup.efforts().is_none());
}

#[test]
fn footer_matches_the_longest_label_and_reads_a_single_effort() {
    let labels: Vec<String> = ["Claude Opus 5", "Claude Opus 5.5", "Grok 4.7", "Composer 2.5", "Auto", "Claude Opus 4.7"].map(String::from).to_vec();
    let f = |text: &str| parse_footer(text, &labels);
    assert_eq!(f("Claude Opus 5.5 300K Medium · 13.8%"), Some(Footer { label: "Claude Opus 5.5".into(), effort: Some("medium") }));
    assert_eq!(f("Claude Opus 5 300K Low · 9.2%"), Some(Footer { label: "Claude Opus 5".into(), effort: Some("low") }));
    assert_eq!(f("Grok 4.7 500K Low Fast · MAX · 10.6%").unwrap().effort, Some("low"));
    assert_eq!(f("Claude Opus 4.7 300K Extra High · 1%").unwrap().effort, Some("xhigh"));
    assert_eq!(f("Composer 2.5 Fast · 2%").unwrap().effort, None);
    assert_eq!(f("Auto").unwrap().label, "Auto");
    // The host's own statusline repeats the effort and appends other text.
    assert_eq!(f("Grok 4.7 High High  ░░░░░░░░░░ 6%  73% left  herdcats-cursor-probe").unwrap().effort, Some("high"));
    // Disagreeing efforts are not guessed.
    assert_eq!(f("Grok 4.7 Low High").unwrap().effort, None);
    // A neighbour's longer name, or an unknown model, never matches.
    assert!(f("Claude Opus 50 300K").is_none());
    assert!(f("Unknown Model High").is_none());
    assert!(f("").is_none());
}

#[test]
fn footer_text_is_the_first_row_under_the_composer_that_is_not_the_mode_line() {
    let screen = format!("{COMPOSER}  Plan (shift+tab to cycle)\n  Claude Opus 5.5 300K Medium · 8.4%\n  /private/tmp/herdcats-cursor-probe\n");
    assert_eq!(footer_text(&screen).as_deref(), Some("Claude Opus 5.5 300K Medium · 8.4%"));
    let tasks = format!("{COMPOSER}  1 task\n  Grok 4.5 High · 1%\n");
    assert_eq!(footer_text(&tasks).as_deref(), Some("Grok 4.5 High · 1%"));
    assert_eq!(footer_text("no composer"), None);
}

#[test]
fn ids_are_stable_slugs_and_efforts_map_both_ways() {
    assert_eq!(slug("Claude Opus 5.5"), "claude-opus-5-5");
    assert_eq!(slug("Claude Opus 5"), "claude-opus-5");
    assert_eq!(slug("GPT-5.6 Sol"), "gpt-5-6-sol");
    assert_eq!(slug("DeepSeek V4.1 Flash 1017"), "deepseek-v4-1-flash-1017");
    assert_eq!(slug("  --Weird!! "), "weird");
    for (id, label) in EFFORTS {
        assert_eq!(effort_id(label), Some(id));
        assert_eq!(effort_label(id), Some(label));
    }
    assert_eq!(effort_id("Turbo"), None);
}

#[test]
fn the_session_version_comes_from_the_running_process_not_the_symlink() {
    let ok = "/Users/u/.local/bin/cursor-agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/index.js --trust";
    let worker = "/Users/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/node /Users/u/.local/share/cursor-agent/versions/2026.10.22-27dcf5f/index.js worker-server";
    assert_eq!(session_version([ok, worker, "node mcp"]), Ok(TESTED_VERSION.to_owned()));
    // An older session after an auto-update keeps its own version.
    let old = ok.replace("2026.10.22-27dcf5f", "2026.10.19-6bbf2c4");
    assert_eq!(session_version([old.as_str()]), Ok("2026.10.19-6bbf2c4".to_owned()));
    assert_ne!(session_version([old.as_str()]), Ok(TESTED_VERSION.to_owned()));
    // Mixed versions, none, or malformed ones are unverified.
    assert_eq!(session_version([ok, old.as_str()]), Err("cursor_version_unverified"));
    assert_eq!(session_version(["zsh", "node server.js"]), Err("cursor_version_unverified"));
    assert_eq!(session_version([] as [&str; 0]), Err("cursor_version_unverified"));
    for bad in ["x/cursor-agent/versions/latest/index.js", "x/cursor-agent/versions/2026.10.22/index.js", "x/cursor-agent/versions/2026.10.22-zzzzzzz/index.js", "x/cursor-agent/versions//index.js", "x/cursor-agent/versions/12345.1.2-27dcf5f/index.js"] {
        assert_eq!(session_version([bad]), Err("cursor_version_unverified"), "{bad}");
    }
}
