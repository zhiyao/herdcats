# Cursor identity, approvals, questions, and model controls: verified feasibility

Historical research snapshot for the Cursor CLI conversation work. Scope: research, not implementation. See [current implementation and validation](../cursor-conversations.md); where the two differ, the implementation document is correct (see the corrections at the end of this file).

Date: 2026-10-27. Installed CLI: `cursor-agent` 2026.10.19-6bbf2c4 at the start of the session. The CLI auto-updated to 2026.10.22-27dcf5f partway through (the `~/.local/bin/cursor-agent` symlink was re-pointed while a probe was open). The first session (identity and an auto-run `printf` under the host's unrestricted config) ran on 10.19; every approval, question, model, hook, and transcript-rewrite finding ran on 10.22. A version gate must therefore tolerate the binary changing underneath a running Herdr session.

## Decision

Read-only timeline, prompt submission, shell approvals, structured questions, and model/effort changes are all reachable through the existing interactive terminal and the on-disk transcript. Four things differ from Agy and shape the design:

1. The transcript never shows a pending tool. A `tool_use` record is written only after the approval or question is resolved, and tool results are never written. Pending state must come from the screen.
2. Herdr identity is reliable only for a freshly launched session. After `/new` it goes stale, and after `--resume` it is absent.
3. A trailing `turn_ended` record is overwritten in place when the next turn starts.
4. The `/model` setter accepts only a bare model id with default parameters. Effort has to be changed through a picker sub-screen.

| Feature | Live evidence | Conclusion |
| --- | --- | --- |
| Identity | `agent_session {agent: cursor, kind: id, source: herdr:cursor, value: <chatId>}`. `value` equalled the transcript directory name and file stem in all runs. Two panes in the same cwd got different ids and transcripts. | Verified for fresh launches. Fails closed after `--resume` and goes stale after `/new`. |
| Transcript read | JSONL with user, assistant text, `tool_use`, and `turn_ended` records. | Feasible, with the rewrite behavior below. |
| Prompt submission | Typed text plus Enter works. Enter sent with no pause after the text submitted but left the text in the composer. | Feasible. Needs a pause and a post-submit empty-composer check. |
| Approve once | Shell card, `y` or Enter on the first row ran the command. | Verified. |
| Allowlist and Run Everything | Present on the card as Tab and Shift+Tab rows. Deliberately never selected. | Terminal-only, never driven. |
| Deny | `n` or Down×3 + Enter opens a "Tell the agent what to do instead" input. Empty Enter skips. The agent then retried the command and raised a second card. | Verified, but it is a two-stage flow and the turn continues. |
| Questions (single, multi, write-in, skip) | `AskQuestion` rendered a boxed form. Space, Enter, ←/→, typing on Other, and Esc were all verified. | Verified on Claude Opus 5.5. The tool was not found on Grok 4.5. |
| Observer hooks | `beforeShellExecution` and `preToolUse` fire before the approval card with the command and a `tool_use_id`. `AskQuestion` fires no tool hooks. | Optional enhancement for shell only. Needs user or project hook installation. |
| List models | `--list-models` returned 270 flat ids and labels. | Verified. Output is not a clean parseable schema. |
| Change model live | `/model <bare-id>` set the model and persisted it to `cli-config.json`. The picker also works. | Verified for bare ids. |
| Set effort live | Only through the picker Tab screen (Effort radio). Bracket syntax is rejected by `/model`. | Verified, picker-driven only. |

These are PTY tests through Herdr panes. No Herdcats adapter was implemented or exercised. Rendering was observed at one pane size (about 75 columns of content). Other widths, custom statusline configs, and non-shell approval cards are not covered.

## Method and evidence

Disposable sessions ran in `/private/tmp/herdcats-cursor-probe` (trust accepted with `--trust` for that folder only), driven with `herdr pane send-text`, `send-keys`, and `read --source visible`. All prompts were synthetic: `Reply with exactly ...`, a harmless `printf`, or an `AskQuestion` request. Approval testing chose only run-once and deny. `--force`, `--yolo`, "Run Everything", and the allowlist row were never selected.

The host's `~/.cursor/cli-config.json` has `approvalMode: "unrestricted"` and a statusline command, so a stock launch never shows an approval card and its footer differs from a clean install. To get cards without touching that file, later probes launched with `CURSOR_CONFIG_DIR=/private/tmp/herdcats-cursor-probe/cfg`, a copy with `approvalMode: "allowlist"`, an empty allow list, and no statusline. The user's `cli-config.json` model was verified unchanged at the end.

What `CURSOR_CONFIG_DIR` moves and what it does not:

| Path | Follows `CURSOR_CONFIG_DIR`? |
| --- | --- |
| `cli-config.json`, `chats/` | Yes |
| `projects/<slug>/agent-transcripts/` | No, always `~/.cursor/projects` |
| `hooks.json` (user level) | No, always `~/.cursor/hooks.json`. The Herdr hook still fired. |
| `<cwd>/.cursor/hooks.json` (project level) | Yes, honored from the working directory |

The sanitized [synthetic transcript fixture](fixtures/cursor-2026.10.22-synthetic-interactions.jsonl) has 11 records from one probe chat: a deny-then-approve shell turn, a two-question `AskQuestion` turn, a skipped `AskQuestion` turn, and the trailing marker. Timestamps were normalized. Screen text below was transcribed from live PTY output. No account banner or email is kept.

## 1. Identity

Herdr pane metadata for a Cursor pane:

```json
{"agent": "cursor", "agent_session": {"agent": "cursor", "kind": "id", "source": "herdr:cursor", "value": "<chatId>"}}
```

The `agent` value is `cursor`, the `kind` is `id`, and the source is `herdr:cursor`, so the iOS check `source == herdr:<agent>` holds without the special mapping Agy needed (`agy` with `herdr:antigravity_cli`). `agent_session.value` is the Cursor chat UUID and equals the transcript path component.

| Scenario | Result |
| --- | --- |
| Fresh `cursor-agent` launch | Session reported at startup in one run, and after the first prompt in the earliest run. Do not assume it exists before the first prompt. |
| Two panes, same cwd | Distinct ids (`05840e65-…`, `437b5e77-…`) and distinct transcript files. |
| `/new` inside the TUI | A new chat and a new transcript were created on the next prompt. Herdr's `agent_session.value` stayed on the old id for at least 10 seconds afterwards, including after the new chat's first turn completed. |
| `cursor-agent --resume <chatId>` | Appended to the existing transcript file. Herdr reported no `agent_session` at all, even after a completed turn. |
| Process exit | `agent` and `agent_session` cleared. |

Consequence: exact-identity matching can safely refuse a pane with no session, but it cannot detect that a still-bound id is stale after `/new`. A timeline for such a pane keeps showing the old chat while the user is typing into a new one. This is a Herdr hook limitation (the hook runs on `sessionStart` only), and it should be called out in user-facing docs rather than guessed around. Pane `agent_status` in these runs: `idle` at the empty composer, `blocked` while a shell approval card was pending, `done` after a turn, and `done` while an `AskQuestion` form was pending.

The `sessionStart` hook payload carries `session_id` and `conversation_id` (equal to the chat id), `model`, `cursor_version`, `workspace_roots`, and `transcript_path: null` at that moment. Later hook events (`beforeShellExecution`, `postToolUse`, `stop`) carry the real absolute `transcript_path`, which was always `~/.cursor/projects/<slug>/agent-transcripts/<chatId>/<chatId>.jsonl`.

### Transcript location and slug rule

Path: `~/.cursor/projects/<slug>/agent-transcripts/<chatId>/<chatId>.jsonl`. A Cursor chat also has `~/.cursor/chats/<md5(cwd)>/<chatId>/{meta.json, prompt_history.json, store.db}`. The `<md5(cwd)>` rule was verified for `/private/tmp/herdcats-cursor-probe`. `meta.json` is small and holds `cwd`, `title`, and timestamps, for example `{"schemaVersion":1,"createdAtMs":…,"hasConversation":true,"title":"…","updatedAtMs":…,"cwd":"/private/tmp/herdcats-cursor-probe"}`. Prefer the JSONL; `store.db` is SQLite and was not used.

Slug rule, verified on 10.22 with print-mode runs in real directories:

| cwd component | Slug |
| --- | --- |
| `dot.dir` | `dot-dir` |
| `under_score` | `under-score` |
| `sp ace` | `sp-ace` |
| `MixedCase` | `MixedCase` (case preserved) |
| `x.y_z w` | `x-y-z-w` |
| `a--b` | collapsed to `a-b` |

So the rule is: the absolute path with each run of non-alphanumeric characters turned into a single `-`, with the leading separator dropped. This holds for dots and underscores, which the brief asked to verify.

Long paths are the exception. A cwd whose full slug would be 132 characters produced `private-tmp-herdcats-cursor-probe-slugs-longlong-43be4f8`: the first 48 characters of the slug, then `-`, then a 7-hex suffix. Existing directories show the same pattern (prefixes of 48 and 49 characters, 56 to 57 characters total), but a 109-character untruncated slug also exists from February 2026, so truncation is version-dependent. I could not reproduce the 7-hex suffix from md5, sha1, sha256, sha512, or crc32 of the path, the slug, or common variants. Do not compute the slug; look the transcript up by chat id instead. The bridge should list the bounded set of `projects/*/agent-transcripts/<chatId>` directories, require exactly one match, and use the slug only as a cross-check when the cwd slug is short enough to be untruncated. Truncated project directories can also exist empty (no `agent-transcripts`).

## 2. Transcript record schema

All records are one JSON object per line.

```json
{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Tuesday, Oct 27, 2026, 9:00 AM (UTC+8)</timestamp>\n<user_query>\nPrompt text\n</user_query>"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"..."},{"type":"tool_use","name":"Shell","input":{"command":"printf X","description":"..."}}]}}
{"type":"turn_ended","status":"success"}
```

- **User:** a single text block wrapped as `<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>`. The wrapper must be stripped; the user text can legitimately end with a trailing newline or contain `/quit` and similar.
- **Assistant text and tools:** one record can hold several blocks, a text block followed by one or more `tool_use` blocks. Only `text` and `tool_use` block types appeared (26 user, 32 assistant, 13 `turn_ended` across all probe transcripts).
- **Tool calls:** `{"type":"tool_use","name":…,"input":{…}}` with no tool-call id. Observed names: `Shell` (`command`, `description`, and on retries `request_smart_mode_approval` and `smart_mode_block_reason`), `AskQuestion`, and `GetDynamicTools`.
- **Tool results:** none. No `tool_result` block was ever written. Shell output reaches the transcript only through the assistant's later text.
- **Thinking:** none. A `claude-opus-5-thinking-low` print-mode run with an explicit "think it through" prompt wrote only the user and assistant text blocks. Thinking blocks are not persisted.
- **Reasoning, images, and subagents:** not exercised.

### Where approvals, denials, and answers show up

| Event | Transcript effect |
| --- | --- |
| Card pending | Nothing. The file holds only the user record. |
| Run once | The `tool_use` record is appended after the decision, then the assistant's follow-up text. |
| Deny | The `tool_use` record is appended after the decision with no marker. The agent then re-emitted the same command with `request_smart_mode_approval: true` and `smart_mode_block_reason: "Rejected:"` and raised a new card. |
| Question pending | Nothing. The file holds only the user record. |
| Question answered | The `AskQuestion` `tool_use` appears (with title, question ids, prompts, options, `allow_multiple`) but the chosen answers are not in it. The answer is visible only in the TUI row and in the assistant's reply. |
| Question skipped | Same `tool_use` shape. The reply text says the user skipped. |

`AskQuestion` input shape:

```json
{"title":"README clarifications","questions":[
  {"id":"label","prompt":"Which label?","options":[{"id":"alpha","label":"Alpha"},{"id":"beta","label":"Beta"}]},
  {"id":"features","prompt":"Which features?","allow_multiple":true,"options":[{"id":"one","label":"One"},{"id":"two","label":"Two"},{"id":"three","label":"Three"}]}]}
```

Here `input` is already a decoded object, unlike Agy's JSON-encoded strings. The `title` field is optional in the fixture (one call omitted it).

### Delayed creation, rewrite, and rotation

- **Delayed creation:** the transcript directory does not exist after launch. In a timed run, the `agent_session` was already present at idle, and the transcript directory appeared about 2 seconds after the first prompt was submitted. The bridge must retry a missing file for a known chat id before declaring failure.
- **In-place rewrite of the tail:** the file keeps one inode. After a completed turn it ends in `{"type":"turn_ended","status":"success"}`. When the next prompt is submitted, that marker line is overwritten by the new user record. Observed with a 50 ms poller: `(inode N, 326 bytes, 3 records, last=turn_ended)` then `(inode N, 496 bytes, 3 records, last=user)`. Then `assistant` (4 records), `assistant` (5), and `turn_ended` (6) appended in order. A byte-offset follower that consumed the marker must rewind to the start of that line rather than treat the file as truncated, and it must not count `turn_ended` as a durable record. The record count therefore rises by one per new record but is not monotonic by byte length.
- **Multi-turn files:** a chat with 13 user prompts contained exactly one `turn_ended`, at the end.
- **`--resume`:** appended to the same file (3 to 5 records).
- **`/new`:** a different chat id and file. The old file is left as is.
- **Print mode (`-p`):** also writes a transcript under the same layout.
- **Composer residue:** unrelated to the file, but see section 6.

## 3. The approval screen

Shell command permission card (approval mode `allowlist`, empty allowlist):

```text
───────────────────────────────────────────────────────────────────────────
 $  printf HERDCATS_APPROVAL_PROBE_OK in .

 Run this command?
 Shell allowlist is empty
  → Run (once) (y)
    Add Shell(printf) to allowlist? (tab)
    Run Everything (shift+tab)
    Skip & tell the agent what to do instead (esc or n)
```

Four rows. The `→` marks the selected row, and it starts on the first row. The row above the options (`Shell allowlist is empty`) changes when the allowlist is non-empty; that variant was not captured.

| Row | Meaning | Hotkey | Tested |
| --- | --- | --- | --- |
| Run (once) | Run this command only. | `y` | Yes: `y` ran it, and the turn completed. |
| Add Shell(printf) to allowlist? | Persistently allowlist the command prefix in config. | `tab` | No, on purpose. |
| Run Everything | Switch to run-everything mode for the session or config. | `shift+tab` | No, on purpose. |
| Skip & tell the agent what to do instead | Deny. | `esc` or `n` | Yes, via Down×3 and Enter. |

Navigation: Up and Down move the selection and clamp at both ends (a second Down at the last row stayed on it). Enter activates the selected row. Key bursts need pacing: two Down presses sent back to back moved the selection only once, while the same presses 0.5 s apart both registered. Sending a `y` before the card finished rendering was dropped silently, and the card then stayed pending. A guarded navigator must reread the screen after each key.

Denial is two-stage. Selecting Skip changes the screen to:

```text
 ┌───────────────────────────────────────────────────────────────────────┐
 │ $  printf HERDCATS_APPROVAL_PROBE_OK in .                             │
 └───────────────────────────────────────────────────────────────────────┘
 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  → Tell the agent what to do instead (Enter to send,      ctrl+c to stop
    empty to skip, Esc to cancel)
 ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
```

An empty Enter finishes the denial (verified). The hint says Esc cancels back to the card (not tested). The conversation row then shows `$ printf … Rejected`. In the tested model, the agent treated the rejection as an auto-review block and retried, so a denial does not end the turn and a second card for the same command can follow immediately. A bridge must treat the new card as a distinct request.

Observer hooks (`beforeShellExecution`, `preToolUse`) fired while the card was pending (the card was still on screen when the log was read), with the exact command and a `tool_use_id`:

```json
{"tool_name":"Shell","tool_input":{"command":"printf HERDCATS_HOOK_PROBE2","cwd":"","timeout":30000},"tool_use_id":"<uuid>","session_id":"<chatId>","hook_event_name":"preToolUse"}
```

`postToolUse` then carried `tool_output` and `duration`, and `stop` carried token counts and `status`. This could give structured pending-shell capture the way the Claude and Codex permission hooks do, but it requires writing a hook into `~/.cursor/hooks.json` or `<project>/.cursor/hooks.json`, the payloads include `user_email`, and a hook that returns no decision did not change the card. `AskQuestion` fired none of the tool hooks (only `beforeSubmitPrompt` and `stop`). The screen remains the only oracle for questions. I recommend not depending on hooks for the first version.

Not captured: file edit, read, MCP, web fetch, and plan-mode cards. Treat anything that does not match the exact shell card as Terminal-only.

## 4. Questions

Cursor has a structured question tool, `AskQuestion`. The same host showed it inconsistently:

- On Claude Opus 5.5 (Agent mode) the model used it on request, in single, multiple, write-in, and skipped forms.
- On Grok 4.5 (Agent and Plan modes) the model searched for it with `GetDynamicTools`, found nothing, and replied `NOTOOL` three times. Opus later called the tool in the same chat and wrote that the earlier misses were wrong because "I only looked for it among the dynamic tools." The cause is not established, so availability depends on the model and cannot be assumed from the CLI version.
- The CLI bundle contains the `askQuestionInteractionQuery` handler and an `askQuestionToolCall`, so the UI is part of the product. ACP mode rejects questions.

The form is a boxed screen with one question at a time:

```text
 ┌───────────────────────────────────────────────────────────────────────┐
 │ README clarifications                                                 │
 │                                                                       │
 │ Question 1 of 2                                                       │
 │                                                                       │
 │ 1. Which label?                                                       │
 │                                                                       │
 │   › [ ] Alpha                                                         │
 │     [ ] Beta                                                          │
 │     [ ] Other: (type to answer)                                       │
 │                                                                       │
 │ ↑/↓ option · ←/→ question · Space select · Enter next/submit · Esc to │
 │ skip                                                                  │
 └───────────────────────────────────────────────────────────────────────┘
```

A multi-select question adds `(multi-select)` after the prompt. A single-select question also shows `[ ]` boxes. The `›` marks the cursor row. The title line is the tool's `title` (`README clarifications`) or a default (`Clarifying Questions`) when omitted.

| Action | Key | Observed |
| --- | --- | --- |
| Move cursor | Up, Down | Moves `›`. Paced presses were reliable. |
| Toggle or select | Space | Single select checks `[x]` on the cursor row. Multi-select toggles. |
| Next question or submit | Enter | Enter on question 1 of 2 advanced to question 2. Enter on the last question submitted. |
| Previous or next question | Left, Right | State was preserved in both directions. Right returned the cursor to the first row. |
| Write-in | Move to the Other row, then type | Typing auto-checked the row and rendered `Other: Green`. Enter then advanced. |
| Skip | Esc | Skipped the whole form, including answers already given. Row text: `AskQuestion Clarifying Questions (2) Questions skipped by user`. |

Answered rows echo the full result in the conversation after submit, for example `[x] Alpha` and `[x] One`, `[x] Three`. The transcript omits it (section 2), so a question card has to be matched from the pending screen. Pane `agent_status` stays `done` while the form is up, so Herdr state cannot be used to detect it. Question counts above 2, long options, and a form with an optional explanation line were not tested.

## 5. Model and effort

`cursor-agent --list-models` (and `cursor-agent models`) prints a flat text list:

```text
Available models

auto - Auto (default)
gpt-5.3-codex-low - Codex 5.3 Low
claude-opus-5-5-medium - Claude Opus 5.5 1M
grok-4.7-low-fast - Grok 4.7  Low Fast​​

Tip: use --model <id> (or /model <id> in interactive mode) to switch. Parameterized models also accept quoted overrides, e.g. --model 'claude-opus-4-8[context=1m,effort=high,fast=false]'.
```

Measured on this account: 274 lines, 270 unique `id - label` rows, the longest line 187 bytes, and 74 distinct families once the effort and `-fast` suffixes are stripped. Effort and fast are baked into the ids here, for example `gpt-5.3-codex-xhigh-fast`. Four labels (the Grok 4.7 ones) contain a double space and two trailing U+200B zero-width spaces, so labels must be normalized and length-bounded before display. The first line and the tip are non-model text. There is no JSON mode.

The list ids do not match the ids the TUI and config use. The config's current model was `grok-4.5` with parameters `effort` and `fast`, while the list names that model `cursor-grok-4.5-high`. A list-derived id cannot be compared to `cli-config.json` directly. The `--model` flag accepts bracket overrides, which the footer and config express as parameters.

The interactive `/model` command opens a picker of 46 model families (this account), not the 270 flat ids:

```text
 Available models                                            Max mode: OFF

 Filter:

    Muse Wonder              300K High
    Claude Fable 5.1         300K High
 →  Grok 4.5                 High (Tab to modify)
    Gemini 3.8 Flash         High

 9-18 of 46

 Type to filter • Enter to select • Tab to edit
```

Tab on a row opens the parameter editor, here for a model with context, effort, and fast:

```text
 Grok 4.7 — Edit Parameters                                  Max mode: OFF

  Context
  → ● 256K ✓
    ○ 500K

  Effort
    ○ Low
    ○ Medium
    ● High ✓
    ○ Extra High

    ◉ Fast

 ↑/↓ to navigate • Enter to select • Esc to go back
```

Findings:

- **Direct setter:** `/model <bare family id>` applied immediately with no picker and no acknowledgement line. `/model grok-4.7` and `/model claude-opus-5-5` both worked. The new model started from its default parameters (Grok 4.7 came up as `256K High Fast`; Opus 5.5 as `300K Medium`).
- **`/model` with anything else is a filter, not a setter.** `/model grok-4.7-low` and `/model grok-4.7[context=256k,reasoning_effort=low,fast=false]` both opened the picker with "Models matching … (no matches)". The bracket form that `--model` accepts does not work in the TUI. No keystrokes are sent to the model.
- **Effort:** only via the picker's Tab screen. Enter on a radio row selects it and stays on the screen, and the change is applied and written to config at once with no further confirmation. Two rapid Down presses registered once, so each press needs a pause.
- **Parameter ids differ per model:** `effort` and `fast` for Grok 4.5, but `context`, `reasoning_effort`, and `fast` for Grok 4.7. Effort values seen: Low, Medium, High, Extra High, Max. Not every model has every axis, and some are fast-only or context-only. Normalize in the bridge from the parameter editor, not from guessed ids.
- **Footer shape:** the footer is the line after the composer and depends on the user's statusline config. With the statusline removed it reads `<Model label> <context> <effort> <Fast> · MAX · <percent>%`, for example `Grok 4.7 500K Low Fast · MAX · 10.6%`, `Claude Opus 5.5 300K Medium · 13.8%`, or `Grok 4.5 High · 6.9%` on the earlier model. `MAX` appears only when Max mode (500K context here) is on. With the host's statusline command the same footer was `Grok 4.5 High High  ░░░░░░░░░░ 0%  73% left  herdcats-cursor-probe`, which repeats the effort. A parser has to tolerate both, and a statusline script can print arbitrary text, so require a model label that matches the expected label rather than parsing the footer generically.
- **Persistence:** every change was written to `cli-config.json` (`model`, `selectedModel.parameters`, `modelParameters.<id>`, `modelSelectionHistory`). Model and effort changes therefore persist across sessions and are not session-local. Product copy should say so.
- **Mode line:** the mode (Agent, Ask, Plan, Debug) is a separate line above the model footer, shown as `<Mode> (shift+tab to cycle)`. Agent mode shows no label. Shift+Tab cycles Debug, Ask, Agent, Plan. A mode change is easy to trigger by accident and changes what `/model` is allowed alongside it, so a control should require the mode line to be absent (Agent).

Not tested: model change during a running turn, models without any parameters, and whether a selected model is still valid after a plan or account change. Initially disable busy-turn changes, as Agy does.

## 6. Prompt submission and the empty composer

The empty idle composer, with the statusline removed:

```text
 ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
  → Add a follow-up
 ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
  Grok 4.5 High · 10.6%
  /private/tmp/herdcats-cursor-probe
```

On a brand-new chat the placeholder reads `→ Plan, search, build anything`. While a turn runs the placeholder row shows `Add a follow-up` and a right-aligned `ctrl+c to stop`. `herdr pane read --source visible` returned these screens; the default `recent` source returned only the shell line above the TUI.

- **Typing:** `send-text` followed by `Enter` submits. The composer wraps long text across rows, each prefixed by the `→` on the first and spaces after.
- **Enter race:** when `Enter` followed the text immediately (same shell command, no pause), the prompt was submitted and answered, but the full text stayed in the composer afterwards. This happened on 3 of 4 immediate-Enter submissions (the fourth cleared), and on none of the submissions that had a pause of 0.1 s to 1 s (about ten). A follow-up message sent into the stale buffer was concatenated onto it (`…its output)/quit`) and submitted as one prompt. Consequences for the bridge: pause between text and Enter, then reread the screen and verify the placeholder is back, and refuse to send when the composer is not at the empty placeholder.
- **Clearing:** `ctrl+u` deletes one wrapped line of composer text, so several presses clear a multi-line draft.
- **Slash menu:** a leading `/` opens an autocomplete list under the composer, and Enter on a highlighted entry runs it (`/quit` exits, `/model` opens the picker). A prompt that starts with `/` is therefore a command, not text, and `/model grok-4.7` ran as a command because it matched exactly. The same typed text must be sent as a command only when intended; a user prompt beginning with `/` needs separate handling.
- **Exit:** `Ctrl+C` once prints `Press Ctrl+C again to exit`; a second press has to arrive within that window.
- **Quick-start screens:** the first launch in a folder prompts for workspace trust, which `--trust` skipped. Other first-run prompts were not seen.

## Why this fits Herdcats

The reference flow in the Agy research applies, with the corrections above:

1. Bind the exact native conversation to pane id, terminal id, connection ownership, and transcript generation. Accept only `agent == cursor`, `source == herdr:cursor`, `kind == id`, and a UUID value.
2. Locate the transcript by chat id under a descriptor-pinned `~/.cursor/projects`, with delayed-creation retry, and check `meta.json`'s `cwd` against the pane cwd where it is readable.
3. Read the file as append-only JSONL plus a rewritable trailing `turn_ended`. Compute the generation from the offset of the last durable record, not from file length.
4. Treat the screen as the only pending-state oracle for approvals and questions. Never infer a pending tool from the transcript or from Herdr `blocked`.
5. Before each key, reread identity and screen. Pace keys by at least 0.5 s. Abort on a changed card, a different command, a second card, or a pane session change.
6. Allow model and effort changes only at a verified idle, empty, Agent-mode composer and verify both the footer and `cli-config.json` afterwards.

## Decision table

| Feature | Status | Notes |
| --- | --- | --- |
| Read-only timeline | Feasible | Lookup by chat id, tolerate the rewritten `turn_ended` tail and delayed creation. |
| Pane identity | Partial | Exact for fresh launches. Absent after `--resume`, stale after `/new`. Fail closed. |
| Prompt submission | Feasible | Pause before Enter, verify the empty composer afterwards. |
| Shell approval: run once | Feasible | Screen-guarded `y` or navigate and Enter. |
| Shell approval: deny | Partial | Two-stage flow, and the agent may immediately raise a new card. |
| Shell approval: allowlist, Run Everything | Terminal-only | Persistent scopes. Never driven. |
| Other approval cards (edit, MCP, fetch, plan) | Terminal-only | Not captured. |
| Structured questions | Partial | Feasible on models that expose `AskQuestion`. Screen-only pending state, answers not in the transcript. |
| Question skip | Feasible | Esc skips the whole form. |
| Model list | Partial | Parseable but unstructured, with zero-width characters. List ids differ from config ids. |
| Model change | Feasible | Bare-id `/model <id>` at an idle empty Agent-mode composer. Persists to config. |
| Effort change | Partial | Picker Tab screen only, per-model parameter ids, paced keys. |
| Structured hooks | Terminal-only | Not adopted. Optional later for shell. Needs hook installation. |

## Remaining implementation validation

Feasibility is established for the tested paths. Production readiness still needs: non-shell cards (file edit, MCP, fetch, plan approval), the non-empty-allowlist card text, narrow terminal widths and long wrapped commands, a user statusline that rewrites the footer, concurrent desktop and mobile input, session replacement after `/new` and `--resume`, long-path slug directories, `AskQuestion` forms with more than two questions or long options, busy-turn model changes, and a CLI auto-update arriving mid-session. The version gate should name 2026.10.22-27dcf5f (the version all screen findings were re-verified on) and treat other builds as read-only until tested.

No application code changed.

## Appendix: commands used

Reproducible with the probe directory and `CURSOR_CONFIG_DIR` described above:

```text
herdr pane split --current --direction right
herdr pane run <pane> "cd /private/tmp/herdcats-cursor-probe && CURSOR_CONFIG_DIR=…/cfg cursor-agent --trust"
herdr pane send-text <pane> "<prompt>"; herdr pane send-keys <pane> Enter
herdr pane read <pane> --source visible
herdr pane get <pane>            # agent, agent_status, agent_session
cursor-agent --list-models
```

## Corrections found while implementing

Later probing and the implementation changed several conclusions above. They are kept as written for the record.

- **`/model <id>` is not a reliable setter.** The decision table says a bare `/model <id>` is feasible. It is a fuzzy filter: `claude-opus-5` selected Claude Opus 5.5, `claude-fable-5` selected Fable 5.1, `claude-sonnet-5` selected Sonnet 5.5, and 17 of 57 family ids derived from `--list-models` are not in the picker at all. The implementation chooses a row in the picker by its exact label instead.
- **`--list-models` is not the catalog.** Its 270 flat ids do not map onto the 46 picker families or their parameter ids. The picker is the catalog.
- **The picker ignores pasted text.** Its filter takes single-character keys only. Down from the last row wraps to the first, and its first frame is drawn at the top of the list before it jumps to the current model; keys sent into that frame are lost.
- **Parameter groups.** The effort group is titled `Effort` (Claude, Grok) or `Reasoning` (GPT, Kimi). A model with no parameters ignores Tab.
- **Shell card notices.** With a non-empty allow list the card reads `Not in allowlist: a, b` instead of `Shell allowlist is empty`.
- **Questions.** The cursor starts on the first option of each question, Enter with nothing selected advances, and single choice is a radio. Typed write-in text survives when another option is chosen later.
- **Status lines.** A user's `statusLine` replaces the footer, and the footer lags changes by about a second.
- **Version.** The running session's version is in its process command line; the installed symlink can already name a newer build.
