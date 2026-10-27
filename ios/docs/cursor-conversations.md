# Cursor conversations

The iOS app accepts Herdr's `cursor` agent for the Cursor CLI (`cursor-agent`). A native conversation opens only when the connected bridge advertises `cursor: true` and `record_content: true`. Prompt submission additionally needs `cursor_prompts: true`. Every action verifies the current pane, terminal, native chat ID and the exact session source `herdr:cursor` with an `id`-kind reference.

The published installer remains pinned to bridge 0.3.0 with its existing checksum and Claude/Codex agent list. It cannot install Cursor support. Until a Cursor bridge release is published and verified, build the bridge from this checkout on the SSH host:

```sh
cargo build --release --manifest-path bridge/Cargo.toml
./bridge/target/release/herdcats-bridge --version-json
```

Confirm the report includes `cursor`, install the binary at `~/.local/bin/herdcats-bridge`, then choose **Check again** in the conversation view. The app never offers the pinned installer for a Cursor pane. This change does not publish a release or change the installer pin or checksum.

## What works

| Feature | Status |
| --- | --- |
| Read-only conversation | Yes: messages and tool calls. |
| Sending a prompt | Yes, only when the screen shows an idle, empty composer. |
| Shell command approvals | Run once and Skip. Other choices stay in Terminal. |
| Questions (`AskQuestion`) | Single choice, multiple choice and write-in, one question at a time. |
| Model and effort | Yes, on the verified build only. |
| File edits, MCP, web fetch, plan approvals | Terminal only. |

Use Terminal whenever the bridge cannot verify the session, a pending interaction or a control. Nothing here implies that a Cursor-enabled binary has been published.

## Identity and the transcript

Cursor stores a chat at `~/.cursor/projects/<slug>/agent-transcripts/<chatId>/<chatId>.jsonl`. The `<slug>` is a lossy encoding of the working directory (runs of non-alphanumerics become `-`, and long paths are cut and given a hash suffix the bridge cannot reproduce), so it is never used. The bridge lists the project folders with a pinned, no-symlink root, requires **exactly one** `<chatId>/<chatId>.jsonl` for the exact chat ID Herdr reports, and treats two matches as ambiguous. Two panes in one folder stay bound to their own chats. The file does not exist until the first prompt, so a missing file is retried. The bridge never chooses a transcript by working directory or modification time.

Herdr reports the chat at launch, with two gaps that the bridge cannot close:

- After `cursor-agent --resume` Herdr reports **no** session. The pane shows "Cursor chat not identified" and falls back to Terminal.
- After `/new` inside the TUI, Herdr keeps reporting the **old** chat. The conversation view keeps showing the previous chat while you type into a new one. This cannot be detected from Herdr's data, so it is not guessed around. Start a new Cursor session in the pane, or use Terminal.

### How the transcript behaves

- Each record is one JSON line: a user message wrapped in `<timestamp>` and `<user_query>` tags (stripped only when complete), assistant text, and `tool_use` calls.
- There is **no tool result**, no tool-call ID and no thinking block. A call is written only **after** it was approved, denied or answered, never while it is pending.
- The trailing `{"type":"turn_ended"}` line is **overwritten in place** by the next prompt. The follower never consumes it, rewinds to its start, and does not treat the change as a rewrite. A half-written last line is held back the same way. Editing the consumed part of the file, shrinking it or replacing it resets the generation, which invalidates pending actions.
- Tool entries are marked `completed`, which means only "recorded". It never means succeeded or approved.

## Sending prompts

Cursor writes no pending approval or question to its transcript, and Herdr reports a live question form as `done`. So neither the transcript nor Herdr's status can say whether it is safe to type. For a Cursor pane the **bridge** reads the terminal first (`prompt.submit`), then sends the prompt in the same call, so no phone round trip separates the check from the send. It refuses with a specific message unless the screen is an idle, empty composer (faint placeholder, bottom of the screen). A pending approval card, skip-feedback input, question form, open menu, typed draft, running turn or an unrecognized screen all refuse, and Herdcats points to Terminal.

A message that starts with `/` is **refused** in the app (and again in the bridge). Cursor would run it as one of its own commands (`/quit`, `/model`, `/new`), not send it to the model. Rephrase it or use Terminal. Other agents keep their slash commands. The old Herdr-CLI send path throws for Cursor panes, so the guard cannot be bypassed.

## Approvals

Only Cursor's shell permission card is supported. It is read from the screen and must be the last thing drawn, with a single-row command, one of two known notices, and exactly four rows:

```text
 $  printf X in .

 Run this command?
 Shell allowlist is empty            (or: Not in allowlist: printf)
  → Run (once) (y)
    Add Shell(printf) to allowlist? (tab)
    Run Everything (shift+tab)
    Skip & tell the agent what to do instead (esc or n)
```

A user whose allow list is not empty sees `Not in allowlist: a, b` (names sorted). The names must match the `Add Shell(...)` row as a set. Any other wording, a wrapped command, another tool or any layout change stays in Terminal.

The phone offers **Run (once)** and **Skip** only, with their on-screen numbers (1 and 4) and exact labels. **Add to allowlist** and **Run Everything** persist permissions or switch the whole session to unrestricted, and what follows them was not verified, so they stay in Terminal. Answers are guarded arrow keys and Enter: identity, transcript prefix and the exact card are re-checked before every key, and uncertain delivery is never retried. Skip also submits the optional empty "tell the agent what to do instead" input.

**Confirmation is weaker than for Agy.** With no result in the transcript, "confirmed" means the card left the screen and a `Shell` call for that exact command was appended within 5 seconds. That shows the call was recorded after the decision, not whether it ran or was denied. A slow command is recorded late and can return "not confirmed" although the card is already gone. After a denial the agent may retry the command at once and raise a fresh card, which gets a new request ID.

## Questions

Cursor's `AskQuestion` form shows one question at a time ("Question 2 of 3"). The bridge reads the form from the screen and presents **each visible question as its own request**, with its position; the next question arrives as a new request after Enter. Single choice, multiple choice and write-in work. A write-in is one line of at most 500 characters.

A question is answerable only while untouched (cursor on the first row, nothing checked, write-in empty). Otherwise the app shows that it is in progress at the desk. **Skip is not offered**: Esc would discard the whole form at the desk. While a form is up the reported status is "blocked" so the composer closes. Confirmation is the next question appearing or, for the last question, the form closing and an `AskQuestion` call being appended. The chosen answers are not recorded in the transcript, so the conversation shows the tool call but not what was picked. Forms with more than 8 questions or 32 options stay in Terminal.

## Model and effort

Model controls are enabled only for the exact build `2026.10.22-27dcf5f`. The version comes from the **running session's own process** (Herdr's process information for the pane), not from `cursor-agent --version` or the install symlink, because the installed build can change under a running session when Cursor auto-updates. A different, mixed or unknown version keeps history and Terminal and refuses control before any key is sent.

- **The picker is the catalog.** The flat `--list-models` ids do not match what `/model <id>` accepts: a typed id is a fuzzy filter that can select a neighbour (`claude-opus-5` selected Claude Opus 5.5), and many derived ids are not in the picker. So the bridge opens `/model`, walks the list with verified steps (about 4 seconds for 46 models), closes it, and caches the rows for that version. The labels are also saved to `~/.cache/herdcats/cursor-model-catalog.json` (private, valid for the same build and 24 hours), so the next connection lists the models at once instead of scanning again. A saved list is only a speed-up: every change still picks the exact row in the live picker, and the file is deleted and rescanned whenever the screen disagrees with it. `--list-models` is not used for a quick preview because it prints about 270 flat variants where the picker has 46 rows. Model ids on the wire are slugs of the picker label (`Claude Opus 5.5` → `claude-opus-5-5`) and are never typed into the terminal.
- **Changing the model** types the exact label into the picker filter one character per key (the picker ignores pasted text), moves to the row whose label matches exactly, and presses Enter. Success needs an idle composer whose footer names that model.
- **Changing the effort** uses the model's parameter editor: Tab on its row, move to the radio under `Effort` or `Reasoning`, Enter, Esc. A model without such a group offers no efforts. Context size, Fast and Thinking are never changed. A model's efforts are read when it is the current model or right after it was selected; other models list none until then.
- **Guards.** Both calls need an idle composer in the default Agent mode with no draft, card, form or menu. Every step is verified on screen, a key is sent only after re-reading the screen it acts on, nothing is retried, and every path ends by closing the picker or editor with Esc and requiring the idle composer again. If that fails the bridge reports `picker_stuck` instead of hiding an open menu. Each change carries the captured chat identity and generation.
- **It persists.** Cursor writes every model or effort change to its own `cli-config.json`, so a change made from the phone also becomes the default for new Cursor sessions on that computer. The Configure sheet says so. The bridge never reads or writes that file.

### Custom status lines

The model in use is read from the footer, which a `statusLine` command replaces. A status line works when its first row starts with the exact picker label (the longest label wins, so `Claude Opus 5` is never read as `Claude Opus 5.5`). Context size, effort words, Fast, Thinking, a context bar, usage figures, the directory and a branch are ignored after that. This was probed with a copy of a real status line script, whose `display_name` already contains the parameters and whose `param_summary` repeats them, and which wraps onto a second row. Status lines refresh about once a second, so the bridge waits for the footer after an effort change.

A status line that prints another name, an abbreviated or lower-case name, a partial name or nothing is refused with a clear message before any input. The footer is the status line's own text, so each change is also checked against the picker's cursor row and the editor's selected radio.

## Validation

Fixtures are synthetic or captured from disposable probes of `cursor-agent` 2026.10.22 in a scratch folder, using a throwaway `CURSOR_CONFIG_DIR`. No real conversation content was used. Approval probes chose only run-once and skip; the allowlist and Run Everything rows were never selected, and `--force` was never used. The user's real `~/.cursor/cli-config.json` and `statusline.sh` were hashed before and after probing and never changed; the real status line script was copied and its usage cache repointed so no account token or network was used.

Automated tests cover: exact chat-ID lookup and same-folder panes, delayed creation, the overwritten `turn_ended` line and torn writes, symlink rejection, record and block mapping, the screen classifier and the faint-placeholder check, card and form parsing (including wrapped prompts, labels and unsupported variants), prompt refusal for every non-idle screen, guarded response plans and stale checks, the picker, editor and footer parsers, a stateful emulator of the `/model` TUI with injected faults (dropped keys, a lost Enter, a dead Esc, a transient first frame, a lagging status line), and the iOS capability, identity, question, approval and model-control decoding.

Live checks through the release bridge on disposable panes covered prompt delivery, run-once and skip approvals (including a non-empty allow list), a two-question form with a write-in, refusal of prompts during a pending form while Herdr reported `done`, the picker scan, a model change to a neighbour-named model, effort changes, and refusals in Plan mode and with a typed draft. Not covered: file, MCP, web or plan cards, wrapped commands, other Cursor builds, narrow terminals beyond the one width probed, concurrent desk and phone input, and an automated phone-to-host end-to-end run.

## Known limits

- Model control is gated to the one verified Cursor build. The conversation, prompts, approvals and questions are guarded by what the screen shows, not by a version check, but were verified on that build only; a Cursor update that redraws those screens makes them refuse and fall back to Terminal.
- The `/new` gap and the missing session after `--resume` (see above) are Herdr limits.
- Approval and question confirmation is weaker than Agy's because Cursor records no results.
- The chosen question answers are not visible in the conversation.
