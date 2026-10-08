import { PixelHorizon } from './PixelHorizon';
import { SiteNav, type SitePageKey } from './SiteNav';

interface SiteHeaderProps {
  current?: SitePageKey;
  title: string;
  children?: React.ReactNode;
}

/** Moonlit banner with the site nav and page title; its treeline flows into the page body. */
export function SiteHeader({ current, title, children }: SiteHeaderProps) {
  return (
    <div className="site-header">
      <PixelHorizon />
      <div className="site-header-inner">
        <SiteNav current={current} />
        <div className="site-header-title">
          <h1>{title}</h1>
          {children}
        </div>
      </div>
    </div>
  );
}
