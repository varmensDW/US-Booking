import {NextResponse} from 'next/server';
import {getStatus} from '@/server/queries';

export const dynamic = 'force-dynamic';

// Connectivity (read-only identity checks) and configuration names; never values.
export async function GET() {
  return NextResponse.json(await getStatus(), {headers: {'Cache-Control': 'no-store'}});
}
