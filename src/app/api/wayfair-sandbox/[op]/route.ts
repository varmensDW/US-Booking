import {NextResponse} from 'next/server';
import {z} from 'zod';
import {ActionError, errorBody, runAction} from '@/server/db';
import {isJson, sameOrigin} from '@/server/request';
import {WayfairError} from '@/server/wayfair/client';
import {checkRegistration, fetchLabel, lookupOrders, register, testAuth} from '@/server/wayfair/service';
import {measure, staffName} from '@/shared/actions';

export const dynamic = 'force-dynamic';

const po = z.string().trim().regex(/^[A-Za-z0-9_-]{1,40}$/, 'Enter a sandbox PO number');
const SCHEMAS = {
  auth: z.object({}),
  orders: z.object({limit: z.number().int().min(1).max(10), has_response: z.boolean().nullable(), po_numbers: z.array(po).max(10).optional()}),
  'check-registration': z.object({po_number: po}),
  register: z.object({
    staff: staffName, po_number: po,
    package: z.object({length: measure, width: measure, height: measure, weight: measure}).nullable(),
  }),
  resolve: z.object({
    staff: staffName, id: z.number().int().positive(), outcome: z.enum(['found_existing', 'resolved_not_registered']),
    evidence: z.string().trim().min(3).max(1000),
  }),
  'fetch-label': z.object({staff: staffName, registration_id: z.number().int().positive()}),
} as const;
type Op = keyof typeof SCHEMAS;

const STATUS: Record<WayfairError['kind'], number> = {
  config: 409, auth: 502, network: 502, timeout: 504, provider: 502, graphql: 502, unexpected: 502,
};

// Explicit Wayfair SANDBOX operations. Each request is one staff action; nothing here touches live
// orders, parcels, booking attempts or readiness.
export async function POST(req: Request, ctx: {params: Promise<{op: string}>}) {
  const {op} = await ctx.params;
  if (!Object.hasOwn(SCHEMAS, op)) return NextResponse.json({error: 'Unknown operation'}, {status: 404});
  if (!sameOrigin(req)) return NextResponse.json({error: 'Cross-site requests are not accepted'}, {status: 403});
  if (!isJson(req)) return NextResponse.json({error: 'Send the request as application/json'}, {status: 415});
  const parsed = SCHEMAS[op as Op].safeParse(await req.json().catch(() => undefined));
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return NextResponse.json({error: issue ? `${issue.path.join('.') || 'request'}: ${issue.message}` : 'Invalid request'}, {status: 422});
  }
  const body = parsed.data as Record<string, unknown>;
  try {
    let result: unknown;
    switch (op as Op) {
      case 'auth': result = await testAuth(); break;
      case 'orders': result = await lookupOrders({limit: body.limit as number, hasResponse: body.has_response as boolean | null,
                                                 poNumbers: body.po_numbers as string[] | undefined}); break;
      case 'check-registration': result = await checkRegistration(body.po_number as string); break;
      case 'register': result = await register({staff: body.staff as string, po: body.po_number as string,
                                                pkg: body.package as {length: string; width: string; height: string; weight: string} | null}); break;
      case 'resolve': result = await runAction('wayfair_sandbox_resolve', body); break;
      case 'fetch-label': result = await fetchLabel({staff: body.staff as string, registrationId: body.registration_id as number}); break;
    }
    return NextResponse.json({result}, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    if (e instanceof ActionError) return NextResponse.json({error: e.message}, {status: e.status});
    if (e instanceof WayfairError) return NextResponse.json({error: e.message, kind: e.kind}, {status: STATUS[e.kind]});
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
