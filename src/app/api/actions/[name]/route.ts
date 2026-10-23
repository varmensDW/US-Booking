import {NextResponse} from 'next/server';
import {ActionError, errorBody, runAction} from '@/server/db';
import {isJson, sameOrigin} from '@/server/request';
import {ACTION_FUNCTIONS, ACTION_SCHEMAS, type ActionKey} from '@/shared/actions';

export const dynamic = 'force-dynamic';

// One staff action per request (POST /api/actions/<name>, JSON body). The body is checked against
// the shared schema, then passed to its database function, which validates again, checks for stale
// data and writes an audit entry. Nothing here books, buys or prints anything.
export async function POST(req: Request, ctx: {params: Promise<{name: string}>}) {
  const {name} = await ctx.params;
  if (!Object.hasOwn(ACTION_SCHEMAS, name)) return NextResponse.json({error: 'Unknown action'}, {status: 404});
  if (!sameOrigin(req)) return NextResponse.json({error: 'Cross-site requests are not accepted'}, {status: 403});
  if (!isJson(req)) return NextResponse.json({error: 'Send the action as application/json'}, {status: 415});
  const key = name as ActionKey;
  const body = await req.json().catch(() => undefined);
  const parsed = ACTION_SCHEMAS[key].safeParse(body);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return NextResponse.json({error: issue ? `${issue.path.join('.') || 'request'}: ${issue.message}` : 'Invalid request'}, {status: 422});
  }
  try {
    const result = await runAction(ACTION_FUNCTIONS[key], parsed.data as Record<string, unknown>);
    return NextResponse.json({result}, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    if (e instanceof ActionError) return NextResponse.json({error: e.message}, {status: e.status});
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
