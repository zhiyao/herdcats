import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Herdcats — Support',
  description: 'Connect over SSH, use Compose and Timeline, set up Herdcats Bridge and phone answers, and troubleshoot Herdcats on iPhone.',
};

export default function SupportLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return <>{children}</>;
}
