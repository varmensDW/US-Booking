import {AppShell} from '@/client/components/app-shell';

export default function AppLayout({children}: {children: React.ReactNode}) {
  return <AppShell>{children}</AppShell>;
}
