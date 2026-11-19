/** Opt-in Herdcats transport for the existing Pi interactive process. */
import { VERSION, getAgentDir, type ExtensionAPI } from '@earendil-works/pi-coding-agent';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';

export default async function herdcats(pi: ExtensionAPI) {
  const runtimePath = fileURLToPath(new URL('./runtime.mjs', import.meta.url));
  // Load current bytes via a data URL so Pi /reload sees updated runtime.mjs.
  const source = readFileSync(runtimePath, 'utf8');
  const { createIntegration } = await import(`data:text/javascript;base64,${Buffer.from(source, 'utf8').toString('base64')}`);
  const integration = createIntegration(pi, { getSupportedThinkingLevels, version: VERSION });
  pi.on('session_start', async (_event, ctx) => {
    if (ctx.mode !== 'tui') return;
    try { await integration.start(ctx, { directory: join(getAgentDir(), 'herdcats') }); }
    catch (error) {
      ctx.ui.notify(`Herdcats conversation controls unavailable: ${error instanceof Error ? error.message : 'unknown error'}. Continue in Terminal.`, 'warning');
    }
  });
  pi.on('session_shutdown', async () => { await integration.stop(); });
}
