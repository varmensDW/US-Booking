'use client';

import * as React from 'react';
import {motion} from 'motion/react';
import {CircleCheck, CircleDashed, CircleX, History, LoaderCircle} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Badge} from '@/client/components/ui/badge';
import {Skeleton} from '@/client/components/ui/skeleton';
import {EmptyState, ErrorState, IconTile, StaleBanner} from '@/client/components/bits';
import {STAGE_LABELS} from '@/client/components/sync-control';
import {useSyncStatus} from '@/client/lib/api';
import {CASE_LABELS} from '@/client/lib/domain';
import {formatTime, formatTimestamp} from '@/client/lib/format';
import type {SyncJob} from '@/shared/types';

function CurrentJob({job}: {job: SyncJob}) {
  const running = job.state === 'running';
  return (
    <Card className="p-5">
      <div className="flex items-center gap-3">
        <IconTile icon={running ? LoaderCircle : job.state === 'succeeded' ? CircleCheck : CircleX}
          tone={running ? 'primary' : job.state === 'succeeded' ? 'success' : 'danger'} className={running ? '[&_svg]:animate-spin' : ''} />
        <div className="flex-1">
          <p className="text-sm font-semibold text-ink">
            {running ? 'Sync in progress' : job.state === 'succeeded' ? 'Latest sync from this screen completed' : 'Latest sync from this screen failed'}
          </p>
          <p className="text-xs text-muted">Started {formatTimestamp(job.started_at)}{job.finished_at ? ` · finished ${formatTime(job.finished_at)}` : ''}</p>
        </div>
      </div>
      <ol className="mt-4 space-y-2" aria-label="Sync stages reported by the server">
        {job.stages.map((s, i) => (
          <motion.li key={`${s.stage}-${i}`} initial={{opacity: 0, x: -6}} animate={{opacity: 1, x: 0}} transition={{duration: 0.15}}
            className="flex items-start gap-3 text-sm">
            <span className="mt-0.5 w-24 shrink-0 text-xs tabular-nums text-muted">{formatTime(s.at)}</span>
            <span className={s.stage === 'failed' ? 'text-danger' : s.stage === 'finished' ? 'text-success' : 'text-ink'}>
              {STAGE_LABELS[s.stage]}{s.note ? <span className="text-muted"> — {s.note}</span> : null}
            </span>
          </motion.li>
        ))}
        {running && (
          <li className="flex items-center gap-3 text-sm text-muted">
            <span className="w-24 shrink-0" />
            <CircleDashed aria-hidden className="size-4" /> Waiting for the next stage (no percentage is available)
          </li>
        )}
      </ol>
    </Card>
  );
}

export function SyncHistory() {
  const sync = useSyncStatus();
  if (sync.isPending) {
    return <Card className="space-y-3 p-5" aria-busy="true" aria-label="Loading sync history">{[0, 1, 2, 3].map(i => <Skeleton key={i} className="h-12 w-full" />)}</Card>;
  }
  if (sync.isError && !sync.data) {
    return <Card><ErrorState title="Sync history could not be loaded" message={sync.error.message} onRetry={() => sync.refetch()} retrying={sync.isFetching} /></Card>;
  }
  const {runs, job, error} = sync.data!;
  return (
    <div className="space-y-5">
      {sync.isError && <StaleBanner message={sync.error.message} dataTime={null} />}
      {error && <StaleBanner message={error} dataTime={null} />}
      {job && <CurrentJob job={job} />}
      <Card>
        <div className="flex items-center gap-3 border-b border-line px-5 py-4">
          <IconTile icon={History} tone="teal" size="sm" />
          <h2 className="text-sm font-semibold text-ink">Recorded sync runs</h2>
          <span className="text-xs text-muted">Committed imports and failed import attempts (kept even though the import itself was rolled back); dry runs leave no record. Times shown in your time zone.</span>
        </div>
        {runs.length === 0 ? <EmptyState title="No sync has been recorded yet" /> : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-sm">
              <thead>
                <tr className="bg-canvas text-left text-xs font-semibold uppercase tracking-wide text-muted">
                  <th scope="col" className="px-5 py-3">Run</th>
                  <th scope="col" className="px-5 py-3">Status</th>
                  <th scope="col" className="px-5 py-3">Started</th>
                  <th scope="col" className="px-5 py-3">Groups</th>
                  <th scope="col" className="px-5 py-3">Orders</th>
                  <th scope="col" className="px-5 py-3">Findings opened</th>
                </tr>
              </thead>
              <tbody>
                {runs.map(r => {
                  const c = r.counts ?? {};
                  const cases = Object.entries(r.cases_opened ?? {});
                  return (
                    <tr key={r.id} className="border-t border-line align-top">
                      <td className="px-5 py-3 font-mono text-[13px] text-ink">#{r.id}</td>
                      <td className="px-5 py-3">
                        <Badge tone={r.status === 'ok' ? 'success' : r.status === 'failed' ? 'danger' : 'primary'}>
                          {r.status === 'ok' ? 'Completed' : r.status === 'failed' ? 'Failed' : 'Running'}
                        </Badge>
                        {r.error && <p className="mt-1 text-xs text-danger">{r.error}</p>}
                      </td>
                      <td className="px-5 py-3 text-muted">{formatTimestamp(r.started_at)}</td>
                      <td className="px-5 py-3 tabular-nums text-ink">{c.groups_new ?? 0} new · {c.groups_refreshed ?? 0} refreshed{c.groups_superseded ? ` · ${c.groups_superseded} superseded` : ''}</td>
                      <td className="px-5 py-3 tabular-nums text-ink">{c.orders_inserted ?? 0} new · {c.orders_changed ?? 0} changed · {c.orders_unchanged ?? 0} unchanged</td>
                      <td className="px-5 py-3">
                        {cases.length === 0 ? <span className="text-muted">none</span> : (
                          <div className="flex flex-wrap gap-1">{cases.map(([k, v]) => <Badge key={k} tone="review">{CASE_LABELS[k] ?? k} ×{v}</Badge>)}</div>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
