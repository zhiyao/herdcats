import Link from 'next/link';
import { ThemeToggle } from './ThemeToggle';

export type SitePageKey = 'support' | 'about' | 'privacy' | 'terms' | 'licenses';

const LINKS: { key: SitePageKey; href: string; label: string }[] = [
  { key: 'support', href: '/support', label: 'Support' },
  { key: 'about', href: '/about', label: 'About' },
  { key: 'privacy', href: '/privacy', label: 'Privacy' },
  { key: 'terms', href: '/terms', label: 'Terms' },
  { key: 'licenses', href: '/licenses', label: 'Licenses' },
];

/** Top navigation that floats directly on the night sky (DESIGN.md §6, Nav link). */
export function SiteNav({ current }: { current?: SitePageKey }) {
  return (
    <header className="site-nav">
      <Link href="/" className="nav-badge" aria-label="Herdcats home">
        <img src="/assets/logo.png" alt="" width={40} height={40} />
      </Link>
      <nav className="nav-links" aria-label="Site">
        {LINKS.map(({ key, href, label }) => (
          <Link
            key={key}
            href={href}
            className={`nav-link${current === key ? ' nav-link-active' : ''}`}
            aria-current={current === key ? 'page' : undefined}
          >
            {label}
          </Link>
        ))}
      </nav>
      <div className="nav-end">
        <a
          href="https://github.com/zhiyao/herdcats"
          target="_blank"
          rel="noopener noreferrer"
          className="nav-link"
        >
          GitHub ↗
        </a>
        <ThemeToggle />
      </div>
    </header>
  );
}
