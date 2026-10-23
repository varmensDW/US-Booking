'use client';

import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {cn} from '@/client/lib/utils';

const TABS = [
  {href: '/settings', label: 'General'},
  {href: '/settings/package-profiles', label: 'Package Profiles'},
  {href: '/settings/wayfair-sandbox', label: 'Wayfair Sandbox'},
];

export function SettingsTabs() {
  const pathname = usePathname();
  return (
    <nav aria-label="Settings sections" className="mb-5 flex gap-1 overflow-x-auto border-b border-line">
      {TABS.map(t => {
        const active = pathname === t.href;
        return (
          <Link key={t.href} href={t.href} aria-current={active ? 'page' : undefined}
            className={cn('-mb-px whitespace-nowrap border-b-2 px-3 py-2 text-sm font-medium transition-colors duration-150',
              active ? 'border-primary text-primary' : 'border-transparent text-muted hover:text-ink')}>
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
