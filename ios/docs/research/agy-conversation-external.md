# Antigravity conversation integration: external interfaces

Historical research snapshot. See [current implementation and validation](../agy-conversations.md) for the source support status and subsequent user smoke findings.

Researched 2026-10-25. Installed CLI: `agy 1.4.7`. Research only; no agent prompts, credentials, or configuration changes were made. Local inspection emitted schema and enum names, not conversation text.

## Best fit for existing terminal sessions

The official [hooks contract](https://antigravity.google/docs/hooks/) supplies `conversationId`, `workspacePaths`, `transcriptPath`, and `modelName`. For CLI sessions the documented transcript is `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`. Supported events include SessionStart, PreToolUse, PostToolUse, PreInvocation, PostInvocation, and Stop. Hooks load from workspace `.agents/hooks.json`, global `~/.gemini/config/hooks.json`, or plugins; CLI settings hooks are not loaded. This provides a documented route to session identity and transcript discovery.

Recommendation (inference): start with passive transcript ingestion and use hooks for identity/status where needed. This preserves the running TUI instead of launching a second process against its conversation.

## Local evidence from 1.4.7

Read-only Python inspection of three recently modified transcript files found these field families:

- Common: `type`, `status`, `step_index`, `source`, `created_at`.
- Text: `content`, optionally `thinking`.
- Tools: `tool_calls`, with entries containing `name` and `args`.
- Metadata: `input_tokens`, `output_tokens`, `cache_read_tokens`, `error`, `truncated_fields`.

The newest sampled transcript contained `USER_INPUT` from `USER_EXPLICIT`; `PLANNER_RESPONSE` and `GENERIC` from `MODEL`; and `SYSTEM_MESSAGE` / `CHECKPOINT`. Status values included `RUNNING`, `DONE`, `ERROR`. No repeated step indexes appeared in that one file, but index stability across compaction, rewind, and process restart is unverified. Sampled records had no conversation-ID field: preserve identity from the containing directory or hook metadata. These are observations, not a complete schema guarantee. The parser needs fixtures for content types, tool results, partial updates, truncation, and unknown enums before shipping.

There were 472 transcript files at the documented path. Directory inventory also showed 500 `conversations/*.db` files. Read-only SQLite schema inspection found:

- Per-conversation database: `trajectory_meta`, `steps`, `gen_metadata`, `executor_metadata`, `parent_references`, `trajectory_metadata_blob`, `battle_mode_infos`. Step payloads and metadata use BLOB columns.
- `conversation_summaries.db`: table `conversation_summaries`, primary key `conversation_id`, with `workspace_uris`, `app_data_dir`, `last_modified_time`, `status`, `source`, `step_count`, `last_user_input_step_index`, `parent_conversation_id`, and display metadata.

Recommendation (inference): prefer JSONL over decoding BLOB step payloads. Evaluate summaries as an optional discovery index, with graceful fallback because this SQLite schema is observed rather than publicly guaranteed. Database reads must be read-only and account for live WAL updates; immutable reads were used only for schema inspection and are unsuitable as a live polling strategy.

## Resuming and workspace identity

[Resume documentation](https://antigravity.google/docs/cli/commands/resume) documents `agy --conversation <id>` and the workspace-keyed `~/.gemini/antigravity-cli/cache/last_conversations.json`. `--continue` checks that cache and can start a fresh session if the remembered conversation disappears. Prefer an explicit conversation ID for reliable binding. The [conversation guide](https://antigravity.google/docs/cli/conversations/) scopes histories to the working directory. Validate how project roots and nested workspaces map to Herdcats panes.

## Optional managed-session interface

The official [headless interface](https://antigravity.google/docs/cli/headless/) supports paired `--input-format stream-json --output-format stream-json`, sending NDJSON user events and receiving `init`, `step_update`, and per-turn `result` events. Updates expose text deltas and tool information. Send the next prompt after the current result; close stdin to end gracefully. Resume with `--conversation`.

Important limitation: `control_request` and `control_response` are explicitly unsupported and terminate streaming sessions. Headless permission requests are soft-denied unless allowed by policy; exit zero does not establish that every requested tool executed. This interface therefore does not provide Claude-style interactive approval RPC. Authentication uses previously cached credentials. Input supports text blocks only. CLI-handled slash commands require separate invocations. Session usage counters are cumulative.

Local `agy --help` confirms streaming flags, conversation resume, `--mode`, and `--remote-control`. It reports print timeout default `0s` (wait until completion), unlike the headless documentation's five-minute default: capability checks must use the installed version.

## Remaining evidence needed

1. Capture a sanitized complete TUI transcript fixture: user text, assistant text/thinking, tool request/result/error, question, approval, interrupted turn, and subagent.
2. Confirm transcript append/rewrite behavior and freshness during active token streaming.
3. Prove pane process → conversation ID mapping through launch arguments, session hook metadata, or another reliable local identifier; a recent workspace cache alone is ambiguous with concurrent sessions.
4. Establish how terminal approvals/questions become structured mobile controls; headless RPC does not solve this.
5. Validate migration/version handling and unavailable-history fallback. No minimum version was established by this research.
