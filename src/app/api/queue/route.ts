import {NextResponse} from 'next/server';
import {getQueue} from '@/server/queries';
import {errorBody} from '@/server/db';

export const dynamic = 'force-dynamic';

// Review queue from the booking snapshot. Never triggers an OMS import.
export async function GET() {
  try {
    return NextResponse.json(await getQueue(), {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
