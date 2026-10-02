import { SitePage, sitePageStyles as styles } from '@/components/SitePage';

export const metadata = {
  title: 'Herdcats — About',
  description: 'Why Herdcats exists: a minimal, open source iPhone client for Herdr over direct SSH.',
};

export default function AboutPage() {
  return (
    <SitePage badge="About" title="About Herdcats">
      <section className={styles.section}>
        <h2 className={styles.label}>Who</h2>
        <p>Herdcats is maintained by Enchanting Labs.</p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>Why</h2>
        <p>
          <a href="https://herdr.dev" target="_blank" rel="noopener noreferrer">Herdr</a> changed how I
          run AI agents across machines. When I&rsquo;m away from my desk, I still want to check on them.
          Existing tools were subscriptions, closed source, or locked to a few popular agents. I wanted
          one that talks directly to each agent&rsquo;s own terminal UI, whatever the agent.
        </p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>What</h2>
        <p>Herdcats is a minimal iPhone app for Herdr:</p>
        <ul className={styles.list}>
          <li>Direct SSH, with no server and no middle layer</li>
          <li>Fast and simple, built around Herdr&rsquo;s own spaces, tabs, panes and agents</li>
          <li>Built-in quota integration so you can see your subscription usage</li>
        </ul>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>Why Herdcats?</h2>
        <p>
          In Monty Python&rsquo;s <em>Life of Brian</em>, shepherds joke about a herd of cats waiting to
          be sheared — the point being it&rsquo;s absurd, basically impossible. That&rsquo;s the playful
          take: &ldquo;herding cats&rdquo; means trying to wrangle things that refuse to be wrangled. Managing
          independent AI agents feels the same. The name also nods to{' '}
          <a href="https://herdr.dev" target="_blank" rel="noopener noreferrer">Herdr</a>
          &rsquo;s herd, and to the lazy pixel cats that show up when you&rsquo;re waiting or offline.
          Herding cats, from your pocket.
        </p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>How to get it</h2>
        <p>
          It&rsquo;s{' '}
          <a href="https://github.com/zhiyao/herdcats" target="_blank" rel="noopener noreferrer">
            open source
          </a>{' '}
          and contributions are welcome. It&rsquo;s on TestFlight now and coming to the App Store for a
          small one-time price that covers the developer fee.
        </p>
      </section>
    </SitePage>
  );
}
