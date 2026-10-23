'use client';

import * as React from 'react';
import {motion} from 'motion/react';
import {Ban, CircleHelp, ClipboardList, Layers, Search, X} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Input} from '@/client/components/ui/input';
import {Select, SelectContent, SelectItem, SelectTrigger, SelectValue} from '@/client/components/ui/select';
import {Skeleton} from '@/client/components/ui/skeleton';
import {EmptyState, ErrorState, IconTile, StaleBanner, type TileTone} from '@/client/components/bits';
import {GroupTable} from '@/client/components/group-table';
import {GroupDrawer} from '@/client/components/group-drawer';
import {useQueue} from '@/client/lib/api';
import {
  channelLabel, confirmedIso2, destinationKey, REVIEW_STATUS_LABELS, reviewStatus, type ReviewStatus,
} from '@/client/lib/domain';
import type {QueueGroup} from '@/shared/types';

function SummaryCard({label, value, hint, icon, tone, delay}: {label: string; value: React.ReactNode; hint: string; icon: React.ReactNode; tone: TileTone; delay: number}) {
  return (
    <motion.div initial={{opacity: 0, y: 8}} animate={{opacity: 1, y: 0}} transition={{duration: 0.2, delay}}>
      <Card className="flex h-full items-start gap-4 p-5">
        {icon}
        <div className="min-w-0">
          <p className="text-sm font-medium text-muted">{label}</p>
          <p className="mt-1 text-3xl font-semibold tabular-nums tracking-tight text-ink">{value}</p>
          <p className={`mt-1 text-xs ${tone === 'review' ? 'text-review' : 'text-muted'}`}>{hint}</p>
        </div>
      </Card>
    </motion.div>
  );
}

function FlagTile({iso2}: {iso2: string}) {
  return (
    <span aria-hidden className="inline-flex size-11 shrink-0 items-center justify-center rounded-xl bg-canvas">
      <span className={`fi fi-${iso2.toLowerCase()} rounded-[3px] shadow-[0_0_0_1px_rgb(15_23_42/0.12)]`} style={{width: 24, height: 18}} />
    </span>
  );
}

function SummaryCards({groups}: {groups: QueueGroup[]}) {
  const orders = groups.flatMap(g => g.destinations);
  const us = orders.filter(d => confirmedIso2(d) === 'US').length;
  const ca = orders.filter(d => confirmedIso2(d) === 'CA').length;
  const unconfirmed = orders.filter(d => !confirmedIso2(d)).length;
  const review = groups.filter(g => g.state === 'review').length;
  const merged = groups.filter(g => g.order_count > 1).length;
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <SummaryCard label="Imported groups" value={groups.length} tone="primary" delay={0}
        hint={`${orders.length} orders · ${merged} merged group${merged === 1 ? '' : 's'}`}
        icon={<IconTile icon={Layers} tone="primary" size="lg" />} />
      <SummaryCard label="Needs review" value={review} tone="review" delay={0.04}
        hint={review ? 'Awaiting staff review' : 'No group awaiting review'}
        icon={<IconTile icon={ClipboardList} tone="review" size="lg" />} />
      <SummaryCard label="Confirmed US destinations" value={us} tone="teal" delay={0.08}
        hint={`${unconfirmed} order${unconfirmed === 1 ? '' : 's'} with country not confirmed`}
        icon={<FlagTile iso2="us" />} />
      <SummaryCard label="Confirmed Canada destinations" value={ca} tone="teal" delay={0.12}
        hint="Verified map or evidenced order confirmation only"
        icon={<FlagTile iso2="ca" />} />
    </div>
  );
}

function SummarySkeleton() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4" aria-hidden>
      {[0, 1, 2, 3].map(i => (
        <Card key={i} className="flex items-start gap-4 p-5">
          <Skeleton className="size-11 rounded-xl" />
          <div className="flex-1 space-y-2"><Skeleton className="h-4 w-32" /><Skeleton className="h-8 w-14" /><Skeleton className="h-3 w-40" /></div>
        </Card>
      ))}
    </div>
  );
}

type DestFilter = 'all' | 'US' | 'CA' | 'unconfirmed' | 'conflict';
type StatusFilter = 'all' | ReviewStatus;

export function OrderReview() {
  const queue = useQueue();
  const [search, setSearch] = React.useState('');
  const [channel, setChannel] = React.useState('all');
  const [dest, setDest] = React.useState<DestFilter>('all');
  const [status, setStatus] = React.useState<StatusFilter>('all');
  const [openId, setOpenId] = React.useState<number | null>(null);
  const opener = React.useRef<HTMLElement | null>(null);
  const open = React.useCallback((id: number, el: HTMLElement) => { opener.current = el; setOpenId(id); }, []);

  const groups = React.useMemo(() => queue.data?.groups ?? [], [queue.data]);
  const channels = React.useMemo(() => [...new Set(groups.flatMap(g => g.channels))].sort(), [groups]);
  const filtered = React.useMemo(() => {
    const q = search.trim().toLowerCase();
    return groups.filter(g => {
      if (q && !g.platform_order_refs.some(r => r.toLowerCase().includes(q)) && !g.skus.some(s => s.toLowerCase().includes(q))
          && !g.oms_order_ids.some(id => String(id).includes(q))) return false;
      if (channel !== 'all' && !g.channels.includes(channel)) return false;
      if (dest !== 'all' && destinationKey(g) !== dest) return false;
      if (status !== 'all' && reviewStatus(g) !== status) return false;
      return true;
    });
  }, [groups, search, channel, dest, status]);
  const filtersActive = search !== '' || channel !== 'all' || dest !== 'all' || status !== 'all';
  const clear = () => { setSearch(''); setChannel('all'); setDest('all'); setStatus('all'); };

  if (queue.isPending) {
    return (
      <div className="space-y-5" aria-busy="true" aria-label="Loading review queue">
        <SummarySkeleton />
        <Card className="p-5 space-y-3">{[0, 1, 2, 3, 4, 5].map(i => <Skeleton key={i} className="h-11 w-full" />)}</Card>
      </div>
    );
  }
  if (queue.isError && !queue.data) {
    return (
      <Card>
        <ErrorState title="The review queue could not be loaded" message={queue.error.message}
          onRetry={() => queue.refetch()} retrying={queue.isFetching} />
      </Card>
    );
  }
  const data = queue.data!;

  return (
    <div className="space-y-5">
      {queue.isError && <StaleBanner message={queue.error.message} dataTime={data.generated_at} />}
      <SummaryCards groups={groups} />

      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-xl border border-line bg-surface px-4 py-2.5 text-sm text-muted shadow-card">
        <span className="inline-flex items-center gap-1.5"><Ban aria-hidden className="size-4 text-subtle" />
          <span><span className="font-medium text-ink">Booking and printing are not available</span> in this phase (live booking is off).</span></span>
        <span className="tabular-nums">{data.totals.lines} order lines · {data.totals.ordered_units} ordered units</span>
        <span className="tabular-nums">{data.totals.component_rows} pack-component reference rows (not ordered units, not parcel contents)</span>
      </div>

      <Card>
        <div className="flex flex-col gap-3 border-b border-line p-4 lg:flex-row lg:items-center">
          <div className="relative flex-1">
            <Search aria-hidden className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-subtle" />
            <Input value={search} onChange={e => setSearch(e.target.value)} placeholder="Search order reference or SKU"
              aria-label="Search by order reference or SKU" className="pl-9" />
          </div>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-3 lg:flex">
            <Select value={channel} onValueChange={setChannel}>
              <SelectTrigger aria-label="Marketplace" className="lg:w-44"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All marketplaces</SelectItem>
                {channels.map(c => <SelectItem key={c} value={c}>{channelLabel(c)}</SelectItem>)}
              </SelectContent>
            </Select>
            <Select value={dest} onValueChange={v => setDest(v as DestFilter)}>
              <SelectTrigger aria-label="Destination" className="lg:w-48"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All destinations</SelectItem>
                <SelectItem value="US">Confirmed United States</SelectItem>
                <SelectItem value="CA">Confirmed Canada</SelectItem>
                <SelectItem value="unconfirmed">Country not confirmed</SelectItem>
                <SelectItem value="conflict">Destination conflict</SelectItem>
              </SelectContent>
            </Select>
            <Select value={status} onValueChange={v => setStatus(v as StatusFilter)}>
              <SelectTrigger aria-label="Review status" className="lg:w-56"><SelectValue /></SelectTrigger>
              <SelectContent>
                <SelectItem value="all">All review statuses</SelectItem>
                {(Object.keys(REVIEW_STATUS_LABELS) as ReviewStatus[]).map(s => <SelectItem key={s} value={s}>{REVIEW_STATUS_LABELS[s]}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
        </div>
        <div className="flex items-center justify-between gap-3 px-4 py-2.5 text-sm text-muted">
          <p aria-live="polite">
            Showing <span className="font-semibold text-ink tabular-nums">{filtered.length}</span> of{' '}
            <span className="tabular-nums">{groups.length}</span> fulfilment groups
            {queue.isFetching && <span className="ml-2 text-subtle">· refreshing…</span>}
          </p>
          {filtersActive && (
            <button type="button" onClick={clear} className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-primary hover:bg-primary-soft">
              <X aria-hidden className="size-3.5" /> Clear filters
            </button>
          )}
        </div>
        {groups.length === 0 ? (
          <EmptyState title="No fulfilment groups imported yet">
            Use <span className="font-medium text-ink">Sync Orders</span> to import open US1 orders from the OMS. Page loads never import anything by themselves.
          </EmptyState>
        ) : filtered.length === 0 ? (
          <EmptyState title="No groups match these filters" icon={CircleHelp}>
            Try a different search or <button type="button" className="font-medium text-primary underline" onClick={clear}>clear the filters</button>.
          </EmptyState>
        ) : (
          <GroupTable groups={filtered} onOpen={open} />
        )}
      </Card>

      <GroupDrawer groupId={openId} onClose={() => setOpenId(null)} returnFocusTo={opener} queueGroup={groups.find(g => g.id === openId) ?? null} />
    </div>
  );
}
