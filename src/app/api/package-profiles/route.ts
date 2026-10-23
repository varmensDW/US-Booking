import {NextResponse} from 'next/server';
import {getPackageProfiles} from '@/server/queries';
import {errorBody} from '@/server/db';

export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    return NextResponse.json(await getPackageProfiles(), {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
