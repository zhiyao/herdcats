# Agy approvals, questions, and model controls: verified feasibility

Historical research snapshot. See [current implementation and validation](../agy-conversations.md) for the source support status and subsequent user smoke findings.

Date: 2026-10-25. Installed CLI: 1.4.7 on macOS. Scope: research, not implementation.

## Decision

All three controls are technically feasible through Agy's existing interactive terminal. This is supported by live tests, not just inference from launch flags. Herdcats should extend its guarded terminal interaction adapters; a new headless session or Google's undocumented remote protocol is unnecessary for the tested interactions.

| Feature | Live evidence | Conclusion |
| --- | --- | --- |
| Approve once | A `printf` request paused on a four-option permission card; Enter on the first option ran it and its output was recorded. | Verified for a command approval. |
| Deny | A second `printf` request prompted again; three Down keys and Enter selected No. Agy reported user denial, recorded an ERROR result, and returned idle. | Verified; denial interrupted the turn. The earlier one-time approval did not grant all printf commands. |
| Single-select question | `ask_question` displayed Red/Blue and Write-in. Down and Enter selected Blue; the assistant and transcript confirmed Blue. | Verified. |
| Multiple questions, write-in | One tool call asked two questions. The first accepted Gamma through Write-in; Enter advanced to question 2/2. | Verified. |
| Multi-select question | Space toggled One, Down twice moved to Three, Space toggled Three, Enter submitted both answers. The assistant and transcript confirmed Gamma and One/Three. | Verified. |
| List models | `agy models` fetched model IDs and human labels successfully. | Verified on this account; availability is dynamic. |
| Change model live | `/model` opened a picker; Down and Enter changed Flash to Opus. Picker navigation changed back. The session header, acknowledgement, and footer changed. | Verified without restarting or resuming a second process. |
| Set model directly | `/model gemini-3.8-flash-low` changed the active model from Flash medium to low and acknowledged the change. | Verified simpler setter; no prompt text was appended. |
| Set effort directly | `/effort medium` acknowledged medium and updated the footer. | Verified. |

These are CLI PTY tests. No Herdcats adapter was implemented or exercised end to end. Rendering was observed at the probe PTY's default size; other terminal widths and user keybindings need coverage.

## Method and evidence

Ran a disposable session in `/private/tmp/herdcats-agy-interaction-probe` with explicit Flash/low startup flags and a dedicated log file. Accepted trust only for that temporary folder; declined an earlier launch in the broader `/private/tmp` folder. All agent prompts were synthetic and restricted to questions or a harmless `printf`. Approval testing selected one-time approval and denial, never conversation-wide or persistent permission grants. Exited using `/quit`; the process completed.

The sanitized [synthetic transcript fixture](fixtures/agy-1.4.7-synthetic-interactions.jsonl) contains 15 records from this probe only. User metadata wrappers were removed. This fixture records the user requests, tool arguments, returned answers, successful command output, and denied command error. It is not a raw terminal capture. Picker acknowledgements and screen controls below were transcribed from live PTY output during this research; no account banner is retained.

### Approval screen

```text
Command
Requesting permission for:
   printf HERDCATS_APPROVAL_PROBE_OK

Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with 'printf'
  3. Yes, and always allow for commands that start with 'printf' (Persist to settings.json)
  4. No, cancel

↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
```

The terminal wrapped the long choices across lines. A bridge must preserve their meanings: once, this conversation, persistent policy, and deny. They cannot be collapsed into a generic Yes. While approval was still pending, a conversation row already said `Ran (...)`; that label alone is not evidence of execution or approval state.

The tested input path used arrows and Enter. Numeric labels were displayed but numeric selection and the remote guide's y/n shortcuts were not tested. Agy permits configurable keybindings, so do not assume that a displayed number is a supported input key.

### Question screens

```text
Question 1/2: Which label?
  1. (Recommended) Alpha
  2. Beta
> 3. Write-in...
  Your answer:
  enter Submit · esc Back

Question 2/2: Which probe features?
> 1. [ ] (Recommended) One
  2. [ ] Two
  3. [ ] Three
  4. Write-in...
  ↑/↓ Navigate · ← Back · space Toggle · enter Submit All · esc Skip
```

The transcript exposed the pending `ask_question` arguments before the UI answer. In this version, `tool_calls[].args.questions` was a JSON-encoded string, not an already-decoded array. `run_command` arguments similarly used JSON-encoded string values for CommandLine. A robust parser needs typed decoding with bounds and errors, not string trimming.

The planner record containing `ask_question` was already DONE while the question was awaiting input. Thus DONE on a planner record does not establish that its tool has finished. Completed question results appeared later as GENERIC content (`A1: ...`, `A2: ...`). No durable tool-call ID appeared in these sampled tool-call objects. Step indexes were distinct within this probe; stability across rewrite, fork, and compaction is unproven.

### Model screen

```text
Switch Model
  Search:
  Gemini 4 Argon
> Gemini 3.8 Flash (current)
  Claude Opus 5.5
  Claude Sonnet 5.5
  GPT-OSS 120B (Medium)
  Keyboard: ↑/↓ Navigate  ←/→ Effort  enter Select  esc Go Back

Model set to Claude Opus 5.5 (Medium)
Effort set to medium
Model set to Gemini 3.8 Flash (Low)
```

Use `agy models` for the supported IDs; do not hardcode this account's current models. Validate direct setters against the running CLI version and confirm the acknowledgement/footer. The official reference describes interactive `/model` as persisting across sessions; the startup flags apply to the current session. Product copy should not promise a session-only preference without validating persistence. [CLI reference](https://antigravity.google/docs/cli/reference/)

## Why this fits Herdcats

The bridge already reads the current terminal screen, sends text/keys, matches requests, and verifies pane identity. Its approval and question parsers currently dispatch only Claude/Codex, so Agy needs new parsers and response planners rather than an iOS-only allowlist edit. The current approval `OptionKey` representation assumes digit/letter/Escape choices; the tested Agy workflow also needs guarded relative navigation and confirmation. [Approval parser](../../../bridge/src/approval_screen.rs), [Herdr client](../../../bridge/src/herdr.rs), [service](../../../bridge/src/service.rs), [question key planning](../../../bridge/src/question_keys.rs), [model controls](../../../bridge/src/model_control.rs).

Recommended flow:

1. Bind the exact native conversation to pane ID, terminal ID, connection ownership, and transcript generation.
2. Read structured question/tool details from the verified transcript or observer hook. Decode nested JSON strings and correlate the exact outstanding call.
3. Require a recognized current permission/question screen and match it to that call. A transcript record is not a pending-state oracle.
4. Before each navigation/confirmation step, reread current identity and screen. Abort if another device or the terminal user has answered, changed selection unexpectedly, amended a command, moved to a different question, or replaced the pane session.
5. Confirm the resulting screen or matching transcript result. Never blindly retry after an uncertain send.
6. Allow model/effort controls only at a verified idle, empty composer; submit an exact validated slash command and verify its result.

Normalize identity cautiously: the older roadmap uses `antigravity_cli`, but a local firstmate verification records Herdr returning `agent=agy` with `source=herdr:antigravity_cli`. Current iOS prompt checks assume `source == herdr:<agent>`, so merely adding `agy` or `antigravity_cli` to its allowlist can still fail. Confirm the installed Herdr shape and model an explicit supported source/agent mapping. Prior local compatibility evidence; [current prompt guards](../../Herdcats/Networking/HerdrConnection+PaneInput.swift).

## Official contracts and limits

Google's [Remote Control guide](https://antigravity.google/docs/remote-control/) explicitly supports approvals and clarifying questions from either the terminal or remote UI in the same live session. This independently corroborates feasibility, but the guide does not publish a third-party request/response API.

The [hooks contract](https://antigravity.google/docs/hooks/) exposes `ask_question` arguments and PreToolUse policy decisions. An observer hook could improve capture; it is not a documented asynchronous answer API. A blocking custom authorization hook would introduce different timeout and policy behavior and is unnecessary for the tested terminal path.

The [headless stream interface](https://antigravity.google/docs/cli/headless/) rejects approval control messages. That limitation applies to that interface; it does not prevent controlling the existing TUI. See the [official-source research](agy-interactions-official.md) for details and citations.

## Remaining implementation validation

Feasibility is established for the tested command permissions, ordinary questions, and idle model changes. Production readiness still requires file/URL/MCP permission cards, subagent approvals/questions, approval scope amendments, question skip/back behavior, custom keybindings, narrow terminals, long/wrapped options, concurrent desktop/mobile input, session replacement, reconnect during response delivery, and partial/rewritten transcripts. Busy-turn model switching was not tested; initially disable it.

No application code changed. The next engineering step is synthetic parser fixtures and guarded input plans for Agy, followed by a two-pane Herdcats integration test.
