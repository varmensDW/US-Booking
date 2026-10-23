import {NextResponse} from 'next/server';
import {errorBody} from '@/server/db';
import {sandboxRecords, sandboxStatus} from '@/server/wayfair/service';

export const dynamic = 'force-dynamic';

// Wayfair sandbox status (configuration, last authentication and order-access results) and the
// sandbox registration/label records. Never contacts Wayfair.
export async function GET() {
  const status = sandboxStatus();
  try {
    return NextResponse.json({...status, records: await sandboxRecords()}, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json({...status, records: null, ...errorBody(e)}, {status: 503});
  }
}
