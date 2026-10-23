import {NextResponse} from 'next/server';
import {errorBody} from '@/server/db';
import {shippoStatus, testRecords} from '@/server/shippo/service';

export const dynamic = 'force-dynamic';

// Shippo TEST status (configuration, last authentication check) and the stored test
// shipments/purchases/labels. Never contacts Shippo.
export async function GET() {
  const status = await shippoStatus();
  try {
    return NextResponse.json({...status, records: await testRecords()}, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json({...status, records: null, ...errorBody(e)}, {status: 503});
  }
}
