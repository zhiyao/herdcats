import Link from 'next/link';
import styles from './SitePage.module.css';

interface SitePageProps {
  badge?: string;
  title?: string;
  children: React.ReactNode;
}

/** Shared header, glow background, and footer for the text pages (About, Privacy, Terms). */
export function SitePage({ title, children }: SitePageProps) {
  return (
    <div className={styles.wrapper}>
      <header className={styles.header}>
        <Link href="/" className={styles.brandLink}>
          <img src="/assets/logo.png" alt="" width={36} height={36} className={styles.logo} />
          <span className={styles.brandName}>Herdcats</span>
        </Link>
      </header>

      <main className={styles.main}>
        {title ? <h1 className={styles.title}>{title}</h1> : null}
        {children}
      </main>

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
    </div>
  );
}

export { styles as sitePageStyles };
