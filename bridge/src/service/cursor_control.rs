//! Cursor model and effort control, driven through the live `/model` picker.
//!
//! Every input is guarded by the screen it must produce, nothing is retried,
//! and the picker is always closed again: on success, on a mismatch and on an
//! error. The picker's own rows are the catalog; `/model <id>` is never typed
//! because it is a fuzzy filter that can select a neighbour. A change made
//! here is persisted by Cursor itself to `cli-config.json`, so it also becomes
//! the user's default for future sessions.
use super::*;
use crate::{
    cursor_model as cm,
    cursor_screen::{self, Screen},
};

pub(super) type Efforts = Vec<(&'static str, &'static str)>;

#[derive(Clone, Debug)]
pub(super) struct CursorModelEntry {
    pub label: String,
    pub id: String,
    /// `None` until the parameter editor was read; `Some(empty)` for a model
    /// without an effort group.
    pub efforts: Option<Efforts>,
}

#[derive(Clone, Debug)]
pub(super) struct CursorCatalog {
    pub version: String,
    pub models: Vec<CursorModelEntry>,
}

/// Longest wait for one screen change after one input.
const STEP_WAIT: Duration = Duration::from_millis(1500);
const POLL: Duration = Duration::from_millis(40);

impl Service {
    /// The running session's version, read from its own process, must be the
    /// verified build. The symlink and `--version` can already name a newer
    /// build after an auto-update while an older session keeps running.
    pub(super) fn cursor_version(&self, identity: &Identity) -> Result<String> {
        let lines = self
            .client
            .process_command_lines(&identity.pane_id)
            .map_err(|_| "cursor_version_unverified")?;
        let version = cm::session_version(lines.iter().map(String::as_str))?;
        if version != cm::TESTED_VERSION {
            return Err("cursor_unsupported_version");
        }
        Ok(version)
    }

    fn cursor_plain(&self, identity: &Identity) -> Result<String> {
        self.client.read_visible(&identity.pane_id).map_err(|_| "screen_unavailable")
    }

    /// Poll the visible screen until `check` accepts it or `timeout` passes.
    fn cursor_wait<T>(&self, identity: &Identity, timeout: Duration, mut check: impl FnMut(&str) -> Option<T>) -> Result<Option<T>> {
        let deadline = Instant::now() + timeout;
        loop {
            let screen = self.cursor_plain(identity)?;
            if let Some(found) = check(&screen) {
                return Ok(Some(found));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(POLL);
        }
    }

    fn cursor_press(&self, identity: &Identity, key: &str) -> Result<()> {
        // No retry: a failed call may still have been delivered.
        self.client.send_keys(&identity.pane_id, &[key])
    }

    /// Return the pane to its idle composer: Esc out of the picker or editor
    /// (and clear a `/model` that was typed but not entered). `Err` only when
    /// the screen cannot be brought back or even verified.
    fn cursor_close(&self, identity: &Identity, typed: Option<&str>) -> Result<()> {
        for _ in 0..5 {
            let plain = self.client.read_visible(&identity.pane_id).map_err(|_| "picker_stuck")?;
            let styled = self.client.read_visible_ansi(&identity.pane_id).map_err(|_| "picker_stuck")?;
            match cursor_screen::classify(&plain, &styled) {
                Screen::Idle { .. } => return Ok(()),
                Screen::Overlay => self.cursor_press(identity, "esc").map_err(|_| "picker_stuck")?,
                Screen::Draft if typed.is_some_and(|t| plain.lines().any(|l| l.trim_end() == format!("  → {t}"))) => {
                    self.cursor_press(identity, "ctrl+u").map_err(|_| "picker_stuck")?
                }
                _ => return Err("picker_stuck"),
            }
            thread::sleep(Duration::from_millis(250));
        }
        Err("picker_stuck")
    }

    /// Type `/model`, check the composer holds exactly that, then Enter, and
    /// wait for a picker that has settled. Cursor draws the picker's first
    /// frame at the top of the list and then jumps to the model in use; a key
    /// sent into that first frame is lost. So the picker counts as open only
    /// when its cursor row agrees with the live footer and the same screen was
    /// read for 250 ms running.
    fn cursor_open_picker(&self, identity: &Identity) -> Result<cm::Picker> {
        let footer = cm::footer_text(&self.cursor_plain(identity)?).ok_or("footer_unrecognized")?;
        self.client.send_text(&identity.pane_id, "/model")?;
        let typed = self.cursor_wait(identity, STEP_WAIT, |s| s.lines().any(|l| l.trim_end() == "  → /model").then_some(()))?;
        if typed.is_none() {
            return Err("picker_unavailable");
        }
        // The footer sits under the composer; with `/model` typed it may move,
        // so the one read before typing is the reference.
        self.cursor_press(identity, "enter")?;
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut candidate: Option<(cm::Picker, Instant)> = None;
        loop {
            let seen = cm::parse_picker(&self.cursor_plain(identity)?).filter(|p| {
                p.filter.is_empty() && !p.rows.is_empty() && p.cursor_label().is_some_and(|label| footer.starts_with(label))
            });
            match (seen, candidate.take()) {
                (Some(now), Some((before, since))) if now == before => {
                    if since.elapsed() >= Duration::from_millis(250) {
                        return Ok(now);
                    }
                    candidate = Some((before, since));
                }
                (Some(now), _) => candidate = Some((now, Instant::now())),
                (None, _) => {}
            }
            if Instant::now() >= deadline {
                return Err("picker_unavailable");
            }
            thread::sleep(POLL);
        }
    }

    /// One key, then wait for the cursor row to change (never a blind repeat).
    fn cursor_step(&self, identity: &Identity, key: &str, before: &cm::Picker) -> Result<cm::Picker> {
        let was = (before.cursor_label().map(str::to_owned), before.cursor_index());
        // Act only on the screen that was verified: if it moved on since, stop.
        let now = cm::parse_picker(&self.cursor_plain(identity)?).ok_or("picker_mismatch")?;
        if (now.cursor_label().map(str::to_owned), now.cursor_index()) != was {
            return Err("picker_mismatch");
        }
        self.cursor_press(identity, key)?;
        let moved = self.cursor_wait(identity, STEP_WAIT, |s| {
            let p = cm::parse_picker(s)?;
            ((p.cursor_label().map(str::to_owned), p.cursor_index()) != was && p.cursor_label().is_some()).then_some(p)
        })?;
        moved.ok_or("picker_mismatch")
    }

    /// Type `text` into the picker's filter. Pasted text is ignored by the
    /// picker, so each character is its own key, and the filter must show
    /// exactly what was typed so far before the next one is sent.
    fn cursor_type_filter(&self, identity: &Identity, text: &str) -> Result<cm::Picker> {
        let mut typed = String::new();
        let mut last = None;
        for c in text.chars().map(|c| c.to_ascii_lowercase()) {
            let key = match c {
                ' ' => "space".to_owned(),
                c if c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-' => c.to_string(),
                _ => return Err("unknown_model"),
            };
            typed.push(c);
            self.cursor_press(identity, &key)?;
            let want = typed.trim_end().to_owned();
            last = Some(
                self.cursor_wait(identity, STEP_WAIT, |s| {
                    cm::parse_picker(s).filter(|p| p.filter.to_ascii_lowercase() == want)
                })?
                .ok_or("picker_mismatch")?,
            );
        }
        last.ok_or("picker_mismatch")
    }

    /// With the picker open on the current model, filter by the exact label and
    /// move to the row with that label.
    fn cursor_pick_row(&self, identity: &Identity, open: &cm::Picker, current: &str, label: &str) -> Result<cm::Picker> {
        // Cursor opens on the model in use; anything else means the screen is
        // not what the footer said.
        if open.cursor_label() != Some(current) {
            return Err("picker_mismatch");
        }
        let mut picker = self.cursor_type_filter(identity, label)?;
        if picker.rows.is_empty() {
            return Err("unknown_model");
        }
        // Start from the top of the filtered list, then walk down.
        for _ in 0..24 {
            match picker.cursor_index() {
                Some(0) | None => break,
                Some(_) => picker = self.cursor_step(identity, "up", &picker)?,
            }
        }
        for _ in 0..24 {
            if picker.cursor_label() == Some(label) {
                return Ok(picker);
            }
            let last = picker.window.is_none_or(|(_, last, total)| last == total) && picker.rows.last().is_some_and(|r| r.selected);
            if last {
                return Err("unknown_model");
            }
            picker = self.cursor_step(identity, "down", &picker)?;
        }
        Err("unknown_model")
    }

    fn cursor_footer(&self, identity: &Identity, labels: &[String]) -> Result<Option<cm::Footer>> {
        let plain = self.cursor_plain(identity)?;
        Ok(cm::footer_text(&plain).and_then(|text| cm::parse_footer(&text, labels)))
    }

    /// Wait for an idle composer whose footer names `label`.
    fn cursor_wait_footer(&self, identity: &Identity, labels: &[String], label: &str) -> Result<Option<cm::Footer>> {
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let plain = self.cursor_plain(identity)?;
            let styled = self.client.read_visible_ansi(&identity.pane_id).map_err(|_| "screen_unavailable")?;
            if matches!(cursor_screen::classify(&plain, &styled), Screen::Idle { .. })
                && let Some(footer) = cm::footer_text(&plain).and_then(|t| cm::parse_footer(&t, labels))
                && footer.label == label
            {
                return Ok(Some(footer));
            }
            if Instant::now() >= deadline {
                return Ok(None);
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    /// Read every picker row: walk down to the end and back up to the start.
    fn cursor_scan(&self, identity: &Identity) -> Result<Vec<String>> {
        let mut picker = self.cursor_open_picker(identity)?;
        let (_, _, total) = picker.window.ok_or("catalog_incomplete")?;
        if total == 0 || total > cm::MAX_MODELS {
            return Err("catalog_incomplete");
        }
        let mut labels: Vec<Option<String>> = vec![None; total];
        let mut record = |p: &cm::Picker| -> Result<()> {
            let (first, _, _) = p.window.ok_or("catalog_incomplete")?;
            for (offset, row) in p.rows.iter().enumerate() {
                let slot = labels.get_mut(first - 1 + offset).ok_or("catalog_incomplete")?;
                match slot {
                    Some(seen) if *seen != row.label => return Err("catalog_incomplete"),
                    _ => *slot = Some(row.label.clone()),
                }
            }
            Ok(())
        };
        record(&picker)?;
        for _ in 0..total {
            if picker.cursor_index() == Some(total - 1) {
                break;
            }
            picker = self.cursor_step(identity, "down", &picker)?;
            record(&picker)?;
        }
        for _ in 0..total {
            if picker.cursor_index() == Some(0) {
                break;
            }
            picker = self.cursor_step(identity, "up", &picker)?;
            record(&picker)?;
        }
        labels.into_iter().collect::<Option<Vec<_>>>().ok_or("catalog_incomplete")
    }

    /// Catalog for this exact live version, scanned once and then cached.
    fn cursor_catalog_for(&self, identity: &Identity, version: &str) -> Result<CursorCatalog> {
        if let Some(cached) = self.cursor_catalog.borrow().as_ref().filter(|c| c.version == version) {
            return Ok(cached.clone());
        }
        let labels = self.cursor_run(identity, None, |s| s.cursor_scan(identity))?;
        let models: Vec<CursorModelEntry> = labels
            .into_iter()
            .map(|label| CursorModelEntry { id: cm::slug(&label), label, efforts: None })
            .collect();
        let mut ids = std::collections::HashSet::new();
        if models.iter().any(|m| m.id.is_empty() || m.id.len() > 64 || !ids.insert(m.id.clone())) {
            return Err("catalog_ambiguous");
        }
        let catalog = CursorCatalog { version: version.to_owned(), models };
        *self.cursor_catalog.borrow_mut() = Some(catalog.clone());
        Ok(catalog)
    }

    /// Run a picker operation and always return to the idle composer.
    fn cursor_run<T>(&self, identity: &Identity, typed: Option<&str>, operation: impl FnOnce(&Self) -> Result<T>) -> Result<T> {
        let outcome = operation(self);
        let closed = self.cursor_close(identity, typed.or(Some("/model")));
        match (outcome, closed) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(code), Ok(())) => Err(code),
            (_, Err(code)) => Err(code),
        }
    }

    /// Open the editor of the model currently in use and read its efforts.
    /// `Ok(None)`: the model has no parameters (Cursor ignores Tab).
    fn cursor_read_editor(&self, identity: &Identity, current: &str) -> Result<Option<cm::Editor>> {
        let open = self.cursor_open_picker(identity)?;
        if open.cursor_label() != Some(current) {
            return Err("picker_mismatch");
        }
        self.cursor_press(identity, "tab")?;
        let seen = self.cursor_wait(identity, Duration::from_millis(1200), cm::parse_editor)?;
        match seen {
            Some(editor) if editor.label == current => Ok(Some(editor)),
            Some(_) => Err("picker_mismatch"),
            // Still on the picker after the wait: this model has no parameters.
            None => match cm::parse_picker(&self.cursor_plain(identity)?) {
                Some(p) if p.cursor_label() == Some(current) => Ok(None),
                _ => Err("picker_mismatch"),
            },
        }
    }

    fn cursor_efforts_of(&self, identity: &Identity, current: &str) -> Result<(Efforts, Option<&'static str>)> {
        let editor = self.cursor_run(identity, None, |s| s.cursor_read_editor(identity, current))?;
        Ok(match editor {
            Some(editor) => (editor.efforts().unwrap_or_default(), editor.current_effort()),
            None => (Vec::new(), None),
        })
    }

    fn cursor_remember_efforts(&self, version: &str, label: &str, efforts: &Efforts) {
        if let Some(catalog) = self.cursor_catalog.borrow_mut().as_mut().filter(|c| c.version == version)
            && let Some(entry) = catalog.models.iter_mut().find(|m| m.label == label)
        {
            entry.efforts = Some(efforts.clone());
        }
    }

    fn cursor_model_json(entry: &CursorModelEntry, current: bool) -> Value {
        let efforts: Vec<Value> = entry
            .efforts
            .iter()
            .flatten()
            .map(|(id, label)| json!({"id":id,"label":label}))
            .collect();
        let mut value = json!({"id":entry.id,"label":entry.label,"efforts":efforts});
        if current {
            value["current"] = json!(true);
        }
        value
    }

    /// `model.status` for Cursor: version gate, idle Agent-mode composer, then
    /// the catalog (picker scan, cached) and the model in use (footer).
    pub(super) fn cursor_model_status(&self, identity: &Identity) -> Result<Value> {
        let version = self.cursor_version(identity)?;
        self.cursor_ready(identity, true)?;
        let catalog = self.cursor_catalog_for(identity, &version)?;
        let labels: Vec<String> = catalog.models.iter().map(|m| m.label.clone()).collect();
        let footer = self.cursor_footer(identity, &labels)?;
        let mut effort = footer.as_ref().and_then(|f| f.effort);
        if let Some(footer) = &footer {
            let known = catalog.models.iter().find(|m| m.label == footer.label).and_then(|m| m.efforts.clone());
            if known.is_none() {
                let (efforts, from_editor) = self.cursor_efforts_of(identity, &footer.label)?;
                self.cursor_remember_efforts(&version, &footer.label, &efforts);
                effort = effort.or(from_editor);
            }
        }
        let catalog = self.cursor_catalog_for(identity, &version)?;
        let current = footer.as_ref().and_then(|f| catalog.models.iter().find(|m| m.label == f.label));
        let models: Vec<Value> = catalog
            .models
            .iter()
            .map(|m| Self::cursor_model_json(m, current.is_some_and(|c| c.id == m.id)))
            .collect();
        let current_json = current.map(|m| Self::cursor_model_json(m, false));
        Ok(json!({
            "identity":identity, "generation":self.generation, "agent":"cursor",
            "model":current_json.as_ref().map(|m| json!({"id":m["id"],"label":m["label"],"efforts":m["efforts"]})),
            "effort":effort,
            "models":models,
            "efforts":current_json.as_ref().map(|m| m["efforts"].clone()).unwrap_or_else(|| json!([])),
            "catalog":{"source":"picker","fresh":true,"complete":true,"fetchedAt":Value::Null,"cliVersion":version,"error":Value::Null},
        }))
    }

    /// Choose the model whose picker row label is exactly `target`.
    fn cursor_select_model(&self, identity: &Identity, labels: &[String], current: &str, target: &str) -> Result<()> {
        let open = self.cursor_open_picker(identity)?;
        let picker = self.cursor_pick_row(identity, &open, current, target)?;
        if picker.cursor_label() != Some(target) {
            return Err("picker_mismatch");
        }
        self.cursor_press(identity, "enter")?;
        match self.cursor_wait_footer(identity, labels, target)? {
            Some(_) => Ok(()),
            None => Err("confirm_timeout"),
        }
    }

    /// In the editor of the model in use, move to the `Effort`/`Reasoning`
    /// radio for `target` and select it. Every move is verified on screen.
    fn cursor_select_effort(&self, identity: &Identity, labels: &[String], model: &str, target: &str) -> Result<Efforts> {
        let open = self.cursor_open_picker(identity)?;
        if open.cursor_label() != Some(model) {
            return Err("picker_mismatch");
        }
        self.cursor_press(identity, "tab")?;
        let mut editor = self
            .cursor_wait(identity, Duration::from_millis(1500), cm::parse_editor)?
            .ok_or("invalid_effort")?;
        if editor.label != model {
            return Err("picker_mismatch");
        }
        let offered = editor.efforts().unwrap_or_default();
        let item = editor
            .effort_items()
            .into_iter()
            .find(|(_, item)| cm::effort_id(&item.text) == Some(target))
            .map(|(index, _)| index)
            .ok_or("invalid_effort")?;
        for _ in 0..40 {
            if editor.cursor == item {
                break;
            }
            let (key, expected) = if editor.cursor < item { ("down", editor.cursor + 1) } else { ("up", editor.cursor - 1) };
            self.cursor_press(identity, key)?;
            editor = self
                .cursor_wait(identity, STEP_WAIT, |s| cm::parse_editor(s).filter(|e| e.cursor == expected && e.label == model))?
                .ok_or("picker_mismatch")?;
        }
        if editor.cursor != item {
            return Err("picker_mismatch");
        }
        self.cursor_press(identity, "enter")?;
        // The radio moves at once; the footer follows when the editor closes.
        self.cursor_wait(identity, STEP_WAIT, |s| {
            cm::parse_editor(s).filter(|e| e.label == model && e.current_effort() == Some(target))
        })?
        .ok_or("confirm_timeout")?;
        self.cursor_close(identity, None)?;
        let footer = self.cursor_footer(identity, labels)?;
        if footer.as_ref().is_some_and(|f| f.label == model && f.effort == Some(target)) {
            Ok(offered)
        } else {
            Err("confirm_timeout")
        }
    }

    /// `model.set` for Cursor: change the model, the effort, or both.
    pub(super) fn cursor_model_set(&self, identity: &Identity, params: &Value) -> Result<Value> {
        if params["expect"]["identity"] != serde_json::to_value(identity).map_err(|_| "stale")?
            || params["expect"]["generation"].as_u64() != Some(self.generation)
        {
            return Err("stale");
        }
        let valid_id = |v: &Value| v.as_str().map(|s| !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'));
        let target_model = match &params["model"] {
            Value::Null => None,
            v if valid_id(v) == Some(true) => v.as_str(),
            _ => return Err("invalid_request"),
        };
        let target_effort = match &params["effort"] {
            Value::Null => None,
            v if valid_id(v) == Some(true) && cm::effort_label(v.as_str().unwrap_or("")).is_some() => v.as_str(),
            _ => return Err("invalid_effort"),
        };
        if target_model.is_none() && target_effort.is_none() {
            return Err("invalid_request");
        }
        if !params["expect"].is_object() {
            return Err("invalid_request");
        }
        let version = self.cursor_version(identity)?;
        self.cursor_ready(identity, true)?;
        let catalog = self.cursor_catalog_for(identity, &version)?;
        let labels: Vec<String> = catalog.models.iter().map(|m| m.label.clone()).collect();
        let current = self.cursor_footer(identity, &labels)?.ok_or("footer_unrecognized")?;
        let current_id = cm::slug(&current.label);
        if params["expect"]["model"].as_str() != Some(current_id.as_str())
            || params["expect"]["effort"].as_str() != current.effort
        {
            return Err("stale");
        }
        let target = match target_model {
            Some(id) => catalog.models.iter().find(|m| m.id == id).ok_or("unknown_model")?,
            None => catalog.models.iter().find(|m| m.id == current_id).ok_or("unknown_model")?,
        };
        let changes_model = target.id != current_id;
        let applied = |footer: &cm::Footer, entries: &CursorCatalog, confirmed: bool, error: Option<&str>| {
            let entry = entries.models.iter().find(|m| m.label == footer.label);
            json!({"identity":identity,"generation":self.generation,"applied":{
                "model":entry.map(|m| Self::cursor_model_json(m, false)),
                "effort":footer.effort},"confirmed":confirmed,"error":error})
        };
        if !changes_model && target_effort.is_none_or(|e| current.effort == Some(e)) {
            return Ok(applied(&current, &catalog, true, None));
        }
        // Re-verify the occupant, then drive the picker.
        let mut state = current.clone();
        if changes_model {
            self.cursor_run(identity, None, |s| s.cursor_select_model(identity, &labels, &current.label, &target.label))?;
            state = self.cursor_footer(identity, &labels)?.ok_or("footer_unrecognized")?;
        }
        let mut error = None;
        if let Some(effort) = target_effort
            && state.effort != Some(effort)
        {
            match self.cursor_run(identity, None, |s| s.cursor_select_effort(identity, &labels, &state.label, effort)) {
                Ok(offered) => {
                    self.cursor_remember_efforts(&version, &state.label, &offered);
                    state = self.cursor_footer(identity, &labels)?.ok_or("footer_unrecognized")?;
                }
                // The model change already happened; report it with the failure.
                Err(code) if changes_model && code != "picker_stuck" => error = Some(code),
                Err(code) => return Err(code),
            }
        } else if changes_model {
            // Learn the new model's efforts for the next status; best effort.
            if let Ok((efforts, _)) = self.cursor_efforts_of(identity, &state.label) {
                self.cursor_remember_efforts(&version, &state.label, &efforts);
            }
        }
        let fresh = self.cursor_catalog_for(identity, &version)?;
        let confirmed = error.is_none()
            && state.label == target.label
            && target_effort.is_none_or(|e| state.effort == Some(e));
        Ok(applied(&state, &fresh, confirmed, error.or(if confirmed { None } else { Some("confirm_timeout") })))
    }
}
