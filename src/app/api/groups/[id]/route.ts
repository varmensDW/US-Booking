import {NextResponse} from 'next/server';
import {getGroupDetail} from '@/server/queries';
import {errorBody} from '@/server/db';

export const dynamic = 'force-dynamic';

export async function GET(_req: Request, ctx: {params: Promise<{id: string}>}) {
  const {id} = await ctx.params;
  const groupId = Number(id);
  if (!/^\d+$/.test(id) || !Number.isSafeInteger(groupId)) {
    return NextResponse.json({error: 'Invalid group id'}, {status: 400});
  }
  try {
    const detail = await getGroupDetail(groupId);
    if (!detail) return NextResponse.json({error: 'Fulfilment group not found'}, {status: 404});
    return NextResponse.json(detail, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
