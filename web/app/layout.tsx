import type { Metadata, Viewport } from 'next';
import { Jost, Silkscreen } from 'next/font/google';
import './globals.css';
import { THEME_STORAGE_KEY } from '@/lib/scenery';

// "Moonlit" type from DESIGN.md: Jost for UI, Silkscreen for pixel labels.
const jost = Jost({ subsets: ['latin'], variable: '--font-sans', display: 'swap' });
const silkscreen = Silkscreen({ subsets: ['latin'], weight: ['400', '700'], variable: '--font-pixel', display: 'swap' });

const themeScript = `try{document.documentElement.dataset.theme=localStorage.getItem('${THEME_STORAGE_KEY}')==='light'?'light':'dark'}catch(e){document.documentElement.dataset.theme='dark'}`;

export const metadata: Metadata = {
  metadataBase: new URL('https://herdcats.dev'),
  title: 'Herdcats — Herding cats, from your pocket',
  description: 'Herding cats, from your pocket. Native iPhone client for Herdr with git worktrees, Citadel SSH, and live terminal pane streaming.',
  icons: {
    icon: [
      { url: '/assets/favicon.png', sizes: '32x32', type: 'image/png' },
      { url: '/assets/logo.png', sizes: '512x512', type: 'image/png' },
    ],
    apple: { url: '/assets/apple-touch-icon.png', sizes: '180x180', type: 'image/png' },
  },
  openGraph: {
    title: 'Herdcats — Herding cats, from your pocket',
    description: 'Herding cats, from your pocket. Native iPhone client for Herdr with git worktrees, Citadel SSH, and live terminal pane streaming.',
    url: '/',
    siteName: 'Herdcats',
    type: 'website',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'Herdcats' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'Herdcats — Herding cats, from your pocket',
    description: 'Herding cats, from your pocket. Native iPhone client for Herdr with git worktrees, Citadel SSH, and live terminal pane streaming.',
    images: ['/og.png'],
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`${jost.variable} ${silkscreen.variable}`} suppressHydrationWarning>
      <head>
        {/* Apply the saved light/dark choice before first paint to avoid a flash. Night is the default. */}
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
