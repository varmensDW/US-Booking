import {NextResponse} from 'next/server';
import {z} from 'zod';
import {ActionError, errorBody} from '@/server/db';
import {isJson, sameOrigin} from '@/server/request';
import {LABEL_FILE_TYPES, ShippoError} from '@/server/shippo/client';
import {fetchLabel, getRates, purchaseLabel, recoverPurchaseDetails, resolvePurchase, setLabelFormat, testAuth} from '@/server/shippo/service';
import {DIMENSION_UNITS, WEIGHT_UNITS, measure, staffName} from '@/shared/actions';

export const dynamic = 'force-dynamic';

const CONTENTS_TYPES = ['DOCUMENTS', 'GIFT', 'SAMPLE', 'MERCHANDISE', 'HUMANITARIAN_DONATION', 'RETURN_MERCHANDISE', 'OTHER'] as const;
const NON_DELIVERY = ['ABANDON', 'RETURN'] as const;
const EEL_PFC = ['NOEEI_30_37_a', 'NOEEI_30_37_h', 'NOEEI_30_37_f', 'NOEEI_30_36', 'AES_ITN'] as const;
const B13A = ['FILED_ELECTRONICALLY', 'SUMMARY_REPORTING', 'NOT_REQUIRED'] as const;
const INCOTERMS = ['DDP', 'DDU', 'FCA', 'DAP', 'eDAP'] as const;

const address = z.object({
  name: z.string().trim().min(2, 'Enter a name (at least 2 characters)').max(80),
  company: z.string().trim().max(80).optional(),
  street1: z.string().trim().min(2, 'Enter a street address').max(120),
  street2: z.string().trim().max(120).optional(),
  city: z.string().trim().min(1, 'Enter a city').max(80),
  state: z.string().trim().max(40).optional(),
  zip: z.string().trim().min(1, 'Enter a postal code').max(20),
  country: z.string().trim().regex(/^[A-Za-z]{2}$/, 'Choose a two-letter country'),
  phone: z.string().trim().min(3, 'Enter a phone number').max(30),
  email: z.string().trim().email('Enter a valid email'),
});
const parcel = z.object({
  length: measure, width: measure, height: measure, dimension_unit: z.enum(DIMENSION_UNITS),
  weight: measure, weight_unit: z.enum(WEIGHT_UNITS),
});
const customsItem = z.object({
  description: z.string().trim().min(2, 'Describe the item').max(200),
  quantity: z.number().int().min(1).max(9999),
  net_weight: measure, mass_unit: z.enum(WEIGHT_UNITS),
  value_amount: measure, value_currency: z.string().trim().length(3, 'Use a 3-letter currency code').toUpperCase(),
  origin_country: z.string().trim().regex(/^[A-Za-z]{2}$/, 'Choose a two-letter country of origin'),
  tariff_number: z.string().trim().max(12).optional(),
});
const customs = z.object({
  contents_type: z.enum(CONTENTS_TYPES),
  contents_explanation: z.string().trim().max(200).optional(),
  non_delivery_option: z.enum(NON_DELIVERY),
  certify: z.literal(true, {message: 'Certify that the customs information is accurate'}),
  certify_signer: z.string().trim().min(2, 'Enter who is certifying this (at least 2 characters)').max(120),
  items: z.array(customsItem).min(1, 'Add at least one customs item').max(20),
  // Optional export-compliance fields (Shippo "Create a new customs declaration"). None is
  // defaulted here; staff choose them, or leave them unset and let Shippo's own validation speak.
  incoterm: z.enum(INCOTERMS).optional(),
  eel_pfc: z.enum(EEL_PFC).optional(),
  aes_itn: z.string().trim().max(40).optional(),
  b13a_filing_option: z.enum(B13A).optional(),
  b13a_number: z.string().trim().max(40).optional(),
}).refine(v => v.contents_type !== 'OTHER' || Boolean(v.contents_explanation), {
  message: 'Explain the contents when contents type is OTHER', path: ['contents_explanation'],
}).refine(v => v.eel_pfc !== 'AES_ITN' || Boolean(v.aes_itn), {
  message: 'Enter the AES ITN when the EEL/PFC choice is AES_ITN', path: ['aes_itn'],
}).refine(v => !v.b13a_filing_option || Boolean(v.b13a_number), {
  message: 'Enter the B13A number when a B13A filing option is chosen', path: ['b13a_number'],
});
const rateSummary = z.object({
  rate_object_id: z.string().min(1), carrier: z.string(), service: z.string(), service_token: z.string().optional(),
  amount: z.string(), currency: z.string(), estimated_days: z.number().nullable().optional(), duration_terms: z.string().nullable().optional(),
  carrier_account_id: z.string().nullable().optional(),
});

const SCHEMAS = {
  auth: z.object({}),
  rates: z.object({staff: staffName, ship_to: address, parcel, customs: customs.nullable()}),
  purchase: z.object({staff: staffName, shipment_id: z.number().int().positive(), rate_object_id: z.string().min(1), rate_summary: rateSummary}),
  resolve: z.object({
    staff: staffName, id: z.number().int().positive(), outcome: z.enum(['confirmed_purchased', 'resolved_not_purchased']),
    evidence: z.string().trim().min(3).max(1000),
  }),
  'fetch-label': z.object({staff: staffName, purchase_id: z.number().int().positive()}),
  'recover-details': z.object({staff: staffName, purchase_id: z.number().int().positive()}),
  'set-label-format': z.object({staff: staffName, label_file_type: z.enum(LABEL_FILE_TYPES).nullable()}),
} as const;
type Op = keyof typeof SCHEMAS;

const STATUS: Record<ShippoError['kind'], number> = {config: 409, auth: 502, network: 502, timeout: 504, provider: 502, unexpected: 502};

// Explicit Shippo TEST-mode operations. Each request is one staff action; nothing here touches
// live orders, parcels, booking attempts, readiness, or imports/updates any marketplace order.
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
      case 'rates': result = await getRates({staff: body.staff as string, shipTo: body.ship_to as Parameters<typeof getRates>[0]['shipTo'],
                                            parcel: body.parcel as Parameters<typeof getRates>[0]['parcel'],
                                            customs: body.customs as Parameters<typeof getRates>[0]['customs']}); break;
      case 'purchase': result = await purchaseLabel({staff: body.staff as string, shipmentId: body.shipment_id as number,
                                                     rateObjectId: body.rate_object_id as string,
                                                     rateSummary: body.rate_summary as Parameters<typeof purchaseLabel>[0]['rateSummary']}); break;
      case 'resolve': result = await resolvePurchase(body as Parameters<typeof resolvePurchase>[0]); break;
      case 'fetch-label': result = await fetchLabel({staff: body.staff as string, purchaseId: body.purchase_id as number}); break;
      case 'recover-details': result = await recoverPurchaseDetails({staff: body.staff as string, purchaseId: body.purchase_id as number}); break;
      case 'set-label-format': result = await setLabelFormat({staff: body.staff as string,
                                                              labelFileType: body.label_file_type as Parameters<typeof setLabelFormat>[0]['labelFileType']}); break;
    }
    return NextResponse.json({result}, {headers: {'Cache-Control': 'no-store'}});
  } catch (e) {
    if (e instanceof ActionError) return NextResponse.json({error: e.message}, {status: e.status});
    if (e instanceof ShippoError) return NextResponse.json({error: e.message, kind: e.kind}, {status: STATUS[e.kind]});
    return NextResponse.json(errorBody(e), {status: 503});
  }
}
