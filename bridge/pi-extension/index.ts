/** Opt-in Herdcats transport for the existing Pi 1.4.0 interactive process. */
import { VERSION, getAgentDir, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { join } from 'node:path';
import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { createIntegration } from './runtime.mjs';

export default function herdcats(pi: ExtensionAPI) {
  const integration = createIntegration(pi, { getSupportedThinkingLevels });
  pi.on('session_start', async (_event, ctx) => {
    if (ctx.mode !== 'tui') return;
    if (VERSION !== '1.4.0') {
      ctx.ui.notify(`Herdcats controls require verified Pi 1.4.0 (running ${VERSION}). Continue in Terminal.`, 'warning');
      return;
    }
    try { await integration.start(ctx, { directory: join(getAgentDir(), 'herdcats') }); }
    catch (error) {
      ctx.ui.notify(`Herdcats conversation controls unavailable: ${error instanceof Error ? error.message : 'unknown error'}. Continue in Terminal.`, 'warning');
    }
  });
  pi.on('session_shutdown', async () => { await integration.stop(); });
}
