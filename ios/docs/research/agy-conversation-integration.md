# Agy conversation mode in Herdcats

Historical research snapshot. See [current implementation and validation](../agy-conversations.md) for the source support status and subsequent user smoke findings.

Research date: 2026-10-25. Scope: add Antigravity CLI as the next agent in Herdcats' existing conversation/timeline view, observing the running terminal session. No implementation changes were made.

Follow-up: [live interaction research](agy-interactions-feasibility.md) now verifies command approval/denial, single/multiple/write-in/multi-select questions, and live model/effort changes on Agy 1.4.7. The initial uncertainties below should be read alongside that newer evidence.

## Finding

This is a bridge adapter and capability integration, with an initial schema-validation step. Herdr session identity is already a promising foundation; detecting Agy or supporting its sign-in does not supply conversation history.

The prior compatibility study records `antigravity_cli`, an observed native session ID, and `agy --conversation <id>` as its resume command. That observation is dated 2026-10-16 and needs a fresh live check before shipping. [Local roadmap](../../../compatibility/phase1/agent-roadmap.json)

Official hooks documentation identifies the CLI transcript as `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`. It also supplies `conversationId`, `workspacePaths`, and `transcriptPath` to hooks. This establishes a candidate passive source; it does not establish its record schema or equivalence to headless stream events. [Google hooks documentation](https://antigravity.google/docs/hooks/)

## Required changes

| Area | Existing behavior and needed work |
| --- | --- |
| Session resolution | Match the exact Herdr `agent_session` to Agy's conversation ID. Resolve the fixed transcript path beneath a pinned CLI brain root, using the bridge's existing descriptor-based path confinement. Never select by newest file or folder alone. |
| Parsing | Add an Agy adapter and parser for observed transcript records, mapping user/assistant messages and tool calls/results to existing entries. Establish stable IDs, tool linkage, ordering, session validation, and handling of unrecognized records. |
| Live history | Extend the follower's agent dispatch; preserve bounded reads, unfinished-line handling, rewrite/reset detection, generation changes, history pagination, and content references. Verify whether Agy appends, rewrites, or omits in-progress output. |
| Protocol | Advertise Agy support in bridge version metadata and initialize capabilities. iOS needs an Agy-specific capability check; its current non-Codex branch assumes Claude. |
| iOS | Add `antigravity_cli` to availability only after bridge support exists. Update helper release metadata, capability decoding, upgrade messages, and supported-agent tests. Existing timeline identity validation and compose guards depend on this allowlist. |
| Input | Reuse the existing Herdr `agent prompt` path after confirming Agy's composer/submit behavior and current pane/session identity. Validate interrupt separately. |
| Approvals/questions | Existing parsers and hook matching are agent-specific. Agy needs its own verified screen/input or structured interaction adapter. Until then, retain Terminal fallback for blocked interactions. |
| Model controls | Keep unavailable for Agy until model/effort discovery and application have their own tested adapter. A global bridge model-control flag alone is insufficient evidence of Agy support. |
| Distribution | Release a bridge that includes the adapter, then update the iOS pinned helper version, installer checksum, and supported-agent list. Current pinned release is 0.3.0 and lists only Claude/Codex. |

Source locations: [adapter contract](../../../bridge/src/adapter.rs), [resolver confinement](../../../bridge/src/resolver.rs), [follower](../../../bridge/src/follower.rs), [service registration and capabilities](../../../bridge/src/service.rs), [Herdr API client](../../../bridge/src/herdr.rs), [iOS models and availability](../../Herdcats/Models/AgentTimelineModels.swift), [handshake and installer](../../Herdcats/Networking/AgentBridgeClient.swift), [compose identity checks](../../Herdcats/Networking/HerdrConnection+PaneInput.swift), [view entry point](../../Herdcats/Features/SpaceDetailView.swift).

## Smallest useful delivery

1. Capture synthetic Agy sessions covering a user message, assistant response, tool success/failure, a second turn, resume, and interruption. Record the CLI version and schema; match the Herdr ID to the transcript directory and record-level identity where available.
2. Implement and test passive history plus updates, with existing pane input for new prompts. Show Terminal fallback for unsupported interactions.
3. Add approval/question handling after separately validating request identity, available choices, input delivery, and stale-request rejection. Add model controls independently.

Acceptance evidence should include two Agy panes in the same folder without mixed histories; pane/session replacement; reconnect; delayed transcript creation; partial writes; malformed/oversized records; rotation/rewrite; long history; tool linking; prompt delivery; and Terminal fallback while blocked. Synthetic fixtures should contain no private conversation content.

## Remaining uncertainty

The exact transcript schema, emission latency, record identity guarantees, compaction behavior, and compatibility across CLI versions need direct validation. The documented path makes this a focused investigation rather than a need to reverse engineer encrypted IDE history. A headless NDJSON interface is a separate execution model and should not be assumed to attach to or observe an existing interactive terminal session.

See [external API findings](agy-conversation-external.md) for official CLI and hook details, including headless interaction limits.
