# Agy approvals, questions, and model selection: official contracts

Historical research snapshot. See [current implementation and validation](../agy-conversations.md) for the source support status and subsequent user smoke findings.

Researched 2026-10-25. Scope: official documentation; no credentials, private conversation content, or configuration changes. These findings complement `agy-conversation-external.md`.

Follow-up: [live CLI testing](agy-interactions-feasibility.md) verifies terminal approval/denial, question variants, model selection, and effort changes on 1.4.7, addressing the tested-terminal-workflow gaps below.

## Feasibility

All three interactions exist in Agy's interactive product. Native Herdcats controls still need a tested bridge to the running CLI. A transcript reader alone cannot answer a pending request or change a model.

| Capability | Officially supported | Missing contract for Herdcats |
| --- | --- | --- |
| Tool approval | Terminal prompt; Google Remote Control can answer it | Public third-party pending-request IDs and response RPC |
| Clarifying question | `ask_question`; Google Remote Control can answer it | Public answer submission schema and stale-question protection |
| Model selection | Startup `--model`; interactive `/model` | Documented live programmatic setter or tested terminal command workflow |

## Existing-session Remote Control

The [Remote Control guide](https://antigravity.google/docs/remote-control/) explicitly supports turning it on in an active CLI with `/remote-control`, or at launch with `--remote-control`. Each terminal process receives its own session instance. A reverse tunnel exists only for that process's lifetime. The generated `antigravity.google.com/r/<instance-id>?p=c%2F<conversation-id>` URL opens in a browser signed into the same Google Account.

The guide promises synchronized prompts, thoughts, tools, and diffs, plus responses to tool confirmations and clarifying questions from either terminal or remote UI. This proves bidirectional existing-session interaction is possible in Google's implementation. It does not document a third-party API, wire schema, local endpoint, or supported authentication mechanism for Herdcats. Remote web settings panels cannot change CLI settings.

Inference: offering the official Remote Control URL is an immediately supported alternative UX; implementing a native replacement requires additional protocol evidence, not merely reusing the URL as an API.

## Tool approvals and hooks

[Permissions](https://antigravity.google/docs/permissions/?tab=cli) represent operations as `action(target)`. Explicit precedence is Deny > Ask > Allow. Ask pauses for user approval. Interactive cards permit scope editing for file, URL, and MCP requests, but not terminal commands. A native approval card must preserve operation scope and distinguish a one-time answer from a durable policy grant.

The [PreToolUse hook contract](https://antigravity.google/docs/hooks/#pretooluse) receives `toolCall.name`, `toolCall.args`, `stepIdx`, and session metadata. Its response is a policy decision:

- `allow` continues to another hook/default policy; it is not unconditional user approval.
- `auto_approve` avoids a default prompt while honoring explicit rules.
- `deny` blocks immediately.
- `ask` prompts subject to Always Allow; `force_ask` ignores cached grants.
- `deny_unless_prior_grant` requires prior permission.

The contract offers no durable pending-request ID or asynchronous “answer this existing prompt” RPC. A blocking custom hook could theoretically await a Herdcats decision, but that is a new custom authorization mechanism, with documented hook timeout default 30 seconds, rather than answering Agy's existing approval UI. Treat this as an experimental design requiring explicit timeout, cancellation, disconnect, and policy semantics.

## Clarifying questions

The [hooks tool catalog](https://antigravity.google/docs/hooks/#interaction-and-media) documents `ask_question` with `questions`, each containing `question`, `options`, and `is_multi_select`. Hook inspection can potentially expose those tool arguments. No answer injection or question-response transport is documented there. Detecting a PreToolUse event is insufficient to prove the UI is ready to receive an answer. The Remote Control guide above confirms that Google's live transport does carry answers.

## Live model and effort selection

The [CLI reference](https://antigravity.google/docs/cli/reference/) documents interactive `/model` and `/effort [level]`. `--model` and `--effort` are startup overrides; model lists should come from `agy models`, not hardcoded names. The [enterprise guide](https://antigravity.google/docs/enterprise/) explicitly distinguishes startup selection from mid-session `/model` switching. The [model guide](https://antigravity.google/docs/models/) says an in-flight turn retains its selected model until its steps finish or execution is canceled.

The [CLI changelog](https://antigravity.google/docs/changelog?tab=cli) additionally documents one-shot `/model <model> <prompt>` behavior and a fix that defers a queued one-shot model switch until its prompt executes. Do not confuse this with permanently changing the session model. Inspect and validate the installed CLI's exact command syntax before wiring a dropdown.

The [headless guide](https://antigravity.google/docs/cli/headless/) rejects `control_request`/`control_response` and CLI-handled `/model` in stream input. Its streaming interface is therefore not a documented live model/approval/question control channel.

## Implementation gate

Before enabling native controls, establish a request identity tied to pane generation and conversation ID, observe current pending state, serialize responses, confirm acceptance, and reject stale taps. Validate each path against the installed Agy version. Until that evidence exists, show conversation history and use tested terminal interaction or the official remote UI for controls.
