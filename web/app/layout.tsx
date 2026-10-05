import type { Metadata, Viewport } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'Herdcats — Herding cats, from your pocket',
  description: 'Herding cats, from your pocket. Native iPhone client for Herdr with git worktrees, Citadel SSH, and live terminal pane streaming.',
  icons: {
    icon: [
      { url: '/assets/favicon.png', sizes: '32x32', type: 'image/png' },
      { url: '/assets/logo.png', sizes: '512x512', type: 'image/png' },
    ],
    apple: { url: '/assets/apple-touch-icon.png', sizes: '180x180', type: 'image/png' },
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
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
