import {NextResponse} from 'next/server';
import {getStatus, getSyncRuns} from '@/server/queries';
import {errorBody} from '@/server/db';
import {currentJob, startSync} from '@/server/sync-job';
import {sameOrigin} from '@/server/request';
import type {SyncStatusResponse} from '@/shared/types';

export const dynamic = 'force-dynamic';

// Current sync job (if any) plus recorded sync runs.
export async function GET() {
  const job = currentJob();
  try {
    const {runs, last_success_at} = await getSyncRuns();
    return NextResponse.json({job, runs, last_success_at} satisfies SyncStatusResponse, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json({job, runs: [], last_success_at: null, ...errorBody(e)}, {status: 503});
  }
}

// Explicit sync. Refused while a sync is running, and when either database is unavailable.
export async function POST(req: Request) {
  if (!sameOrigin(req)) return NextResponse.json({error: 'Cross-site requests are not accepted'}, {status: 403});
  const running = currentJob();
  if (running?.state === 'running') {
    return NextResponse.json({error: 'A sync is already running', job: running}, {status: 409});
  }
  const status = await getStatus();
  if (!status.sync_available) {
    return NextResponse.json({error: status.sync_unavailable_reason ?? 'Sync is unavailable'}, {status: 503});
  }
  const {job, started} = startSync();
  return NextResponse.json({job}, {status: started ? 202 : 409});
}
