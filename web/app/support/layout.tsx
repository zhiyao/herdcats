import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Herdcats — Support',
  description: 'SSH setup, configuration, and troubleshooting support for Herdcats on iOS.',
};

export default function SupportLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <>{children}</>;
}
