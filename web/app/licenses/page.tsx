import { SitePage, sitePageStyles as styles } from '@/components/SitePage';

export const metadata = {
  title: 'Herdcats — Open source licenses',
  description: 'Open source licenses and third-party acknowledgements for Herdcats and its website.',
};

export default function LicensesPage() {
  return (
    <SitePage title="Open source licenses">
      <section className={styles.section}>
        <h2 className={styles.label}>Herdcats</h2>
        <p>
          Herdcats is open source software, built and maintained by Kenny at enchantinglabs.
          The project uses the GNU General Public License version 3, with an additional
          permission for distribution through the Apple App Store and Google Play.
        </p>
        <p>
          <a href="https://github.com/zhiyao/herdcats/blob/main/LICENSE" target="_blank" rel="noopener noreferrer">
            Read the project license ↗
          </a>
        </p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>Website acknowledgements</h2>
        <p>
          This website uses open source software, including Next.js and React. The full
          notices include copyright acknowledgements and license texts for these libraries
          and their included components.
        </p>
        <p>
          <a href="/third-party-notices.txt">Read the full website license notices</a>
        </p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.label}>iPhone app acknowledgements</h2>
        <p>
          The app includes its own dependency licenses, available offline in Settings → Licenses,
          or from Licenses on the welcome screen before connecting.
        </p>
        <p>
          <a href="https://github.com/zhiyao/herdcats/blob/main/THIRD_PARTY_NOTICES.md" target="_blank" rel="noopener noreferrer">
            View the project acknowledgements ↗
          </a>
        </p>
      </section>
    </SitePage>
  );
}
