// Explicit "Sync Orders" action for the web UI. It runs the existing sync command
// (scripts/oms-sync.mjs --apply, default limit of 20 new groups) as a child process and reports
// only the stages that command actually prints. Nothing else in the UI reads the OMS.
//
// Duplicate prevention:
//   * one job per server process: a second start while a job runs is refused (HTTP 409);
//   * across processes the database refuses a concurrent import (oms_sync_apply locks the
//     sync_state row with FOR UPDATE NOWAIT), and that failure is reported as a failed job.
import {spawn} from 'node:child_process';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {envFileOverride, projectRoot} from './db';
import type {SyncJob, SyncStage} from '@/shared/types';

interface JobStore {
  current: SyncJob | null;
}
// Survives module reloads in development.
const store: JobStore = ((globalThis as {__usbSyncJobs?: JobStore}).__usbSyncJobs ??= {current: null});

export function currentJob(): SyncJob | null {
  return store.current;
}

function mark(job: SyncJob, stage: SyncStage, note?: string) {
  if (job.stages.length && job.stage === stage && !note) return;
  job.stage = stage;
  job.stages.push({stage, at: new Date().toISOString(), ...(note ? {note} : {})});
}

export function startSync(): {job: SyncJob; started: boolean} {
  if (store.current?.state === 'running') return {job: store.current, started: false};
  const job: SyncJob = {
    id: randomUUID(), state: 'running', stage: 'starting', stages: [], started_at: new Date().toISOString(),
    finished_at: null, message: null, summary: null,
  };
  mark(job, 'starting');
  store.current = job;

  const args = [path.join(/*turbopackIgnore: true*/ projectRoot, 'scripts', 'oms-sync.mjs'), '--apply',
                ...(envFileOverride ? [`--env-file=${envFileOverride}`] : [])];
  const child = spawn(/*turbopackIgnore: true*/ process.execPath, args, {
    cwd: projectRoot, windowsHide: true,
    env: Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('PG'))) as NodeJS.ProcessEnv,
  });
  let buffer = '';
  let stopLine = '';
  let dbError = '';
  const onLine = (line: string) => {
    if (line.startsWith('OMS:')) mark(job, 'connecting', 'connected to the OMS (read-only) and the booking database');
    else if (line.startsWith('Mode:')) mark(job, 'reading_oms', 'reading open US1 orders from the OMS');
    else if (line.startsWith('Read from OMS:')) mark(job, 'writing_booking', line.replace('Read from OMS:', 'read').trim());
    else if (line.startsWith('STOP:')) stopLine = line.slice(5).trim();
    // psql error text (e.g. the concurrent-import lock); it never contains connection details.
    else if (!dbError && /^(psql:.*?)?ERROR:/.test(line)) dbError = line.replace(/^psql:[^E]*/, '').trim();
    else if (line.startsWith('SUMMARY ')) {
      try {
        const s = JSON.parse(line.slice(8));
        job.summary = {counts: s.counts ?? {}, review_cases_opened: s.review_cases_opened ?? {}, sync_run_id: s.sync_run_id};
      } catch {
        // The command's own exit code still decides success.
      }
    }
  };
  const onData = (d: Buffer) => {
    buffer += d.toString();
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() ?? '';
    lines.forEach(onLine);
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  const finish = (ok: boolean, message: string) => {
    if (job.state !== 'running') return;
    job.state = ok ? 'succeeded' : 'failed';
    job.finished_at = new Date().toISOString();
    job.message = message;
    mark(job, ok ? 'finished' : 'failed', message);
  };
  child.on('error', () => finish(false, 'the sync command could not be started'));
  child.on('close', code => {
    if (buffer) onLine(buffer);
    if (code === 0 && job.summary) {
      const c = job.summary.counts;
      finish(true, `sync run ${job.summary.sync_run_id}: ${c.groups_new ?? 0} new group(s), ${c.groups_refreshed ?? 0} refreshed, `
        + `${c.orders_changed ?? 0} order(s) changed`);
    } else {
      // STOP lines carry the command's own reason; they never contain connection strings.
      const reason = stopLine || `the sync command exited with code ${code}`;
      finish(false, dbError ? `${reason} (${dbError.slice(0, 200)})` : reason);
    }
  });
  return {job, started: true};
}
