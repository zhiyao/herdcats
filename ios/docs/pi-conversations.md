# Pi conversations

Pi conversations use the existing Pi TUI through an opt-in Herdcats extension. Herdcats does not attach RPC to a TUI, resume the session in another process, or inject permission responses into the terminal. Pi CLI versions are not gated. The extension checks required public APIs, and the bridge validates Herdcats extension protocol `1`, session identity and response data. Unsupported APIs or protocol versions leave Terminal available.

## Setup from this source checkout

The app’s [pinned bridge installer](../Herdcats/Networking/AgentBridgeClient.swift) supports Pi. To use the progressive Timeline history from this checkout, build the bridge on the SSH computer and load its bundled Pi extension:

```sh
cargo build --release --manifest-path bridge/Cargo.toml
./bridge/target/release/herdcats-bridge --version-json
```

The development binary reports the version declared in [`bridge/Cargo.toml`](../../bridge/Cargo.toml); Pi capability is negotiated separately at runtime and does not require changing the published installer metadata. Manually install that binary in the bridge location used by Herdcats (normally `~/.local/bin/herdcats-bridge`). Building does not replace the running bridge. Do not change a published installer checksum to point to this development build.

When a Pi pane is not running the extension and the bridge advertises `pi_extension_install`, the app checks `herdcats-bridge pi-extension status` over SSH and shows **Install Pi extension** or **Update Pi extension**. Nothing is written until you tap it. Edited extension files are never replaced; the app explains this instead. Pi loads the extension only on startup or `/reload`, so once the files are current the app offers **Type /reload** while Herdr reports the pane idle: it types `/reload` without Enter and opens Terminal, where you can see any draft and press Enter. Updating Herdcats Bridge from the app also updates an older Herdcats extension that is already installed, never one that is absent or edited.

To enable it by hand, use the extension from `bridge/pi-extension/` in the Pi process Herdcats will control. For a new test pane, follow the README's `pi -e ...` command. For an existing TUI, add the extension to Pi's personal extension directory and use Pi's own `/reload` command if available; reload replaces the extension runtime in that same process. If that Pi build cannot load it into the current process, start a separate disposable test pane with the extension enabled. Never launch a second RPC process to represent the same running session. Rebuild this iOS app, connect to the computer, open the Pi pane's Conversation mode, then choose **Check again** if needed. If no exact native session reference is available from Herdr, use Terminal; Herdcats never picks the newest transcript or another session in the same working folder.

## Native controls

The iOS app requires both `pi: true` and `record_content: true` from the connected bridge. A compatible manually installed source bridge is accepted without replacement by the pinned installer. The bridge supplies messages, streaming revisions, tool calls/results, current model and supported thinking levels. Provider/model IDs and thinking choices come from the live Pi catalog; the phone does not invent a model list.

Pi uses `~/.pi/agent` by default. If Pi runs with `PI_CODING_AGENT_DIR` set, pass the same directory to the bridge with `--pi-agent-dir /absolute/path/to/agent-dir`; the bridge uses its `sessions/` child and connects to the matching `herdcats/` socket.

Pi allocates a timestamped session path when a new session starts, but writes the JSONL file lazily. An absent file is therefore normal for a fresh session. Herdcats may use that session only after safely walking the exact Herdr-reported path without following symlinks and confirming that the live extension reports the same native session ID and reserved path. It then reads the branch from Pi's `sessionManager.getBranch()`; an empty branch is valid, so a first prompt can be sent from iOS without first writing a terminal prompt. A stale path or a different extension session remains unavailable.

Prompts, model changes and dialog responses carry the captured pane, terminal, native session, live extension instance and bridge generation. A reconnect or session replacement clears pending cards and model actions. The bridge and live extension revalidate the action before delivery. Failed or uncertain actions are never automatically retried. Pi prompts require an idle, verified extension connection; terminal prompt submission remains available in Terminal mode.

Standard confirm dialogs display Yes and No and return a boolean to the originating extension. Select dialogs preserve each exact option, including any approval scope supplied by that extension. Input dialogs return the submitted text. Pi editor dialogs, custom UI, built-in Pi dialogs that bypass extension `ctx.ui`, and unknown schemas stay in Terminal because Pi 1.4.0 exposes no safe dismissal handle for those surfaces. There is no built-in Pi permission policy added by Herdcats, no automatic approval, and no synthetic “always allow” scope. Extension setup does not use Claude/Codex phone-answer hooks.

## Timeline history

Timeline opens at the newest messages. Pull down at the top to load an earlier page and keep your place. Use the down-arrow button to return to the latest reply. Switching Pi branches opens the selected branch at its newest messages.

The pull-down hint disappears when you reach the start. New replies, revisions, and changes within the loaded history leave it hidden. If Pi recovers earlier messages and can load more before the earliest one you still have, the hint can return. A temporary interruption to the same Pi session shows a delay notice and keeps your loaded messages and paging position.

If an individual message or response exceeds the [extension transport limits](../../bridge/pi-extension/README.md#explicit-limitations), Timeline directs you to Terminal. This can happen when you first open Timeline or load an earlier page. An outdated extension can offer an update through the setup flow above.

## Limitations and validation

Extension-defined dialogs can only be answered natively when they use the supported integration contract. Pi image and thinking blocks are not currently presented as full native timeline content. Terminal and phone races must resolve the same pending request once; late responses are stale. Native cancellation stops the active turn through Pi's extension API and does not kill the pane.

Tests use synthetic bridge frames and disposable extension/session fixtures. iOS checks cover explicit capability negotiation, exact dialog choices and boolean values, stale generation rejection, live instance identity round-trips, reconnect cleanup and guarded model expectations. Pagination regressions are covered in [AgentTimelineTests.swift](../HerdcatsTests/AgentTimelineTests.swift) and [AgentTimelineUITests.swift](../HerdcatsUITests/AgentTimelineUITests.swift). Run phone-to-host smoke checks against the rebuilt app and source bridge. Use Terminal whenever setup, protocol, identity, permission scope, or delivery cannot be verified.
