import { screenshotUrl } from '@/lib/screenshots';
import { SitePage } from '@/components/SitePage';
import styles from './page.module.css';

export const metadata = {
  title: 'Herdcats — Features',
  description: 'Explore Herdcats spaces, agents, terminal, quotas, Compose and voice on iPhone in light and dark mode.',
};

const screens = [
  ['01-spaces', 'Spaces', 'See your workspaces and which agents need attention.'],
  ['02-agents', 'Agents', 'Check blocked, working and finished agents across projects.'],
  ['03-pane', 'Live terminal', 'Read real ANSI terminal output and send input to your agent.'],
  ['04-keys', 'Terminal keys', 'Use arrows, function keys and modifiers from your iPhone.'],
  ['05-agent-pane', 'Agent pane', 'Open an agent’s pane and continue where you left off.'],
  ['06-quota', 'Model quotas', 'Track remaining usage and reset windows across providers.'],
  ['07-connect', 'Connection settings', 'Connect directly to your machine over SSH or Tailscale.'],
  ['08-settings', 'Settings', 'Choose your appearance, pane preferences and local draft storage.'],
  ['09-compose', 'Compose', 'Draft and review a message before sending it to your agent.'],
  ['10-voice', 'Voice', 'Dictate a message, then review it before sending.'],
];

export default function FeaturesPage() {
  return (
    <SitePage current="features" title="Your agents, from your pocket">
      <p className={styles.intro}>
        Manage workspaces, follow your agents, and send your next instruction over SSH.
        Explore the features below with sample sessions from the iPhone app.
        Use the theme switch to see each feature in light or dark mode.
      </p>
      <div className={styles.grid}>
        {screens.map(([id, title, description]) => (
          <figure className={styles.card} key={id}>
            <figcaption>
              <h2>{title}</h2>
              <p>{description}</p>
            </figcaption>
            {(['dark', 'light'] as const).map((mode) => {
              const src = screenshotUrl(id, mode === 'light');
              return (
                <a className={styles[mode]} href={src} key={mode} aria-label={`View ${title} in ${mode} mode at full size`}>
                  <img src={src} width={1320} height={2868} loading="lazy" alt={`${title} in ${mode} mode. ${description}`} />
                </a>
              );
            })}
          </figure>
        ))}
      </div>
    </SitePage>
  );
}
