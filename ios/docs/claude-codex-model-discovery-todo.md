# Claude and Codex model discovery follow-up

Status: deferred. Finish Agy implementation and live validation first. This document records future work; it does not authorize starting that implementation now.

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
