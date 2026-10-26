# Pi live conversation extension

This opt-in extension runs inside the existing Pi TUI. It does not launch Pi, attach RPC to a TUI, resume a session, change permission policies, or install a bridge binary. The implementation is gated to **@earendil-works/pi-coding-agent 1.4.0**, verified against that installed package's public extension APIs and a disposable TUI probe.

Start a new Pi session with this source extension explicitly enabled:

```sh
pi -e /absolute/path/to/herdcats/bridge/pi-extension/index.ts
```

Keep `index.ts` and `runtime.mjs` together. For automatic discovery, copy this directory to your personal Pi extensions directory as a directory containing `index.ts`, then start Pi normally. Follow Pi's extension lifecycle guidance when reloading: `/reload` replaces the runtime; it is not RPC attachment. Existing sessions started without the extension remain usable in Terminal. Do not start a second `pi --mode rpc` process to control an already running session.

The extension creates `<getAgentDir()>/herdcats/<native-session-UUID>.sock`, normally `~/.pi/agent/herdcats/<UUID>.sock`. The directory is mode 0700 and socket mode 0600; every directory component is checked for symlinks. `PI_CODING_AGENT_DIR` changes Pi's agent directory; pass the same path to the bridge using `--pi-agent-dir /absolute/path/to/agent-dir`. A duplicate endpoint is refused, including a stale endpoint left after a crash. Never delete an endpoint belonging to a running session. Shutdown removes only an endpoint successfully created by this extension instance.

The host bridge independently binds Herdr's pane/terminal/native-session reference to the exact native session file, then checks the extension's session ID and file. A missing or incompatible extension leaves Terminal available. No session is selected using file modification time or a shared working directory.

## Supported live behavior

- Native branch history from `sessionManager.getBranch()` and assistant `message_start` / `message_update` streaming, with native tool calls and tool results preserved.
- Plain user messages through `pi.sendUserMessage()` on an idle, trusted session with no queued messages, pending dialog, or local editor draft. Slash commands stay in Terminal.
- Cancellation through the existing context's `abort()` when the agent is running and there is no pending dialog.
- Exact provider/model identities discovered from `modelRegistry.getAvailable()`, with thinking levels from Pi AI's `getSupportedThinkingLevels(model)`. `setModel()` and `setThinkingLevel()` affect the same native session and are checked after application.
- Extension `ctx.ui.confirm`, `select`, and `input` dialogs. A confirmation returns the exact chosen boolean. A selection returns an exact original option string, including any extension-defined permission scope. An input returns literal text. Neither Herdcats nor this extension invents permission scopes or auto-approves a request.

The same public UI object is shared by Pi extension contexts in verified 1.4.0. The adapter wraps that object when the session starts. Terminal dialogs remain visible and functional. Phone responses dismiss the corresponding terminal widget using its documented `AbortSignal`; terminal completion, original signal cancellation, or timeout invalidates the phone request. Concurrent dialogs resolve only the currently displayed top dialog. Methods retained by another extension before wrapping are detected through Pi's public `ui_prompt_start` / `ui_prompt_end` events and remain Terminal-only.

## Explicit limitations

`ctx.ui.custom()` and `ctx.ui.editor()` stay in Terminal. The editor API in 1.4.0 has no public dismissal signal, so racing a phone result would leave its terminal widget alive. Unknown, oversized, or duplicate-label dialog schemas also stay in Terminal. Built-in Pi UI that bypasses extension `ctx.ui` is not intercepted. Project trust must already be granted locally; this transport never grants it.

This is extension UI forwarding, not a universal permission system. Pi permission policies come from the installed extension that defines the dialog. An extension that uses a custom component or does not use the shared public UI methods may require Terminal. Native command pickers, authentication flows, image attachments, and slash commands remain Terminal interactions.

Each mutation requires the current `session_id`, `instance_id`, and `revision`. Revision changes on native activity, branch/model/thinking changes, editor changes, dialogs, and accepted actions. Session/runtime replacement changes the instance ID. Stale actions are rejected rather than retried. A failed or uncertain network response must be refreshed before a new action is considered.

Frames are newline-delimited JSON capped at 1 MiB. State retains at most the most recent 2000 branch records; an oversized complete state returns `pi_state_too_large` and uses Terminal fallback. It does not spill private transcript copies into another file. The socket is a same-user local transport; it is not a network service or a sandbox against the local account owner.

## Local protocol

Request: `{ "method": "state", "params": {} }`. Response: `{ "result": ... }` or `{ "error": { "code": "stale" } }`.

State returns `protocol: 1`, verified `version`, native `session_id` and `session_file`, `instance_id`, `revision`, `status`, `model`, `models`, native `entries`, `pending`, and explicit `capabilities`. Models use `provider/id` identities; each catalog item includes `efforts: [{id,label}]`.

Mutations require `params.expect: {session_id,instance_id,revision}`:

| Method | Additional parameters |
| --- | --- |
| `prompt` | `text` |
| `cancel` | none |
| `model.set` | optional `model` and `effort`; exact discovered values |
| `dialog.respond` | `request_id` and `value` (boolean, exact selection string, or input text) |

Pending dialogs use `{id,kind,title,message?,options?}`. Supported kinds are `confirm`, `select`, and `input`; `terminal` indicates that the original UI must handle the interaction. There is no phone action for a terminal-only dialog.

## Validation

```sh
node --test bridge/pi-extension/runtime.test.mjs
```

The suite uses disposable synthetic contexts and Unix sockets: identity/revision guards, exact permission scopes, terminal abort, provider disambiguation, thinking validation, unknown custom/editor fallback, private endpoint modes, duplicate-session ownership, local draft invalidation, streaming, bounded frames, and project trust. Socket tests require an environment that permits local Unix socket binding.

A reproducible real Pi 1.4.0 TUI probe uses isolated configuration, a synthetic command, and an entirely local synthetic model provider:

```sh
python3 bridge/pi-extension/tui-probe.py \
  --pi-package ~/.bun/install/global/node_modules/@earendil-works/pi-coding-agent
```

It verifies native session identity, socket state, forwarding of `ctx.ui.confirm`, explicit remote denial returned as `false` to the original command, and removal of the terminal dialog. On the same native session it discovers the synthetic catalog, switches model and thinking level, confirms an effort-only change without replacing the model, submits a plain prompt, observes streaming assistant text, cancels the run, and verifies the native branch returns to idle. The probe drains its disposable terminal while waiting for responses to avoid startup PTY backpressure. No private session content, active agent panes, real provider requests, or credentials are used.

Authoritative APIs inspected: Pi 1.4.0 `docs/extensions.md`, `dist/core/extensions/types.d.ts`, `dist/core/extensions/runner.js`, `dist/modes/interactive/interactive-mode.js`, `dist/core/session-manager.d.ts`, and Pi AI 1.4.0 `getSupportedThinkingLevels` in `dist/models.js`. RPC behavior is documented separately in Pi's `docs/rpc.md` and does not establish attachment to an existing TUI.
