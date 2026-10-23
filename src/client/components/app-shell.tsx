'use client';

import * as React from 'react';
import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {motion, AnimatePresence} from 'motion/react';
import {ClipboardList, Clock, History, Menu, PanelLeftClose, PanelLeftOpen, Settings, Warehouse, X, type LucideIcon} from 'lucide-react';
import {cn} from '@/client/lib/utils';
import {useStatus, useSyncStatus} from '@/client/lib/api';
import {formatTimestamp} from '@/client/lib/format';
import {Tooltip} from '@/client/components/ui/tooltip';
import {SyncActivityBar, SyncButton, SyncOutcome} from '@/client/components/sync-control';

const NAV: Array<{href: string; label: string; icon: LucideIcon; title: string; subtitle: string}> = [
  {href: '/review', label: 'Order Review', icon: ClipboardList, title: 'Order Review', subtitle: 'Fulfilment groups imported from the OMS, awaiting staff review'},
  {href: '/sync-history', label: 'Sync History', icon: History, title: 'Sync History', subtitle: 'Recorded OMS imports into the booking database'},
  {href: '/settings', label: 'Settings', icon: Settings, title: 'Settings', subtitle: 'Connections, routes and integration readiness (read-only)'},
];

const STORAGE_KEY = 'usb.sidebar.collapsed';

function NavLinks({collapsed, onNavigate}: {collapsed: boolean; onNavigate?: () => void}) {
  const pathname = usePathname();
  return (
    <ul className="flex flex-col gap-1">
      {NAV.map(item => {
        const active = pathname === item.href || pathname.startsWith(`${item.href}/`);
        const link = (
          <Link
            href={item.href}
            onClick={onNavigate}
            aria-current={active ? 'page' : undefined}
            className={cn(
              'group relative flex h-10 items-center gap-3 rounded-lg px-3 text-sm font-medium transition-colors duration-150',
              active ? 'bg-primary text-white' : 'text-navy-text hover:bg-navy-2 hover:text-white',
              collapsed && 'justify-center px-0',
            )}
          >
            <motion.span aria-hidden className="inline-flex" whileHover={{scale: 1.12}} transition={{duration: 0.15}}>
              <item.icon className="size-[18px]" />
            </motion.span>
            {!collapsed && <span className="truncate">{item.label}</span>}
            {collapsed && <span className="sr-only">{item.label}</span>}
          </Link>
        );
        return <li key={item.href}>{collapsed ? <Tooltip content={item.label} side="right">{link}</Tooltip> : link}</li>;
      })}
    </ul>
  );
}

function Brand({collapsed}: {collapsed: boolean}) {
  return (
    <div className={cn('flex items-center gap-3 px-1', collapsed && 'justify-center px-0')}>
      <span aria-hidden className="inline-flex size-9 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-primary to-teal text-white shadow-sm">
        <Warehouse className="size-[18px]" />
      </span>
      {!collapsed && (
        <span className="flex min-w-0 flex-col leading-tight">
          <span className="truncate text-sm font-semibold text-white">US Booking</span>
          <span className="truncate text-xs text-navy-muted">US1 warehouse</span>
        </span>
      )}
    </div>
  );
}

export function AppShell({children}: {children: React.ReactNode}) {
  const pathname = usePathname();
  const [collapsed, setCollapsed] = React.useState(false);
  const [mobileOpen, setMobileOpen] = React.useState(false);
  const sync = useSyncStatus();
  const status = useStatus();
  const synthetic = status.data?.environment === 'synthetic';

  React.useEffect(() => {
    try {
      const stored = window.localStorage.getItem(STORAGE_KEY);
      // Without a saved preference, start collapsed on tablet-width screens to leave room for the table.
      setCollapsed(stored ? stored === '1' : window.innerWidth < 1536);
    } catch {
      setCollapsed(window.innerWidth < 1536);
    }
  }, []);
  const toggle = () => {
    setCollapsed(c => {
      try {
        window.localStorage.setItem(STORAGE_KEY, c ? '0' : '1');
      } catch {
        // Ignore.
      }
      return !c;
    });
  };

  const page = NAV.find(n => pathname === n.href || pathname.startsWith(`${n.href}/`)) ?? NAV[0];
  const lastSuccess = sync.data?.last_success_at ?? null;

  return (
    <div className="flex min-h-dvh">
      <a href="#main" className="sr-only z-50 rounded-lg bg-primary px-4 py-2 text-white focus:not-sr-only focus:fixed focus:left-4 focus:top-4">
        Skip to content
      </a>

      {/* Desktop/tablet sidebar */}
      <motion.aside
        aria-label="Main navigation"
        className="on-navy sticky top-0 hidden h-dvh shrink-0 flex-col gap-6 overflow-hidden bg-navy px-3 py-5 md:flex"
        animate={{width: collapsed ? 72 : 240}}
        initial={false}
        transition={{duration: 0.2, ease: 'easeOut'}}
      >
        <Brand collapsed={collapsed} />
        <nav className="flex-1"><NavLinks collapsed={collapsed} /></nav>
        <button
          type="button"
          onClick={toggle}
          aria-expanded={!collapsed}
          aria-label={collapsed ? 'Expand sidebar' : 'Collapse sidebar'}
          className={cn('flex h-10 items-center gap-3 rounded-lg px-3 text-sm text-navy-muted transition-colors duration-150 hover:bg-navy-2 hover:text-white', collapsed && 'justify-center px-0')}
        >
          {collapsed ? <PanelLeftOpen aria-hidden className="size-[18px]" /> : <PanelLeftClose aria-hidden className="size-[18px]" />}
          {!collapsed && <span>Collapse</span>}
        </button>
      </motion.aside>

      {/* Mobile sidebar */}
      <AnimatePresence>
        {mobileOpen && (
          <>
            <motion.div key="scrim" className="fixed inset-0 z-40 bg-navy/50 md:hidden" initial={{opacity: 0}} animate={{opacity: 1}} exit={{opacity: 0}}
              transition={{duration: 0.18}} onClick={() => setMobileOpen(false)} aria-hidden />
            <motion.aside key="drawer" aria-label="Main navigation" role="dialog" aria-modal="true"
              className="on-navy fixed inset-y-0 left-0 z-50 flex w-64 flex-col gap-6 bg-navy px-3 py-5 md:hidden"
              initial={{x: -280}} animate={{x: 0}} exit={{x: -280}} transition={{duration: 0.2, ease: 'easeOut'}}
              onKeyDown={e => e.key === 'Escape' && setMobileOpen(false)}>
              <div className="flex items-center justify-between">
                <Brand collapsed={false} />
                <button type="button" autoFocus onClick={() => setMobileOpen(false)} aria-label="Close navigation"
                  className="rounded-lg p-2 text-navy-muted hover:bg-navy-2 hover:text-white">
                  <X aria-hidden className="size-5" />
                </button>
              </div>
              <nav><NavLinks collapsed={false} onNavigate={() => setMobileOpen(false)} /></nav>
            </motion.aside>
          </>
        )}
      </AnimatePresence>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="sticky top-0 z-30 border-b border-line bg-surface/95 backdrop-blur">
          {synthetic && (
            <div role="status" className="bg-violet px-4 py-1.5 text-center text-sm font-semibold text-white sm:px-6">
              Synthetic test data: this instance is connected to a disposable test database, not live orders.
            </div>
          )}
          <div className="flex flex-col gap-3 px-4 py-3 sm:px-6 lg:flex-row lg:items-center lg:gap-6">
            <div className="flex min-w-0 flex-1 items-start gap-2">
              <button type="button" onClick={() => setMobileOpen(true)} aria-label="Open navigation"
                className="-ml-2 rounded-lg p-2 text-muted hover:bg-canvas hover:text-ink md:hidden">
                <Menu aria-hidden className="size-5" />
              </button>
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h1 className="text-lg font-semibold tracking-tight text-ink sm:text-xl">{page.title}</h1>
                  <span className="inline-flex items-center gap-1 rounded-full border border-teal-line bg-teal-soft px-2 py-0.5 text-xs font-semibold text-teal-strong">
                    <Warehouse aria-hidden className="size-3.5" /> US1 warehouse
                  </span>
                </div>
                <p className="mt-0.5 hidden text-sm text-muted sm:block">{page.subtitle}</p>
              </div>
            </div>
            <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 lg:justify-end">
              <div className="flex items-center gap-2 text-sm text-muted">
                <Clock aria-hidden className="size-4 shrink-0 text-subtle" />
                <span>
                  Last successful sync:{' '}
                  <span className="font-medium text-ink">
                    {sync.isLoading ? 'checking…' : sync.isError && !sync.data ? 'unavailable' : formatTimestamp(lastSuccess)}
                  </span>
                </span>
              </div>
              <SyncButton />
            </div>
          </div>
          <SyncActivityBar />
        </header>
        <SyncOutcome />
        <main id="main" className="min-w-0 flex-1 px-4 py-5 sm:px-6 sm:py-6">
          <AnimatePresence mode="wait" initial={false}>
            <motion.div key={pathname} initial={{opacity: 0, y: 6}} animate={{opacity: 1, y: 0}} exit={{opacity: 0}} transition={{duration: 0.18}}>
              {children}
            </motion.div>
          </AnimatePresence>
        </main>
      </div>
    </div>
  );
}
