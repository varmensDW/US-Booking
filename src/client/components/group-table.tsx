'use client';

import * as React from 'react';
import {
  createColumnHelper, flexRender, getCoreRowModel, getPaginationRowModel, getSortedRowModel, useReactTable, type SortingState,
} from '@tanstack/react-table';
import {ArrowDown, ArrowUp, ArrowUpDown, ChevronLeft, ChevronRight, GitMerge, PanelRightOpen} from 'lucide-react';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Tooltip} from '@/client/components/ui/tooltip';
import {ChannelBadge, CopyButton, DestinationCell} from '@/client/components/bits';
import {groupDestination, omsStatusLabel, reviewItems, STATUS_TONE} from '@/client/lib/domain';
import {formatRelative, formatTimestamp} from '@/client/lib/format';
import {cn} from '@/client/lib/utils';
import type {QueueGroup} from '@/shared/types';

const col = createColumnHelper<QueueGroup>();
const DEST_RANK = {confirmed: 0, mixed: 1, unconfirmed: 2, conflict: 3} as const;

export function GroupTable({groups, onOpen}: {groups: QueueGroup[]; onOpen: (id: number, opener: HTMLElement) => void}) {
  const [sorting, setSorting] = React.useState<SortingState>([]);
  const columns = React.useMemo(() => [
    col.accessor('main_ref', {
      header: 'Order',
      cell: ({row}) => {
        const g = row.original;
        return (
          <div className="flex min-w-0 flex-col gap-1">
            <div className="flex items-center gap-1">
              <span className="whitespace-nowrap font-mono text-[13px] font-semibold text-ink">{g.main_ref}</span>
              <CopyButton value={g.main_ref} label={`Copy order reference ${g.main_ref}`} />
            </div>
            <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted">
              <span className="tabular-nums">OMS {g.container_order_id}</span>
              {g.order_count > 1 && (
                <Badge tone="violet"><GitMerge aria-hidden />{g.order_count - 1} merged order{g.order_count > 2 ? 's' : ''}</Badge>
              )}
            </div>
          </div>
        );
      },
    }),
    col.accessor(g => g.channels.join(','), {
      id: 'marketplace',
      header: 'Marketplace',
      cell: ({row}) => (
        <div className="flex flex-col items-start gap-1">
          {row.original.channels.map(c => <ChannelBadge key={c} channel={c} />)}
          <span className="max-w-40 truncate text-xs text-muted" title={row.original.accounts.join(', ')}>{row.original.accounts.join(', ')}</span>
        </div>
      ),
    }),
    col.accessor(g => DEST_RANK[groupDestination(g).kind], {
      id: 'destination',
      header: 'Destination',
      cell: ({row}) => <DestinationCell dest={groupDestination(row.original)} />,
    }),
    col.accessor('ordered_quantity_total', {
      header: 'Lines / qty',
      cell: ({row}) => (
        <span className="flex flex-col whitespace-nowrap tabular-nums text-ink">
          <span>{row.original.line_count} <span className="text-muted">line{row.original.line_count === 1 ? '' : 's'}</span></span>
          <span>{row.original.ordered_quantity_total} <span className="text-muted">ordered</span></span>
        </span>
      ),
    }),
    col.accessor(g => g.oms_statuses.join(','), {
      id: 'oms_status',
      header: 'OMS status',
      cell: ({row}) => (
        <div className="flex flex-wrap gap-1">
          {row.original.oms_statuses.map(s => <Badge key={s} tone={STATUS_TONE[s] ?? 'neutral'}>{omsStatusLabel(s)}</Badge>)}
        </div>
      ),
    }),
    col.accessor(g => reviewItems(g).length, {
      id: 'review',
      header: 'Review requirements',
      cell: ({row}) => {
        const items = reviewItems(row.original);
        const shown = items.slice(0, 3);
        return items.length === 0 ? <span className="text-sm text-muted">None recorded</span> : (
          <div className="flex max-w-80 flex-wrap gap-1">
            {shown.map(i => <Badge key={i.key} tone={i.tone}>{i.label}</Badge>)}
            {items.length > shown.length && (
              <Tooltip content={items.slice(3).map(i => i.label).join(', ')}>
                <span tabIndex={0} className="inline-flex"><Badge tone="neutral">+{items.length - shown.length} more</Badge></span>
              </Tooltip>
            )}
          </div>
        );
      },
    }),
    col.accessor(g => g.last_synced_at ?? '', {
      id: 'refreshed',
      header: 'Last refreshed',
      cell: ({row}) => (
        <Tooltip content={formatTimestamp(row.original.last_synced_at)}>
          <span tabIndex={0} className="whitespace-nowrap text-sm text-muted">{formatRelative(row.original.last_synced_at)}</span>
        </Tooltip>
      ),
    }),
    col.display({
      id: 'actions',
      header: () => <span className="sr-only">Actions</span>,
      cell: ({row}) => (
        <Button variant="outline" size="sm" onClick={e => onOpen(row.original.id, e.currentTarget)} aria-label={`View details for ${row.original.main_ref}`}>
          <PanelRightOpen aria-hidden /> View details
        </Button>
      ),
    }),
  ], [onOpen]);

  const table = useReactTable({
    data: groups, columns, state: {sorting}, onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(), getSortedRowModel: getSortedRowModel(), getPaginationRowModel: getPaginationRowModel(),
    initialState: {pagination: {pageSize: 10}}, autoResetPageIndex: true,
  });
  const {pageIndex, pageSize} = table.getState().pagination;
  const from = groups.length ? pageIndex * pageSize + 1 : 0;
  const to = Math.min(groups.length, (pageIndex + 1) * pageSize);

  return (
    <div>
      {/* Phones: one card per group, same sorting and pagination as the table. */}
      <ul className="divide-y divide-line md:hidden" aria-label="Fulfilment groups">
        {table.getRowModel().rows.map(row => {
          const g = row.original;
          const items = reviewItems(g);
          return (
            <li key={row.id} className="space-y-3 px-4 py-4">
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0">
                  <div className="flex items-center gap-1">
                    <span className="font-mono text-[13px] font-semibold text-ink break-all">{g.main_ref}</span>
                    <CopyButton value={g.main_ref} label={`Copy order reference ${g.main_ref}`} />
                  </div>
                  <div className="mt-1 flex flex-wrap items-center gap-1.5">
                    {g.channels.map(c => <ChannelBadge key={c} channel={c} />)}
                    {g.oms_statuses.map(s => <Badge key={s} tone={STATUS_TONE[s] ?? 'neutral'}>{omsStatusLabel(s)}</Badge>)}
                    {g.order_count > 1 && <Badge tone="violet"><GitMerge aria-hidden />{g.order_count - 1} merged</Badge>}
                  </div>
                </div>
              </div>
              <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
                <DestinationCell dest={groupDestination(g)} />
                <span className="whitespace-nowrap tabular-nums text-muted">{g.line_count} line{g.line_count === 1 ? '' : 's'} · {g.ordered_quantity_total} ordered</span>
              </div>
              {items.length > 0 && <div className="flex flex-wrap gap-1">{items.map(i => <Badge key={i.key} tone={i.tone}>{i.label}</Badge>)}</div>}
              <div className="flex items-center justify-between gap-2">
                <span className="text-xs text-muted">Refreshed {formatRelative(g.last_synced_at)}</span>
                <Button variant="outline" size="sm" onClick={e => onOpen(g.id, e.currentTarget)} aria-label={`View details for ${g.main_ref}`}>
                  <PanelRightOpen aria-hidden /> View details
                </Button>
              </div>
            </li>
          );
        })}
      </ul>
      <div className="hidden max-h-[70vh] overflow-auto md:block">
        <table className="w-full min-w-[1100px] border-separate border-spacing-0 text-sm">
          <caption className="sr-only">Fulfilment groups awaiting review. Column headers with buttons can be sorted.</caption>
          <thead>
            {table.getHeaderGroups().map(hg => (
              <tr key={hg.id}>
                {hg.headers.map(h => {
                  const sorted = h.column.getIsSorted();
                  return (
                    <th key={h.id} scope="col"
                      aria-sort={sorted === 'asc' ? 'ascending' : sorted === 'desc' ? 'descending' : undefined}
                      className="sticky top-0 z-10 whitespace-nowrap border-b border-line bg-canvas px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide text-muted">
                      {h.column.getCanSort() ? (
                        <button type="button" onClick={h.column.getToggleSortingHandler()}
                          className="inline-flex items-center gap-1.5 rounded px-1 -mx-1 hover:text-ink">
                          {flexRender(h.column.columnDef.header, h.getContext())}
                          {sorted === 'asc' ? <ArrowUp aria-hidden className="size-3.5 text-primary" />
                            : sorted === 'desc' ? <ArrowDown aria-hidden className="size-3.5 text-primary" />
                            : <ArrowUpDown aria-hidden className="size-3.5 opacity-60" />}
                        </button>
                      ) : flexRender(h.column.columnDef.header, h.getContext())}
                    </th>
                  );
                })}
              </tr>
            ))}
          </thead>
          <tbody>
            {table.getRowModel().rows.map(row => (
              <tr key={row.id} className="group transition-colors duration-150 hover:bg-primary-soft/40">
                {row.getVisibleCells().map(cell => (
                  <td key={cell.id} className={cn('border-b border-line px-4 py-3.5 align-top', cell.column.id === 'actions' && 'text-right')}>
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 text-sm text-muted">
        <span className="tabular-nums">Rows {from}–{to} of {groups.length}</span>
        <div className="flex items-center gap-2">
          <Button variant="outline" size="sm" onClick={() => table.previousPage()} disabled={!table.getCanPreviousPage()} aria-label="Previous page">
            <ChevronLeft aria-hidden /> Previous
          </Button>
          <span className="tabular-nums">Page {pageIndex + 1} of {Math.max(1, table.getPageCount())}</span>
          <Button variant="outline" size="sm" onClick={() => table.nextPage()} disabled={!table.getCanNextPage()} aria-label="Next page">
            Next <ChevronRight aria-hidden />
          </Button>
        </div>
      </div>
    </div>
  );
}
