import Link from 'next/link';
import styles from './SitePage.module.css';
import { SiteHeader } from './SiteHeader';
import type { SitePageKey } from './SiteNav';

interface SitePageProps {
  title?: string;
  current?: SitePageKey;
  children: React.ReactNode;
}

/** Shared moonlit header, night body, and footer for the text pages (About, Privacy, Terms, Licenses). */
export function SitePage({ title, current, children }: SitePageProps) {
  return (
    <div className={styles.wrapper}>
      <SiteHeader current={current} title={title ?? 'Herdcats'} />

      <main className={styles.main}>{children}</main>

      <SiteFooter />
    </div>
  );
}

/** Night-950 footer shared by the text pages and Support. */
export function SiteFooter() {
  return (
    <footer className={styles.footer}>
      <div className={styles.footerInner}>
        <p>© {new Date().getFullYear()} Herdcats. Open source iOS client for Herdr.</p>
        <div className={styles.footerLinks}>
          <Link href="/support" className={styles.footerLink}>Support</Link>
          <Link href="/about" className={styles.footerLink}>About</Link>
          <Link href="/privacy" className={styles.footerLink}>Privacy</Link>
          <Link href="/terms" className={styles.footerLink}>Terms</Link>
          <Link href="/licenses" className={styles.footerLink}>Licenses</Link>
          <a
            href="https://github.com/zhiyao/herdcats"
            target="_blank"
            rel="noopener noreferrer"
            className={styles.footerLink}
          >
            GitHub ↗
          </a>
        </div>
      </div>
    </footer>
  );
}

export { styles as sitePageStyles };
