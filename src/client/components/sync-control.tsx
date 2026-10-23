'use client';

import * as React from 'react';
import {motion, AnimatePresence} from 'motion/react';
import {useQueryClient} from '@tanstack/react-query';
import {CircleCheck, CircleX, RefreshCw, X} from 'lucide-react';
import {Button} from '@/client/components/ui/button';
import {Tooltip} from '@/client/components/ui/tooltip';
import {useStartSync, useStatus, useSyncStatus} from '@/client/lib/api';
import type {SyncJob, SyncStage} from '@/shared/types';

export const STAGE_LABELS: Record<SyncStage, string> = {
  starting: 'Starting sync',
  connecting: 'Connecting to OMS and booking database',
  reading_oms: 'Reading open US1 orders from the OMS',
  writing_booking: 'Updating the review queue',
  finished: 'Sync finished',
  failed: 'Sync failed',
};

// The icon rotates only while the server reports a running job (and not under reduced motion).
export function SyncButton() {
  const sync = useSyncStatus();
  const status = useStatus();
  const start = useStartSync();
  const job = sync.data?.job ?? null;
  const running = job?.state === 'running' || start.isPending;
  const unavailable = status.data && !status.data.sync_available ? status.data.sync_unavailable_reason : null;
  const statusUnknown = status.isError && !status.data;
  const disabled = running || Boolean(unavailable) || statusUnknown;
  const reason = running ? 'A sync is already running.'
    : unavailable ? unavailable
    : statusUnknown ? 'Connection status could not be checked, so sync is unavailable.'
    : 'Import new open US1 orders (at most 20 new groups) and refresh imported ones. Nothing is booked or printed.';

  const button = (
    <Button onClick={() => !disabled && start.mutate()} disabled={disabled} aria-describedby="sync-reason">
      <motion.span
        aria-hidden
        className="inline-flex"
        animate={running ? {rotate: 360} : {rotate: 0}}
        transition={running ? {repeat: Infinity, ease: 'linear', duration: 1} : {duration: 0.2}}
        whileHover={!running && !disabled ? {rotate: 45} : undefined}
      >
        <RefreshCw className="size-4" />
      </motion.span>
      {running ? 'Syncing…' : 'Sync Orders'}
    </Button>
  );
  return (
    <div className="flex items-center gap-3">
      {running && job && (
        <span className="hidden max-w-56 truncate text-sm text-muted lg:inline" aria-hidden>
          {STAGE_LABELS[job.stage]}
        </span>
      )}
      <Tooltip content={reason}>
        {/* Wrapper keeps the tooltip reachable while the button is disabled. */}
        <span tabIndex={disabled ? 0 : -1} className="inline-flex rounded-lg">{button}</span>
      </Tooltip>
      <span id="sync-reason" className="sr-only">{reason}</span>
    </div>
  );
}

// Thin indeterminate bar under the header while a sync runs (static under reduced motion).
export function SyncActivityBar() {
  const {data} = useSyncStatus();
  const running = data?.job?.state === 'running';
  return (
    <div className="relative h-0.5 overflow-hidden" aria-hidden>
      {running && <div className="absolute inset-y-0 w-2/5 animate-indeterminate rounded-full bg-gradient-to-r from-primary via-teal to-primary" />}
    </div>
  );
}

// Announces job progress and the real outcome. Success is shown only for a job the server
// reports as succeeded.
export function SyncOutcome() {
  const {data} = useSyncStatus();
  const start = useStartSync();
  const qc = useQueryClient();
  const job = data?.job ?? null;
  const [dismissed, setDismissed] = React.useState<string | null>(null);
  const lastState = React.useRef<SyncJob['state'] | null>(null);

  React.useEffect(() => {
    if (!job) return;
    if (lastState.current === 'running' && job.state !== 'running') {
      qc.invalidateQueries({queryKey: ['queue']});
      qc.invalidateQueries({queryKey: ['group']});
      qc.invalidateQueries({queryKey: ['status']});
    }
    lastState.current = job.state;
  }, [job, qc]);

  const startError = start.error?.message;
  const show = job && job.state !== 'running' && dismissed !== job.id;
  return (
    <div aria-live="polite" className="empty:hidden">
      {job?.state === 'running' && <span className="sr-only">{STAGE_LABELS[job.stage]}</span>}
      <AnimatePresence>
        {startError && !start.isPending && (
          <motion.div key="start-error" initial={{opacity: 0, y: -6}} animate={{opacity: 1, y: 0}} exit={{opacity: 0}} transition={{duration: 0.18}}
            role="alert" className="mx-4 mt-3 flex items-center gap-3 rounded-xl border border-danger-line bg-danger-soft px-4 py-2.5 text-sm text-danger sm:mx-6">
            <CircleX aria-hidden className="size-4 shrink-0" />
            <span className="flex-1">Sync not started: {startError}</span>
            <button type="button" onClick={() => start.reset()} className="rounded p-1 hover:bg-white/60" aria-label="Dismiss"><X className="size-4" aria-hidden /></button>
          </motion.div>
        )}
        {show && (
          <motion.div key={job.id} initial={{opacity: 0, y: -6}} animate={{opacity: 1, y: 0}} exit={{opacity: 0}} transition={{duration: 0.18}}
            className={job.state === 'succeeded'
              ? 'mx-4 mt-3 flex items-center gap-3 rounded-xl border border-success-line bg-success-soft px-4 py-2.5 text-sm text-success sm:mx-6'
              : 'mx-4 mt-3 flex items-center gap-3 rounded-xl border border-danger-line bg-danger-soft px-4 py-2.5 text-sm text-danger sm:mx-6'}>
            {job.state === 'succeeded' ? <CircleCheck aria-hidden className="size-4 shrink-0" /> : <CircleX aria-hidden className="size-4 shrink-0" />}
            <span className="flex-1">
              <span className="font-semibold">{job.state === 'succeeded' ? 'Sync completed' : 'Sync failed'}</span>
              {job.message ? `: ${job.message}` : ''}
            </span>
            <button type="button" onClick={() => setDismissed(job.id)} className="rounded p-1 hover:bg-white/60" aria-label="Dismiss"><X className="size-4" aria-hidden /></button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
