# Agy conversations

The iOS app accepts Herdr's `agy` and `antigravity_cli` names for the Antigravity CLI adapter. A native conversation opens only when the connected bridge advertises `agy: true` and `record_content: true`. Prompt submission also verifies the current pane, terminal, native conversation ID, and the exact session source `herdr:antigravity_cli`.

The published installer remains pinned to bridge 0.3.0 with its existing checksum and Claude/Codex agent list. It cannot install Agy support. Until an Agy bridge release is published and verified, build the bridge from this source checkout on the SSH host:

```sh
cargo build --release --manifest-path bridge/Cargo.toml
./bridge/target/release/herdcats-bridge --version-json
```

Confirm that the version report includes `antigravity_cli`. Manually install the built binary at `~/.local/bin/herdcats-bridge`, then choose **Check again** in the conversation view. A compatible manually installed bridge is accepted without replacing it with the pinned release.

Agy approvals preserve all permission scopes and send the selected option number and exact labels to the bridge. The bridge owns guarded screen navigation; iOS never converts a displayed number into a terminal shortcut. Questions support single selection, multiple selection, and write-in answers through `question_kind: agy` and `agy_question` steps. Model controls use the connected bridge's model-control capability and dynamic model status. Each Agy model change includes the captured native session identity and transcript generation, so a replacement session cannot receive an old selection. Agy does not appear in the Claude/Codex phone-answer hook setup list.

Use Terminal whenever the bridge cannot verify the session, pending interaction, or supported controls. The iOS implementation does not imply that an Agy-enabled binary has been published.

The source adapter follows `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`. It accepts only an exact UUID ID reference from Herdr, pins the brain directory, and walks every path component without following symlinks. Two panes sharing a working directory remain bound to their independent native IDs. Delayed file creation is retried. Appends retain the generation; rewrite/rotation and session replacement invalidate it. Reads, records, previews, retained entries, pagination, and content chunks use the bridge's existing bounds.

Native command cards distinguish **run once**, **allow in this conversation**, **persist to settings.json**, and **deny**. File, URL, MCP, subagent, ambiguous multi-call, amended, and otherwise unrecognized dialogs stay in Terminal. Every navigation step verifies the current occupant, transcript prefix and screen; uncertain delivery is never automatically retried. Question completion and command approval/denial confirmation require the matching unambiguous GENERIC transcript result. A planner marked DONE does not answer a question.

Model controls are enabled only for the live-tested installed version 1.4.7. The bridge queries `agy models` with byte/time limits and validates requested IDs against that catalog. It changes the existing idle terminal through `/model <id>` or `/effort <level>`, requiring an empty composer, the captured session/generation, and a fresh acknowledgment plus matching footer. It never resumes a second process. `/model` may persist across sessions; the app does not promise a session-only preference. Unverified CLI versions retain history and Terminal fallback.

Validation uses copied synthetic transcript data, disposable Agy probes, and fake Herdr socket fixtures. No private conversation content was used for fixtures. The current installed Herdr metadata was checked and confirms `agent=agy`, reference `agent=agy`, `kind=id`, `source=herdr:antigravity_cli`. Tests cover independent same-folder panes, session replacement, delayed source creation, partial lines, rewrite/rotation, symlink rejection, result linkage, stale actions, bounded content references, and iOS capability negotiation. User-reported phone-to-host smoke on 2026-10-26 exercised questions, approvals and model switching through iOS and exposed issues addressed in this branch. This is separate from the automated simulator/synthetic tests and the independent read-only host probes; it is not an automated final-build phone-to-host certification.

## Model family protocol (source only)

The bridge owns Agy family normalization; iOS renders generic model/effort objects. For example, discovered `gemini-3.8-flash-high` / `Gemini 3.8 Flash (High)` becomes public `gemini-3.8-flash` / `Gemini 3.8 Flash`, with High selected separately. Only matching terminal low/medium/high ID and label suffixes are grouped. Other parentheses, unknown variants, literal native IDs colliding with family IDs, and disagreeing family labels remain lossless. Per-family effort options come only from discovered concrete variants.

`model.status`, opted-in verified Agy snapshots, `model.updated`, and `model.set.applied` expose the same family identity. Native catalog entries, footer observations, acknowledgments and model overrides stay raw inside the bridge. Set requests resolve a family and effort to an exact discovered native entry. A family switch preserves current effort when supported, otherwise prefers Medium, Low, then High. An explicit unsupported effort is rejected. Effort-only changes retain the current family. Exact legacy native target IDs remain accepted and keep their concrete selection when no effort is specified.

Stale expectations may use either the public family or exact legacy native ID, but the effort must still match the authoritative native pair; family aliases are accepted only when catalog normalization is unambiguous. Captured pane/terminal/native-session identity, generation, source verification, empty composer, installed-version validation and fresh confirmation remain required. No family ID is typed into Agy and no native ID is guessed.

Rebuild the app and rebuild/reinstall this source bridge to receive normalized choices from the host. Older native-ID clients remain compatible with the new bridge; the simplified app can still render an older bridge's native catalog literally, but cannot group its variants. This source change does not publish a release or change the installer pin/checksum. Catalog loading, failure throttling, explicit Retry and Terminal fallback are unchanged.

The verified 1.4.7 idle footer has two shapes: `Gemini 3.8 Flash · high` and the full native label `GPT-OSS 120B (Medium)`. The bridge matches either shape against the dynamic catalog; the latter infers Medium only from the exact matching native ID/label pair. Composer checks use that same catalog match and still require the empty bordered input region. Drafts, quoted/history footers, menus, malformed or ambiguous labels do not authorize a model command. GPT-OSS remains Medium-only and can switch to another family without losing the authoritative native expectation. This correction is bridge-only; rebuilding/reinstalling the source bridge is required, with no additional iOS rebuild.
