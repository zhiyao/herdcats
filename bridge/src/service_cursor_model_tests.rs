// A small stateful emulator of Cursor's `/model` TUI, driven by the fake Herdr
// server. It draws the same layouts the parsers were written against.
#[derive(Clone, Debug)]
struct TuiModel {
    label: &'static str,
    /// Effort ids offered by the editor; empty means no effort group.
    efforts: Vec<&'static str>,
    context: bool,
    fast: Option<bool>,
}
#[derive(Clone, Debug)]
enum TuiMode {
    Idle,
    Draft(String),
    Picker { filter: String, cursor: usize, top: usize },
    Editor { model: usize, cursor: usize },
}
#[derive(Clone, Debug)]
struct CursorTui {
    models: Vec<TuiModel>,
    /// Display order of the picker; the model last chosen moves to the front.
    order: Vec<usize>,
    current: usize,
    effort: Vec<Option<&'static str>>,
    mode: TuiMode,
    /// Mode line above the footer (`Plan`), if any.
    plan: bool,
    /// Keys that are silently ignored (fault injection).
    ignore: Vec<&'static str>,
    /// Enter inside the picker does nothing (fault injection).
    picker_enter_lost: bool,
    /// Frames of the picker drawn at the top of the list before it jumps to
    /// the current model; keys sent meanwhile are lost (as in the real TUI).
    transient_frames: u8,
    transient: std::cell::Cell<u8>,
    /// Draw the user's statusline instead of Cursor's own footer.
    statusline: bool,
    /// Composer redraws that still show the previous footer after a change.
    footer_lag: u8,
    lag: std::cell::Cell<u8>,
    old_footer: std::cell::RefCell<String>,
}
const TUI_TOP: &str = " ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄";
const TUI_BOTTOM: &str = " ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀";
fn effort_text(id: &str) -> &'static str {
    cm_effort_label(id)
}
fn cm_effort_label(id: &str) -> &'static str {
    crate::cursor_model::effort_label(id).unwrap_or("")
}
impl CursorTui {
    fn new() -> Self {
        let m = |label, efforts: &[&'static str], context, fast| TuiModel { label, efforts: efforts.to_vec(), context, fast };
        let models = vec![
            m("Auto", &[], false, None),
            m("Grok 4.7", &["low", "medium", "high", "xhigh"], true, Some(true)),
            m("Composer 2.5", &[], false, Some(true)),
            m("Claude Opus 5.5", &["low", "medium", "high", "xhigh", "max"], true, Some(false)),
            m("Claude Opus 5", &["low", "medium", "high"], true, Some(false)),
            m("GPT-5.6 Sol", &["none", "low", "medium", "high"], true, Some(false)),
            m("Gemini 3 Flash", &[], false, None),
            m("DeepSeek V4.1 Flash 1017", &["low", "high"], false, None),
        ];
        let effort = models.iter().map(|m| m.efforts.iter().copied().find(|e| *e == "medium").or(m.efforts.first().copied())).collect();
        let order = (0..models.len()).collect();
        Self { models, order, current: 3, effort, mode: TuiMode::Idle, plan: false, ignore: vec![], picker_enter_lost: false, transient_frames: 0, transient: std::cell::Cell::new(0), statusline: false, footer_lag: 0, lag: std::cell::Cell::new(0), old_footer: std::cell::RefCell::new(String::new()) }
    }
    fn params(&self, model: usize) -> String {
        let m = &self.models[model];
        let mut parts = Vec::new();
        if m.context { parts.push("300K".to_owned()); }
        if let Some(e) = self.effort[model] { parts.push(effort_text(e).to_owned()); }
        if m.fast == Some(true) { parts.push("Fast".to_owned()); }
        parts.join(" ")
    }
    fn footer(&self) -> String {
        let p = self.params(self.current);
        let label = self.models[self.current].label;
        if self.statusline {
            // display_name already holds the parameters and param_summary repeats them.
            let shown = if p.is_empty() { label.to_owned() } else { format!("{label} {p}") };
            let summary = if p.is_empty() { String::new() } else { format!(" {p}") };
            return format!("{shown}{summary}  ░░░░░░░░░░ 5%  73% left\n  herdcats-cursor-probe");
        }
        format!("{}{}{} · 8.4%", label, if p.is_empty() { "" } else { " " }, p)
    }
    fn shown_footer(&self) -> String {
        // The statusline refreshes about once a second: keep the old text for a few redraws.
        if self.lag.get() > 0 {
            self.lag.set(self.lag.get() - 1);
            return self.old_footer.borrow().clone();
        }
        self.footer()
    }
    fn changed(&self, before: String) {
        if self.footer_lag > 0 {
            *self.old_footer.borrow_mut() = before;
            self.lag.set(self.footer_lag);
        }
    }
    fn filtered(&self, filter: &str) -> Vec<usize> {
        self.order.iter().copied().filter(|i| self.models[*i].label.to_lowercase().contains(&filter.to_lowercase())).collect()
    }
    fn composer(&self, draft: Option<&str>) -> (String, String) {
        let text = draft.map(|d| format!("  → {d}")).unwrap_or_else(|| "  → Add a follow-up".to_owned());
        let mode = if self.plan { "  Plan (shift+tab to cycle)\n" } else { "" };
        let footer = if matches!(self.mode, TuiMode::Idle | TuiMode::Draft(_)) { self.shown_footer() } else { self.footer() };
        let footer_rows = if self.statusline { footer } else { format!("{footer}\n  /private/tmp/herdcats-cursor-probe") };
        let plain = format!("\n  PONG\n\n{TUI_TOP}\n{text}\n{TUI_BOTTOM}\n{mode}  {footer_rows}");
        let styled = if draft.is_none() {
            let bg = "\u{1b}[48;2;47;50;57m";
            let row = format!(" \u{1b}[0m{bg} \u{1b}[0m\u{1b}[2m{bg}→ \u{1b}[0m\u{1b}[7m{bg}A\u{1b}[0m\u{1b}[2m{bg}dd a follow-up\u{1b}[0m{bg}   \u{1b}[0m");
            plain.replace("  → Add a follow-up", &row)
        } else { plain.clone() };
        (plain, styled)
    }
    fn picker(&self, filter: &str, cursor: usize, top: usize) -> String {
        let rows = self.filtered(filter);
        let (title, none) = if filter.is_empty() { (" Available models".to_owned(), false) } else { (format!(" Models matching \"{filter}\""), rows.is_empty()) };
        let mut out = vec![format!("{title}{}                    Max mode: OFF", if none { " (no matches)" } else { "" }), String::new(), format!(" Filter:{}", if filter.is_empty() { String::new() } else { format!(" {filter}") }), String::new()];
        let last = (top + 10).min(rows.len());
        for (n, model) in rows.iter().enumerate().take(last).skip(top) {
            let params = self.params(*model);
            let selected = n == cursor;
            let mut line = format!("{}{:<24}{}", if selected { " →  " } else { "    " }, self.models[*model].label, if params.is_empty() { String::new() } else { format!(" {params}") });
            if selected && !params.is_empty() { line.push_str(" (Tab to modify)"); }
            out.push(line.trim_end().to_owned());
        }
        if !rows.is_empty() {
            out.push(String::new());
            out.push(format!(" {}-{} of {}", top + 1, last, rows.len()));
        }
        out.push(String::new());
        out.push(" Type to filter • Enter to select • Tab to edit".to_owned());
        out.join("\n")
    }
    fn editor_items(&self, model: usize) -> Vec<(Option<&'static str>, String, bool, bool)> {
        // (group, text, is_radio, selected)
        let m = &self.models[model];
        let mut items = Vec::new();
        if m.context { items.push((Some("Context"), "300K".to_owned(), true, true)); items.push((Some("Context"), "1M".to_owned(), true, false)); }
        for e in &m.efforts { items.push((Some("Effort"), effort_text(e).to_owned(), true, self.effort[model] == Some(*e))); }
        if let Some(on) = m.fast { items.push((None, "Fast".to_owned(), false, on)); }
        items
    }
    fn editor(&self, model: usize, cursor: usize) -> String {
        let mut out = vec![format!(" {} — Edit Parameters                               Max mode: OFF", self.models[model].label), String::new()];
        let mut group = None;
        for (n, (g, text, radio, selected)) in self.editor_items(model).iter().enumerate() {
            if *g != group {
                if let Some(name) = g { if group.is_some() { out.push(String::new()); } out.push(format!("  {name}")); } else { out.push(String::new()); }
                group = *g;
            }
            let glyph = match (radio, selected) { (true, true) => "●", (true, false) => "○", (false, true) => "◉", (false, false) => "◯" };
            out.push(format!("{}{glyph} {text}{}", if n == cursor { "  → " } else { "    " }, if *radio && *selected { " ✓" } else { "" }));
        }
        out.push(String::new());
        out.push(" ↑/↓ to navigate • Enter to select • Esc to go back".to_owned());
        out.join("\n")
    }
    fn screens(&self) -> (String, String) {
        match &self.mode {
            TuiMode::Idle => self.composer(None),
            TuiMode::Draft(d) => self.composer(Some(d)),
            TuiMode::Picker { filter, cursor, top } => {
                let (plain, styled) = self.composer(None);
                let (cursor, top) = if self.transient.get() > 0 && filter.is_empty() {
                    self.transient.set(self.transient.get() - 1);
                    (&0, &0)
                } else { (cursor, top) };
                let body = self.picker(filter, *cursor, *top);
                // The picker is drawn under the composer, in place of the footer.
                let head = plain.split(TUI_BOTTOM).next().unwrap().to_owned();
                let head_s = styled.split(TUI_BOTTOM).next().unwrap().to_owned();
                (format!("{head}{TUI_BOTTOM}\n{body}"), format!("{head_s}{TUI_BOTTOM}\n{body}"))
            }
            TuiMode::Editor { model, cursor } => {
                let (plain, _) = self.composer(None);
                let head = plain.split(TUI_BOTTOM).next().unwrap().to_owned();
                let body = self.editor(*model, *cursor);
                (format!("{head}{TUI_BOTTOM}\n{body}"), format!("{head}{TUI_BOTTOM}\n{body}"))
            }
        }
    }
    fn plain(&self) -> String { self.screens().0 }
    fn styled(&self) -> String { self.screens().1 }
    fn open_position(&self) -> (usize, usize) {
        let cursor = self.order.iter().position(|m| *m == self.current).unwrap();
        (cursor, cursor.saturating_sub(9).min(cursor))
    }
    fn text(&mut self, text: &str) {
        match &mut self.mode {
            TuiMode::Idle => self.mode = TuiMode::Draft(text.to_owned()),
            TuiMode::Draft(d) => d.push_str(text),
            // The real picker ignores pasted text; only single-character keys filter.
            TuiMode::Picker { .. } => {}
            TuiMode::Editor { .. } => {}
        }
    }
    fn key(&mut self, key: &str) {
        if self.ignore.contains(&key) { return; }
        if self.transient.get() > 0 && matches!(self.mode, TuiMode::Picker { .. }) { return; }
        match (&self.mode.clone(), key) {
            (TuiMode::Draft(d), "enter") if d == "/model" => {
                let (cursor, top) = self.open_position();
                self.transient.set(self.transient_frames);
                self.mode = TuiMode::Picker { filter: String::new(), cursor, top };
            }
            (TuiMode::Draft(_), "enter") => self.mode = TuiMode::Idle,
            (TuiMode::Draft(_), "ctrl+u") => self.mode = TuiMode::Idle,
            (TuiMode::Picker { filter, cursor, .. }, "enter") if !self.picker_enter_lost => {
                if let Some(model) = self.filtered(filter).get(*cursor).copied() {
                    let before = self.footer();
                    self.current = model;
                    self.changed(before);
                    self.order.retain(|m| *m != model);
                    self.order.insert(0, model);
                    self.mode = TuiMode::Idle;
                }
            }
            (TuiMode::Picker { .. }, "esc") => self.mode = TuiMode::Idle,
            (TuiMode::Picker { filter, cursor, top }, "space") => {
                self.mode = TuiMode::Picker { filter: format!("{filter} "), cursor: 0, top: 0 };
                let _ = (cursor, top);
            }
            (TuiMode::Picker { filter, .. }, k) if k.len() == 1 && (k.as_bytes()[0].is_ascii_alphanumeric() || k == "." || k == "-") => {
                self.mode = TuiMode::Picker { filter: format!("{filter}{k}"), cursor: 0, top: 0 };
            }
            (TuiMode::Picker { filter, cursor, top }, "up" | "down") => {
                let len = self.filtered(filter).len();
                // Down from the last row wraps to the first, as the real list does.
                let next = if key == "down" { if *cursor + 1 >= len { 0 } else { *cursor + 1 } } else { cursor.saturating_sub(1) };
                let top = if next < *top { next } else if next >= top + 10 { next - 9 } else { *top };
                self.mode = TuiMode::Picker { filter: filter.clone(), cursor: next, top };
            }
            (TuiMode::Picker { filter, cursor, .. }, "tab") => {
                if let Some(model) = self.filtered(filter).get(*cursor).copied() {
                    let m = &self.models[model];
                    if !m.efforts.is_empty() || m.fast.is_some() || m.context {
                        self.mode = TuiMode::Editor { model, cursor: 0 };
                    }
                }
            }
            (TuiMode::Editor { model, .. }, "esc") => {
                let cursor = self.order.iter().position(|m| m == model).unwrap();
                self.mode = TuiMode::Picker { filter: String::new(), cursor, top: cursor.saturating_sub(9) };
            }
            (TuiMode::Editor { model, cursor }, "up" | "down") => {
                let len = self.editor_items(*model).len();
                let next = if key == "down" { (*cursor + 1).min(len - 1) } else { cursor.saturating_sub(1) };
                self.mode = TuiMode::Editor { model: *model, cursor: next };
            }
            (TuiMode::Editor { model, cursor }, "enter") => {
                let items = self.editor_items(*model);
                if let Some((Some("Effort"), text, true, _)) = items.get(*cursor) {
                    let before = self.footer();
                    self.effort[*model] = crate::cursor_model::effort_id(text);
                    self.changed(before);
                    if *model == self.current { /* footer follows */ }
                } else if let Some((None, _, false, on)) = items.get(*cursor) {
                    self.models[*model].fast = Some(!on);
                }
            }
            _ => {}
        }
    }
}

fn model_fixture() -> (Service, PathBuf, SharedHerdr, PathBuf) {
    let (mut service, root, herdr, file) = cursor_fixture();
    service.include_model_control = true;
    herdr.lock().unwrap().tui = Some(CursorTui::new());
    herdr.lock().unwrap().status = Some("idle".into());
    service.poll(&mut Vec::new()).unwrap();
    (service, root, herdr, file)
}
fn tui(herdr: &SharedHerdr) -> CursorTui { herdr.lock().unwrap().tui.clone().unwrap() }
fn input_count(herdr: &SharedHerdr) -> usize { herdr.lock().unwrap().inputs.len() }
fn set_params(service: &Service, model: Option<&str>, effort: Option<&str>, expect_model: &str, expect_effort: Option<&str>) -> Value {
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let mut params = json!({"expect":{"model":expect_model,"effort":expect_effort,"identity":identity,"generation":service.generation}});
    if let Some(m) = model { params["model"] = json!(m); }
    if let Some(e) = effort { params["effort"] = json!(e); }
    params
}

fn closed(herdr: &SharedHerdr) {
    let t = tui(herdr);
    assert!(matches!(t.mode, TuiMode::Idle), "the picker or editor was left open: {:?}", t.mode);
}
fn sent(herdr: &SharedHerdr) -> Vec<String> {
    herdr.lock().unwrap().inputs.iter().map(|i| match i["method"].as_str().unwrap() {
        "pane.send_keys" => i["params"]["keys"][0].as_str().unwrap().to_owned(),
        _ => format!("text:{}", i["params"]["text"].as_str().unwrap()),
    }).collect()
}

#[test]
fn cursor_status_scans_the_picker_reads_the_current_efforts_and_closes_it() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let status = service.cursor_model_status(&identity).unwrap();
    closed(&herdr);
    assert_eq!(status["agent"], "cursor");
    assert_eq!(status["model"]["id"], "claude-opus-5-5");
    assert_eq!(status["model"]["label"], "Claude Opus 5.5");
    assert_eq!(status["effort"], "medium");
    assert_eq!(status["catalog"]["source"], "picker");
    assert_eq!(status["catalog"]["cliVersion"], "2026.10.22-27dcf5f");
    let models = status["models"].as_array().unwrap();
    assert_eq!(models.len(), 8, "every picker row, once");
    let ids: Vec<_> = models.iter().map(|m| m["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&"claude-opus-5") && ids.contains(&"claude-opus-5-5") && ids.contains(&"deepseek-v4-1-flash-1017"));
    let current: Vec<_> = models.iter().filter(|m| m["current"] == true).collect();
    assert_eq!(current.len(), 1);
    assert_eq!(current[0]["id"], "claude-opus-5-5");
    assert_eq!(status["efforts"], json!([{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"},{"id":"xhigh","label":"Extra High"},{"id":"max","label":"Max"}]));
    // Only the model in use has its efforts read.
    let other = models.iter().find(|m| m["id"] == "grok-4-7").unwrap();
    assert_eq!(other["efforts"], json!([]));
    // Esc, never Enter, ends every visit: the scan changed nothing.
    assert_eq!(tui(&herdr).current, 3);
    cleanup(&service, root);
}

#[test]
fn cursor_status_is_cached_after_the_first_visit() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let before = input_count(&herdr);
    let again = service.cursor_model_status(&identity).unwrap();
    assert_eq!(input_count(&herdr), before, "no key or text for a cached catalog");
    assert_eq!(again["model"]["id"], "claude-opus-5-5");
    closed(&herdr);
    cleanup(&service, root);
}

#[test]
fn cursor_model_control_needs_the_verified_live_version_before_any_input() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let old = "/home/u/.local/bin/cursor-agent /home/u/.local/share/cursor-agent/versions/2026.10.19-6bbf2c4/index.js --trust";
    let newer = old.replace("2026.10.19-6bbf2c4", "2026.10.30-abcdef0");
    for (lines, code) in [
        (vec![old.to_owned()], "cursor_unsupported_version"),
        (vec![newer], "cursor_unsupported_version"),
        (vec!["zsh".to_owned()], "cursor_version_unverified"),
        (vec![], "cursor_version_unverified"),
        (vec![old.to_owned(), old.replace("2026.10.19-6bbf2c4", "2026.10.22-27dcf5f")], "cursor_version_unverified"),
    ] {
        herdr.lock().unwrap().process_lines = Some(lines);
        assert_eq!(service.cursor_model_status(&identity).unwrap_err(), code);
        let params = set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("medium"));
        assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), code);
    }
    assert_eq!(input_count(&herdr), 0);
    cleanup(&service, root);
}

#[test]
fn cursor_version_comes_from_the_session_even_when_the_installed_build_moved_on() {
    // The pane runs the verified build; nothing about `cursor-agent --version`
    // or the symlink is consulted.
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    assert_eq!(service.cursor_version(&identity), Ok("2026.10.22-27dcf5f".to_owned()));
    // A cached catalog is for one version only: after an update mid-session the
    // next call must refuse rather than reuse it.
    service.cursor_model_status(&identity).unwrap();
    herdr.lock().unwrap().process_lines = Some(vec!["x/cursor-agent/versions/2026.11.02-0123abc/index.js".into()]);
    let before = input_count(&herdr);
    assert_eq!(service.cursor_model_status(&identity).unwrap_err(), "cursor_unsupported_version");
    assert_eq!(input_count(&herdr), before);
    cleanup(&service, root);
}

#[test]
fn cursor_model_control_refuses_unless_the_composer_is_idle_empty_and_in_agent_mode() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    type Arrange = Box<dyn Fn(&mut CursorTui)>;
    let cases: Vec<(Arrange, &str, &str)> = vec![
        (Box::new(|t| t.plan = true), "idle", "mode_not_agent"),
        (Box::new(|t| t.mode = TuiMode::Draft("half typed".into())), "idle", "composer_not_empty"),
        (Box::new(|_| {}), "working", "agent_busy"),
        (Box::new(|t| t.mode = TuiMode::Picker { filter: String::new(), cursor: 0, top: 0 }), "idle", "picker_open"),
    ];
    for (arrange, status, code) in cases {
        {
            let mut state = herdr.lock().unwrap();
            let mut fresh = CursorTui::new();
            arrange(&mut fresh);
            state.tui = Some(fresh);
            state.status = Some(status.into());
        }
        assert_eq!(service.cursor_model_status(&identity).unwrap_err(), code);
        let params = set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("medium"));
        assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), code);
    }
    assert_eq!(input_count(&herdr), 0, "nothing is typed into a pane that is not ready");
    cleanup(&service, root);
}

#[test]
fn cursor_set_model_picks_the_exact_row_not_a_fuzzy_neighbour() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let params = set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("medium"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    // "Claude Opus 5" is also a prefix of "Claude Opus 5.5": the filter shows both.
    let t = tui(&herdr);
    assert_eq!(t.models[t.current].label, "Claude Opus 5");
    assert_eq!(result["confirmed"], true);
    assert_eq!(result["error"], Value::Null);
    assert_eq!(result["applied"]["model"]["id"], "claude-opus-5");
    assert_eq!(result["applied"]["model"]["label"], "Claude Opus 5");
    assert_eq!(result["applied"]["effort"], "medium");
    // The new model's efforts were read for the next status.
    assert_eq!(result["applied"]["model"]["efforts"], json!([{"id":"low","label":"Low"},{"id":"medium","label":"Medium"},{"id":"high","label":"High"}]));
    // A model-only change never types `/model <id>`.
    let keys = sent(&herdr);
    assert!(!keys.iter().any(|k| k.starts_with("text:/model ") ), "{keys:?}");
    assert_eq!(keys.iter().filter(|k| k.as_str() == "text:/model").count(), 4, "scan, current efforts, change, new efforts");
    cleanup(&service, root);
}

#[test]
fn cursor_set_effort_walks_the_editor_with_verified_steps() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let before = input_count(&herdr);
    let params = set_params(&service, None, Some("max"), "claude-opus-5-5", Some("medium"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    assert_eq!(result["confirmed"], true);
    assert_eq!(result["applied"]["effort"], "max");
    assert_eq!(result["applied"]["model"]["id"], "claude-opus-5-5");
    let t = tui(&herdr);
    assert_eq!(t.effort[3], Some("max"));
    assert_eq!(t.current, 3, "the model stayed the same");
    let keys: Vec<String> = sent(&herdr)[before..].to_vec();
    // /model, Enter, Tab, then moves to Max (Context 2 rows + 4 steps), Enter, Esc, Esc.
    assert_eq!(keys.first().map(String::as_str), Some("text:/model"));
    assert_eq!(keys.iter().filter(|k| k.as_str() == "tab").count(), 1);
    assert_eq!(keys.iter().filter(|k| k.as_str() == "enter").count(), 2, "open the picker, select the radio");
    assert!(keys.iter().all(|k| matches!(k.as_str(), "text:/model" | "enter" | "tab" | "down" | "up" | "esc")), "{keys:?}");
    cleanup(&service, root);
}

#[test]
fn cursor_set_model_and_effort_in_one_request() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let params = set_params(&service, Some("gpt-5-6-sol"), Some("high"), "claude-opus-5-5", Some("medium"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    assert_eq!(result["confirmed"], true);
    assert_eq!(result["applied"]["model"]["id"], "gpt-5-6-sol");
    assert_eq!(result["applied"]["effort"], "high");
    assert_eq!(result["applied"]["model"]["efforts"].as_array().unwrap().len(), 4, "None is offered by the Reasoning group");
    let t = tui(&herdr);
    assert_eq!((t.models[t.current].label, t.effort[t.current]), ("GPT-5.6 Sol", Some("high")));
    cleanup(&service, root);
}

#[test]
fn cursor_unchanged_requests_are_confirmed_without_touching_the_pane() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let before = input_count(&herdr);
    let same_model = set_params(&service, Some("claude-opus-5-5"), None, "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &same_model).unwrap()["confirmed"], true);
    let same_effort = set_params(&service, None, Some("medium"), "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &same_effort).unwrap()["confirmed"], true);
    assert_eq!(input_count(&herdr), before);
    cleanup(&service, root);
}

#[test]
fn cursor_invalid_and_stale_requests_never_open_the_picker() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let before = input_count(&herdr);
    let ok = |model: Option<&str>, effort: Option<&str>| set_params(&service, model, effort, "claude-opus-5-5", Some("medium"));
    let cases: Vec<(Value, &str)> = vec![
        (ok(Some("not-a-model"), None), "unknown_model"),
        (ok(Some("claude opus 5"), None), "invalid_request"),
        (ok(Some("Claude Opus 5"), None), "invalid_request"),
        (ok(Some("../../etc"), None), "invalid_request"),
        (ok(None, Some("turbo")), "invalid_effort"),
        (ok(None, Some("Extra High")), "invalid_effort"),
        (ok(None, None), "invalid_request"),
        (set_params(&service, Some("claude-opus-5"), None, "grok-4-7", Some("medium")), "stale"),
        (set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("high")), "stale"),
        (set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", None), "stale"),
    ];
    for (params, code) in cases {
        assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), code, "{params}");
    }
    let mut wrong_generation = ok(Some("claude-opus-5"), None);
    wrong_generation["expect"]["generation"] = json!(service.generation + 1);
    assert_eq!(service.cursor_model_set(&identity, &wrong_generation).unwrap_err(), "stale");
    let mut wrong_identity = ok(Some("claude-opus-5"), None);
    wrong_identity["expect"]["identity"]["native_session_id"] = json!("33333333-3333-3333-3333-333333333333");
    assert_eq!(service.cursor_model_set(&identity, &wrong_identity).unwrap_err(), "stale");
    assert!(service.cursor_model_set(&identity, &json!({"model":"claude-opus-5"})).is_err());
    assert_eq!(input_count(&herdr), before);
    cleanup(&service, root);
}

#[test]
fn cursor_effort_the_model_does_not_offer_leaves_the_picker_closed_and_unchanged() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    // Opus 5.5 has no `none` effort (GPT does).
    let params = set_params(&service, None, Some("none"), "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "invalid_effort");
    closed(&herdr);
    assert_eq!(tui(&herdr).effort[3], Some("medium"));
    cleanup(&service, root);
}

#[test]
fn cursor_a_dropped_tab_stops_the_effort_change_and_closes_the_picker() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    herdr.lock().unwrap().tui.as_mut().unwrap().ignore = vec!["tab"];
    let params = set_params(&service, None, Some("high"), "claude-opus-5-5", Some("medium"));
    let error = service.cursor_model_set(&identity, &params).unwrap_err();
    assert!(["invalid_effort", "picker_mismatch"].contains(&error), "{error}");
    closed(&herdr);
    assert_eq!(tui(&herdr).effort[3], Some("medium"));
    cleanup(&service, root);
}

#[test]
fn cursor_an_enter_that_selects_nothing_is_unconfirmed_and_never_left_open() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    herdr.lock().unwrap().tui.as_mut().unwrap().picker_enter_lost = true;
    let params = set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "confirm_timeout");
    // The picker that the lost Enter left on screen was closed with Esc.
    closed(&herdr);
    let t = tui(&herdr);
    assert_eq!(t.models[t.current].label, "Claude Opus 5.5", "nothing was selected");
    cleanup(&service, root);
}

#[test]
fn cursor_an_escape_that_does_nothing_reports_picker_stuck_instead_of_hiding_it() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    {
        let mut state = herdr.lock().unwrap();
        state.tui.as_mut().unwrap().ignore = vec!["esc"];
    }
    // Status for a cached model needs no UI; a model change does, and its
    // cleanup cannot succeed with Esc dead.
    let params = set_params(&service, None, Some("high"), "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "picker_stuck");
    cleanup(&service, root);
}

#[test]
fn cursor_picker_first_frame_at_the_top_is_not_acted_on() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    // Every picker opens with three frames at the top of the list, during which keys are lost.
    herdr.lock().unwrap().tui.as_mut().unwrap().transient_frames = 3;
    let status = service.cursor_model_status(&identity).unwrap();
    closed(&herdr);
    assert_eq!(status["models"].as_array().unwrap().len(), 8);
    assert_eq!(status["model"]["id"], "claude-opus-5-5");
    let params = set_params(&service, Some("claude-opus-5"), Some("high"), "claude-opus-5-5", Some("medium"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    assert_eq!(result["confirmed"], true);
    assert_eq!(result["applied"]["model"]["id"], "claude-opus-5");
    assert_eq!(result["applied"]["effort"], "high");
    cleanup(&service, root);
}

#[test]
fn cursor_model_control_works_with_the_users_statusline_footer() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    {
        let mut state = herdr.lock().unwrap();
        let t = state.tui.as_mut().unwrap();
        t.statusline = true;
        // The statusline refreshes late: for a few redraws after any change the old text stays.
        t.footer_lag = 6;
    }
    let status = service.cursor_model_status(&identity).unwrap();
    closed(&herdr);
    assert_eq!(status["model"]["id"], "claude-opus-5-5");
    assert_eq!(status["effort"], "medium");
    // Effort: the editor applies at once, the footer follows later; that is not a failure.
    let params = set_params(&service, None, Some("max"), "claude-opus-5-5", Some("medium"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    assert_eq!(result["confirmed"], true, "{result}");
    assert_eq!(result["applied"]["effort"], "max");
    // Model + effort together.
    let params = set_params(&service, Some("gpt-5-6-sol"), Some("high"), "claude-opus-5-5", Some("max"));
    let result = service.cursor_model_set(&identity, &params).unwrap();
    closed(&herdr);
    assert_eq!(result["confirmed"], true, "{result}");
    assert_eq!(result["applied"]["model"]["id"], "gpt-5-6-sol");
    assert_eq!(result["applied"]["effort"], "high");
    cleanup(&service, root);
}

#[test]
fn cursor_model_control_refuses_when_the_statusline_name_matches_no_picker_row() {
    let (service, root, herdr, _file) = model_fixture();
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let before = input_count(&herdr);
    {
        // The statusline prints a name the picker does not list.
        let mut state = herdr.lock().unwrap();
        let t = state.tui.as_mut().unwrap();
        t.statusline = true;
        t.models[3].label = "Hidden";
    }
    let params = set_params(&service, Some("claude-opus-5"), None, "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "footer_unrecognized");
    assert_eq!(input_count(&herdr), before, "no key was sent while the footer could not be matched");
    cleanup(&service, root);
}

fn saved_catalog_file(root: &Path) -> PathBuf { root.join("cache/herdcats/cursor-model-catalog.json") }
fn labels_of(herdr: &SharedHerdr) -> Vec<String> {
    tui(herdr).models.iter().map(|m| m.label.to_owned()).collect()
}
fn write_saved(file: &Path, version: &str, scanned_at: u64, labels: &[String]) {
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, json!({"version":version,"scannedAt":scanned_at,"labels":labels}).to_string()).unwrap();
}
fn now() -> u64 { std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() }
/// A new bridge process: this session's own copy is gone, the file stays.
fn restart(service: &Service) { *service.cursor_catalog.borrow_mut() = None; }

#[test]
fn cursor_catalog_is_not_saved_anywhere_unless_a_file_is_configured() {
    let (service, root, _herdr, _file) = model_fixture();
    assert!(service.cursor_catalog_file.is_none(), "tests and plain services never write a cache");
    cleanup(&service, root);
}

#[test]
fn cursor_scanned_catalog_is_saved_privately_and_reused_by_the_next_session_without_scanning() {
    let (mut service, root, herdr, _file) = model_fixture();
    let file = saved_catalog_file(&root);
    service.cursor_catalog_file = Some(file.clone());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let first = service.cursor_model_status(&identity).unwrap();
    let scan_inputs = input_count(&herdr);
    assert_eq!(first["catalog"]["fresh"], true);

    use std::os::unix::fs::PermissionsExt;
    assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(file.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
    let saved: Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(saved["version"], "2026.10.22-27dcf5f");
    assert_eq!(saved["labels"].as_array().unwrap().len(), 8);
    assert!(saved.get("efforts").is_none(), "only the picker rows are saved");
    assert!(fs::read_dir(file.parent().unwrap()).unwrap().all(|e| e.unwrap().path() == file), "no temp file is left behind");

    restart(&service);
    let before = input_count(&herdr);
    let second = service.cursor_model_status(&identity).unwrap();
    let used = input_count(&herdr) - before;
    assert!(used * 3 < scan_inputs, "the saved list replaced the scan: {used} inputs against {scan_inputs}");
    assert_eq!(second["catalog"]["fresh"], false);
    assert!(second["catalog"]["fetchedAt"].as_u64().is_some());
    assert_eq!(second["models"].as_array().unwrap().len(), 8);
    assert_eq!(second["model"]["id"], "claude-opus-5-5");
    assert_eq!(second["efforts"], first["efforts"], "the current model's efforts are still read live");
    closed(&herdr);
    cleanup(&service, root);
}

#[test]
fn cursor_saved_catalog_that_is_doubtful_is_ignored_and_scanned_again() {
    let (mut service, root, herdr, _file) = model_fixture();
    let file = saved_catalog_file(&root);
    service.cursor_catalog_file = Some(file.clone());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let labels = labels_of(&herdr);
    let good = || labels.clone();
    type Doubtful = (&'static str, Box<dyn Fn()>);
    let mut doubtful: Vec<Doubtful> = Vec::new();
    let f = file.clone();
    let l = good();
    doubtful.push(("another build", Box::new({ let (f, l) = (f.clone(), l.clone()); move || write_saved(&f, "2026.10.19-6bbf2c4", now(), &l) })));
    doubtful.push(("older than a day", Box::new({ let (f, l) = (f.clone(), l.clone()); move || write_saved(&f, "2026.10.22-27dcf5f", now() - 25 * 3600, &l) })));
    doubtful.push(("from the future", Box::new({ let (f, l) = (f.clone(), l.clone()); move || write_saved(&f, "2026.10.22-27dcf5f", now() + 3600, &l) })));
    doubtful.push(("no rows", Box::new({ let f = f.clone(); move || write_saved(&f, "2026.10.22-27dcf5f", now(), &[]) })));
    doubtful.push(("a repeated row", Box::new({ let (f, l) = (f.clone(), l.clone()); move || { let mut l = l.clone(); l.push(l[0].clone()); write_saved(&f, "2026.10.22-27dcf5f", now(), &l) } })));
    doubtful.push(("a control character", Box::new({ let (f, l) = (f.clone(), l.clone()); move || { let mut l = l.clone(); l[1] = "Grok\u{1b}[2J".into(); write_saved(&f, "2026.10.22-27dcf5f", now(), &l) } })));
    doubtful.push(("not JSON", Box::new({ let f = f.clone(); move || { fs::create_dir_all(f.parent().unwrap()).unwrap(); fs::write(&f, "{nope").unwrap() } })));
    doubtful.push(("a symlink", Box::new({ let (f, l) = (f.clone(), l.clone()); move || {
        let real = f.with_file_name("real.json");
        write_saved(&real, "2026.10.22-27dcf5f", now(), &l);
        let _ = fs::remove_file(&f);
        std::os::unix::fs::symlink(&real, &f).unwrap();
    } })));
    for (why, make) in &doubtful {
        let _ = fs::remove_file(&file);
        make();
        restart(&service);
        let status = service.cursor_model_status(&identity).unwrap();
        assert_eq!(status["catalog"]["fresh"], true, "ignored: {why}");
        assert_eq!(status["models"].as_array().unwrap().len(), 8, "{why}");
        closed(&herdr);
    }
    // A good file written the same way is used, so the cases above fail for their own reason.
    let _ = fs::remove_file(&file);
    write_saved(&file, "2026.10.22-27dcf5f", now() - 3600, &labels);
    restart(&service);
    assert_eq!(service.cursor_model_status(&identity).unwrap()["catalog"]["fresh"], false);
    cleanup(&service, root);
}

#[test]
fn cursor_saved_catalog_that_lacks_the_model_in_use_is_dropped_and_scanned() {
    let (mut service, root, herdr, _file) = model_fixture();
    let file = saved_catalog_file(&root);
    service.cursor_catalog_file = Some(file.clone());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    let stale: Vec<String> = labels_of(&herdr).into_iter().filter(|l| l != "Claude Opus 5.5").collect();
    write_saved(&file, "2026.10.22-27dcf5f", now(), &stale);
    let status = service.cursor_model_status(&identity).unwrap();
    assert_eq!(status["catalog"]["fresh"], true, "rescanned in the same call");
    assert_eq!(status["model"]["id"], "claude-opus-5-5");
    assert_eq!(status["models"].as_array().unwrap().len(), 8);
    let rewritten: Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(rewritten["labels"].as_array().unwrap().len(), 8, "the file now matches the live picker");
    closed(&herdr);
    cleanup(&service, root);
}

#[test]
fn cursor_change_that_the_live_picker_cannot_find_forgets_the_saved_catalog() {
    let (mut service, root, herdr, _file) = model_fixture();
    let file = saved_catalog_file(&root);
    service.cursor_catalog_file = Some(file.clone());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    // The saved list names a model the account no longer has.
    let mut labels = labels_of(&herdr);
    labels.push("Retired Model".into());
    write_saved(&file, "2026.10.22-27dcf5f", now(), &labels);
    let params = set_params(&service, Some("retired-model"), None, "claude-opus-5-5", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "unknown_model");
    closed(&herdr);
    assert!(!file.exists(), "the file that sent us to a missing row is deleted");
    assert!(service.cursor_catalog.borrow().is_none());
    // The next visit scans the live picker and saves what is really there.
    let status = service.cursor_model_status(&identity).unwrap();
    assert_eq!(status["catalog"]["fresh"], true);
    assert_eq!(status["models"].as_array().unwrap().len(), 8);
    assert_eq!(serde_json::from_str::<Value>(&fs::read_to_string(&file).unwrap()).unwrap()["labels"].as_array().unwrap().len(), 8);
    cleanup(&service, root);
}

#[test]
fn cursor_a_catalog_scanned_in_this_session_is_not_forgotten_by_an_unrelated_refusal() {
    let (mut service, root, herdr, _file) = model_fixture();
    let file = saved_catalog_file(&root);
    service.cursor_catalog_file = Some(file.clone());
    let identity = service.watch.as_ref().unwrap().identity.clone().unwrap();
    service.cursor_model_status(&identity).unwrap();
    let params = set_params(&service, Some("claude-opus-5"), None, "wrong-model", Some("medium"));
    assert_eq!(service.cursor_model_set(&identity, &params).unwrap_err(), "stale");
    assert!(file.exists() && service.cursor_catalog.borrow().is_some());
    closed(&herdr);
    cleanup(&service, root);
}
