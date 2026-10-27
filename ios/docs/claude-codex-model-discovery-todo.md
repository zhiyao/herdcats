# Claude and Codex model discovery follow-up

Status: implemented in the bridge and iOS model choices page, pending review and live phone-to-host validation. Unchecked items below are open or deliberately deferred.

Recorded: 2026-10-26.

## Claude: replace the maintained catalog as the primary source

Current behavior: the bridge offers maintained model aliases and version labels, then supplements them with the observed current model. Aliases can continue resolving through Claude Code, but the displayed versions and offered choices can become stale or disagree with account, organization, or provider restrictions.

- [ ] Investigate a supported structured discovery interface in the installed Claude Code version.
- [ ] If structured discovery is unavailable, evaluate safely reading the running session's `/model` picker, including scrolling and closing it without selecting a model or changing a draft.
- [ ] Use the same account, provider, configuration, and policy context as the running pane. A generic API catalog may not match Claude Code's subscription or organization access.
- [ ] Discover available model IDs, labels, aliases, and supported effort levels where the source provides them.
- [ ] Remove maintained version assumptions from current-selection matching. Keep the exact observed active model visible, including older or custom model IDs.
- [ ] Cache the last successfully discovered catalog with source, CLI version, and freshness information. Evaluate persistence across bridge reconnects.
- [ ] Use maintained aliases only as an explicit fallback; distinguish cached or fallback choices from freshly verified availability.

Reference: [Claude's guidance on available models and `/model`](https://support.claude.com/en/articles/14552983-models-usage-and-limits-in-claude-code).

## Codex: validate cache freshness and recovery

Current behavior: the bridge reads `models_cache.json` from the resolved Codex home (`CODEX_HOME`, otherwise `~/.codex`), filters visible model entries, and reads per-model reasoning levels. It supplements the catalog with the observed current model. Accepted effort names still have a maintained allowlist.

- [ ] Investigate Codex's supported catalog-discovery and refresh interfaces, using the installed CLI and primary documentation.
- [ ] Determine which cache metadata reliably indicates freshness and compatibility. Document missing, outdated, malformed, and partially written cache behavior.
- [ ] Confirm the cache belongs to the same host, user, Codex configuration, and provider context as the running session.
- [ ] Refresh stale or missing data through a supported read-only interface where available; preserve the active session and its model.
- [ ] Preserve model visibility rules, ordering, display labels, and model-specific effort levels.
- [ ] Investigate how to support newly introduced reasoning levels without silently omitting them or accepting unverified terminal commands.
- [ ] Keep the actual current model visible when it is absent from the cache, while distinguishing it from a complete available-model catalog.

## Shared behavior and acceptance checks

Build on Agy's loading, error, and Retry handling rather than adding another silent-empty-list path.

- [ ] Show clear loading, failure, cached-data, and retry states in the model choices page.
- [ ] Bound discovery time and output; protect conversation streaming from repeated failed background discovery.
- [ ] Make explicit Retry recover immediately after installation, authentication, policy, or cache repairs.
- [ ] Bind discovery results and model changes to the current pane, terminal, native session, connection ownership, and transcript generation.
- [ ] Reject late replies after a pane/session switch or reconnect; retain existing idle-composer and switch-confirmation guards.
- [ ] Test new and retired models, restricted accounts, custom providers, unknown effort values, missing/corrupt/stale caches, discovery failure and recovery, and two panes with different active models.
- [ ] Verify discovery itself leaves the selected model, user draft, terminal interaction, and persisted settings unchanged.
- [ ] Complete live phone-to-host validation before claiming end-to-end support.

## Code starting points

- [Bridge catalog, model observation, and switching](../../bridge/src/service.rs)
- [Bridge model parsers and maintained defaults](../../bridge/src/model_control.rs)
- [Codex home resolution](../../bridge/src/codex_config.rs)
- [iOS model state](../Herdcats/Features/AgentTimeline/AgentTimelineState.swift)
- [iOS model choices UI](../Herdcats/Features/PaneVoiceComposeBar.swift)


## Implementation notes (2026-10-26)

Research, installed CLIs Claude Code 2.1.310 and codex-cli 0.164.0:

- **Claude**: no structured model-listing command exists (`claude --help` has no `models` subcommand). Scraping the running `/model` picker means typing into a live pane, so it is deferred. The bridge now labels its catalog `source: fallback`, `complete: false`. Alias rows carry no version label, and current-selection matching is exact only. The observed active id keeps its own `observedOnly` row, including older and custom ids. Nothing is cached, because nothing is discovered.
- **Codex**: `codex debug models` renders the raw catalog as JSON and refreshes it unless `--bundled` is passed. `--bundled` is offline and reflects the binary, not the account, so it is not used. The bridge runs `codex --version` then `codex debug models` with the session's `CODEX_HOME`, a 6 s shared deadline, 1 MiB output cap, no stdin, and process-group kill. It does this only inside `model.status`, never on streaming paths. Whether the CLI rewrites `models_cache.json` as a side effect is untested live, and the bridge itself never writes it.
- Cache freshness: `fetched_at` must parse and be within 6 h, and `client_version` must equal the installed version. Missing or unreadable metadata is never fresh. Malformed JSON, a missing `models` array, and no visible model are reported as `codex_catalog_invalid`/`codex_catalog_empty`. A missing file is `codex_catalog_missing`.
- Recovery: refresh failures are backed off for 60 s and successes are remembered for 5 min, in memory. Each explicit `model.status` (iOS Retry or open) clears that memory and retries immediately. A failed refresh keeps a readable cache, labelled `cache`, `fresh: false`.
- `model.status` replies carry `catalog {source, fresh, complete, fetchedAt, cliVersion, error}`. The iOS model choices page shows a note for anything not fresh and complete, with Retry.
- Unknown Codex reasoning levels are reported as `unsupportedEfforts` (plain tokens only). They are never selectable, because picker driving still depends on the allowlisted row labels and the on-screen verification.
- All pane/session/generation, idle-composer, and switch-confirmation guards are untouched. Discovery sends no input.

Open: live validation; Claude `/model` picker reading; persisting a Claude cache; codex cache `etag` and provider checks beyond `CODEX_HOME`.
