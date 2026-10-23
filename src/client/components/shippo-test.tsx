'use client';

// Settings → Shippo Test. Every Shippo call is an explicit button press; the page itself only
// reads local status and the existing package-profile default. Results are TEST-mode data, listed
// here only and never linked to live orders, parcels, booking attempts or readiness (the OMS stays
// the only source of orders; nothing here imports an order or updates a marketplace fulfilment).
import * as React from 'react';
import {useMutation, useQuery, useQueryClient} from '@tanstack/react-query';
import {useFieldArray, useForm} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z} from 'zod';
import {
  CircleCheck, CircleCheckBig, CircleX, Download, FlaskConical, KeyRound, MapPinHouse, Package, PackageSearch, Plus, RefreshCw,
  Settings2, ShieldAlert, Trash2, Undo2 as Undo2Icon,
} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Input} from '@/client/components/ui/input';
import {Skeleton} from '@/client/components/ui/skeleton';
import {FieldError, Label, NativeSelect, Textarea} from '@/client/components/ui/field';
import {ActionMessage, ErrorState, IconTile} from '@/client/components/bits';
import {ApiError, usePackageProfiles} from '@/client/lib/api';
import {StaffBar, useStaff} from '@/client/lib/staff';
import {formatTimestamp} from '@/client/lib/format';
import {DIMENSION_UNITS, WEIGHT_UNITS, measure} from '@/shared/actions';

interface Check {ok: boolean; at: string; detail: string}
interface ShipFrom {name: string; company: string | null; street1: string; street2: string | null; city: string; state: string | null; zip: string; country: string; phone: string; email: string}
interface ConfigView {
  mode: string; token_set: boolean; token_is_test: boolean; ship_from: ShipFrom | null;
  ship_return: ShipFrom | null; return_address_configured: boolean; mock: boolean; problems: string[]; usable: boolean;
}
interface Rate {
  rate_object_id: string; carrier: string; service: string; service_token?: string; amount: string; currency: string;
  estimated_days: number | null; duration_terms: string | null; carrier_account_id?: string | null;
}
interface ShippoMessage {source?: string; code?: string; text?: string}
interface Shipment {
  id: number; ship_from: ShipFrom; ship_to: Record<string, unknown>; destination_country: string;
  parcel: Record<string, unknown>; customs: Record<string, unknown> | null; provider_shipment_id: string | null;
  rates: Rate[]; messages: ShippoMessage[]; requested_by: string; requested_at: string;
}
interface Purchase {
  id: number; shipment_id: number; rate_object_id: string; rate_summary: Rate; state: string;
  provider_transaction_id: string | null; test_mode: boolean | null; tracking_number: string | null;
  carrier: string | null; service_level: string | null; carrier_account_id: string | null;
  amount: string | null; currency: string | null; commercial_invoice_source_url: string | null; error: string | null;
  requested_by: string; requested_at: string; completed_at: string | null; resolved_by: string | null; resolution: string | null;
}
interface LabelRec {id: number; purchase_id: number; kind: 'label' | 'customs_invoice'; content_type: string; file_name: string; size_bytes: number; sha256: string; fetched_by: string; fetched_at: string}
interface Status {
  config: ConfigView; auth: Check | null; live_booking_enabled: boolean; label_format: string | null;
  records: {shipments: Shipment[]; purchases: Purchase[]; labels: LabelRec[]} | null;
  error?: string;
}
const COMPLETED_STATES = new Set(['succeeded', 'confirmed_purchased']);
const LABEL_FILE_TYPES = ['PNG', 'PNG_2.3x7.5', 'PDF', 'PDF_2.3x7.5', 'PDF_4x6', 'PDF_4x8', 'PDF_A4', 'PDF_A5', 'PDF_A6', 'ZPLII'] as const;

async function post<T>(op: string, body: unknown): Promise<T> {
  const res = await fetch(`/api/shippo-test/${op}`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)})
    .catch(() => { throw new ApiError('The local server is not reachable', 0); });
  const json = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(json?.error ?? `Request failed (${res.status})`, res.status);
  return json.result as T;
}
function useShippoTest() {
  return useQuery({
    queryKey: ['shippo-test'],
    queryFn: async (): Promise<Status> => {
      const res = await fetch('/api/shippo-test', {cache: 'no-store'});
      const json = await res.json().catch(() => null);
      if (!json?.config) throw new ApiError(json?.error ?? `Request failed (${res.status})`, res.status);
      return json;
    },
  });
}
function useOp<T>(op: string) {
  const qc = useQueryClient();
  return useMutation({mutationFn: (body: unknown) => post<T>(op, body), onSettled: () => qc.invalidateQueries({queryKey: ['shippo-test']})});
}

function StatusRow({icon, title, state, detail}: {icon: typeof KeyRound; title: string; state: 'ok' | 'fail' | 'none'; detail: React.ReactNode}) {
  return (
    <div className="flex items-start gap-3 rounded-xl border border-line p-3">
      <IconTile icon={icon} tone={state === 'ok' ? 'success' : state === 'fail' ? 'danger' : 'neutral'} size="sm" />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-semibold text-ink">{title}</span>
          <Badge tone={state === 'ok' ? 'success' : state === 'fail' ? 'danger' : 'neutral'}>
            {state === 'ok' ? <CircleCheck aria-hidden /> : state === 'fail' ? <CircleX aria-hidden /> : null}
            {state === 'ok' ? 'OK' : state === 'fail' ? 'Problem' : 'Not checked yet'}
          </Badge>
        </div>
        <div className="mt-1 text-xs text-muted">{detail}</div>
      </div>
    </div>
  );
}

const STATE_TONE: Record<string, 'success' | 'danger' | 'review' | 'info' | 'neutral'> = {
  succeeded: 'success', confirmed_purchased: 'info', failed: 'danger', rejected_not_test: 'danger',
  unknown: 'review', requested: 'review', resolved_not_purchased: 'neutral',
};
const STATE_LABEL: Record<string, string> = {
  succeeded: 'Test label purchased', confirmed_purchased: 'Confirmed purchased (reconciled)', failed: 'Failed',
  rejected_not_test: 'Rejected: not test mode', unknown: 'Outcome unknown', requested: 'In flight',
  resolved_not_purchased: 'Resolved: not purchased',
};
const CONTENTS_TYPES = ['MERCHANDISE', 'GIFT', 'SAMPLE', 'DOCUMENTS', 'HUMANITARIAN_DONATION', 'RETURN_MERCHANDISE', 'OTHER'] as const;
const NON_DELIVERY = ['ABANDON', 'RETURN'] as const;
const INCOTERMS = ['DDP', 'DDU', 'FCA', 'DAP', 'eDAP'] as const;
const EEL_PFC = ['NOEEI_30_37_a', 'NOEEI_30_37_h', 'NOEEI_30_37_f', 'NOEEI_30_36', 'AES_ITN'] as const;
const B13A = ['FILED_ELECTRONICALLY', 'SUMMARY_REPORTING', 'NOT_REQUIRED'] as const;

// Shippo's own canonical example recipient (docs.goshippo.com/guides/generate-shipping-label),
// used here only as an obviously-synthetic starting point; staff can change every field. Never
// derived from a real customer or OMS order.
const SYNTHETIC_US = {name: 'Mr Hippo', company: '', street1: 'Broadway 1', street2: '', city: 'New York', state: 'NY', zip: '10007', phone: '+1 555 341 9393', email: 'mrhippo@shippo.com'};
const SYNTHETIC_CA = {name: 'Mr Hippo', company: '', street1: '100 Queen St W', street2: '', city: 'Toronto', state: 'ON', zip: 'M5H 2N2', phone: '+1 555 341 9393', email: 'mrhippo@shippo.com'};

const customsItemSchema = z.object({
  description: z.string().trim().min(2, 'Describe the item'), quantity: z.coerce.number().int().min(1).max(9999),
  net_weight: measure, mass_unit: z.enum(WEIGHT_UNITS),
  value_amount: measure, value_currency: z.string().trim().length(3, '3-letter code').toUpperCase(),
  origin_country: z.string().trim().regex(/^[A-Za-z]{2}$/, 'Two-letter country'), tariff_number: z.string().trim().max(12).optional(),
});
const formSchema = z.object({
  destination: z.enum(['US', 'CA']),
  name: z.string().trim().min(2, 'Enter a name'), company: z.string().trim().optional(),
  street1: z.string().trim().min(2, 'Enter a street address'), street2: z.string().trim().optional(),
  city: z.string().trim().min(1, 'Enter a city'), state: z.string().trim().optional(), zip: z.string().trim().min(1, 'Enter a postal code'),
  phone: z.string().trim().min(3, 'Enter a phone number'), email: z.string().trim().email('Enter a valid email'),
  length: measure, width: measure, height: measure, dimension_unit: z.enum(DIMENSION_UNITS), weight: measure, weight_unit: z.enum(WEIGHT_UNITS),
  contents_type: z.enum(CONTENTS_TYPES).optional(), contents_explanation: z.string().trim().max(200).optional(),
  non_delivery_option: z.enum(NON_DELIVERY).optional(), certify: z.boolean().optional(), certify_signer: z.string().trim().optional(),
  items: z.array(customsItemSchema).optional(),
  incoterm: z.enum(INCOTERMS).optional().or(z.literal('')), eel_pfc: z.enum(EEL_PFC).optional().or(z.literal('')),
  aes_itn: z.string().trim().optional(), b13a_filing_option: z.enum(B13A).optional().or(z.literal('')), b13a_number: z.string().trim().optional(),
});
type FormValues = z.input<typeof formSchema>;

function RateRow({rate, selected, onSelect}: {rate: Rate; selected: boolean; onSelect: () => void}) {
  return (
    <label className={`flex cursor-pointer items-start gap-3 rounded-xl border p-3 transition-colors duration-150 ${selected ? 'border-primary bg-primary-soft/40' : 'border-line hover:border-line-strong'}`}>
      <input type="radio" name="rate" className="mt-1" checked={selected} onChange={onSelect} />
      <div className="min-w-0 flex-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-semibold text-ink">{rate.carrier}</span>
          <span className="text-sm text-muted">{rate.service}</span>
          <span className="ml-auto text-sm font-semibold text-ink">{rate.amount} {rate.currency}</span>
        </div>
        <p className="mt-0.5 text-xs text-muted">
          {rate.estimated_days != null ? `${rate.estimated_days} day${rate.estimated_days === 1 ? '' : 's'} estimated` : 'No delivery estimate returned'}
          {rate.duration_terms ? ` · ${rate.duration_terms}` : ''}
        </p>
      </div>
    </label>
  );
}

function ShipmentCard({shipment, purchases}: {shipment: Shipment; purchases: Purchase[]}) {
  const {name: staff, valid} = useStaff();
  const [selected, setSelected] = React.useState<Rate | null>(null);
  const purchase = useOp<{purchase_id: number; state: string}>('purchase');
  const mine = purchases.filter(p => p.shipment_id === shipment.id);
  const completed = mine.find(p => COMPLETED_STATES.has(p.state));
  const blocking = completed ?? mine.find(p => p.state === 'requested' || p.state === 'unknown');
  return (
    <li className="space-y-3 py-4">
      <div className="flex flex-wrap items-center gap-2 text-xs text-muted">
        <span className="font-mono">#{shipment.id}</span>
        <Badge tone="neutral">{shipment.destination_country === 'CA' ? 'To Canada' : 'To United States'}</Badge>
        {shipment.customs && <Badge tone="info">Customs attached</Badge>}
        <span>{shipment.requested_by}, {formatTimestamp(shipment.requested_at)}</span>
        {completed && <Badge tone="success"><CircleCheckBig aria-hidden />Completed — label purchased</Badge>}
      </div>
      {shipment.messages.length > 0 && (
        <p className="rounded-lg border border-review-line bg-review-soft px-3 py-2 text-xs text-review">
          {shipment.messages.map((m, i) => <span key={i} className="mr-2">{[m.source, m.code, m.text].filter(Boolean).join(': ')}</span>)}
        </p>
      )}
      {completed ? (
        <p className="rounded-lg border border-success-line bg-success-soft px-3 py-2 text-xs text-success">
          This test shipment already has a purchased label (#{completed.id}). It is done and is not purchased again; see the label below.
        </p>
      ) : shipment.rates.length === 0
        ? <p className="text-sm text-muted">No rates were returned for this test shipment.</p>
        : (
          <div className="space-y-2">
            {shipment.rates.map(r => <RateRow key={r.rate_object_id} rate={r} selected={selected?.rate_object_id === r.rate_object_id} onSelect={() => setSelected(r)} />)}
          </div>
        )}
      {!completed && (
        <>
          <ActionMessage error={purchase.error} />
          <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" disabled={!valid || !selected || Boolean(blocking) || purchase.isPending}
              onClick={() => selected && purchase.mutate({staff, shipment_id: shipment.id, rate_object_id: selected.rate_object_id, rate_summary: selected})}>
              <FlaskConical aria-hidden />{purchase.isPending ? 'Purchasing TEST label…' : 'Purchase TEST label for the selected rate'}
            </Button>
            {blocking && <span className="text-xs text-review">A purchase is already {blocking.state} for this test shipment; resolve it below before buying another.</span>}
          </div>
        </>
      )}
      {mine.length > 0 && <ul className="divide-y divide-line border-t border-line pt-2">{mine.map(p => <PurchaseRow key={p.id} purchase={p} />)}</ul>}
    </li>
  );
}

function ResolveForm({purchase}: {purchase: Purchase}) {
  const {name: staff, valid} = useStaff();
  const resolve = useOp('resolve');
  const [outcome, setOutcome] = React.useState('');
  const [evidence, setEvidence] = React.useState('');
  return (
    <div className="mt-2 space-y-2 rounded-lg border border-review-line bg-review-soft px-3 py-2">
      <p className="text-xs text-review">The purchase may or may not have reached Shippo, so it is not retried automatically. Check Shippo's dashboard or support, then record the real outcome.</p>
      <Label htmlFor={`sr-${purchase.id}`}>Outcome</Label>
      <NativeSelect id={`sr-${purchase.id}`} value={outcome} onChange={e => setOutcome(e.target.value)}>
        <option value="" disabled>Choose…</option>
        <option value="confirmed_purchased">Shippo shows it purchased</option>
        <option value="resolved_not_purchased">Shippo shows it was not purchased</option>
      </NativeSelect>
      <Label htmlFor={`sre-${purchase.id}`}>Evidence</Label>
      <Textarea id={`sre-${purchase.id}`} rows={2} value={evidence} onChange={e => setEvidence(e.target.value)} />
      <ActionMessage error={resolve.error} />
      <Button size="sm" disabled={!valid || !outcome || evidence.trim().length < 3 || resolve.isPending}
        onClick={() => resolve.mutate({staff, id: purchase.id, outcome, evidence})}>Record outcome</Button>
    </div>
  );
}

function LabelLine({label, title}: {label: LabelRec; title: string}) {
  return (
    <p className="flex flex-wrap items-center gap-2 text-xs">
      <Badge tone="violet">{title}</Badge>
      <a className="font-medium text-primary underline" href={`/api/shippo-test/labels/${label.id}?inline=1`} target="_blank" rel="noopener">Preview</a>
      <a className="font-medium text-primary underline" href={`/api/shippo-test/labels/${label.id}`}>Download</a>
      <span className="text-muted">{label.content_type}, {label.size_bytes} bytes, fetched {formatTimestamp(label.fetched_at)} · sha256 {label.sha256.slice(0, 12)}…</span>
    </p>
  );
}

function PurchaseRow({purchase}: {purchase: Purchase}) {
  const {name: staff, valid} = useStaff();
  const fetchLabel = useOp<{label_id: number; already_stored: boolean; customs_invoice: {label_id: number} | null}>('fetch-label');
  const recover = useOp<{carrier: string | null; carrier_account_id: string | null; note: string | null}>('recover-details');
  const q = useShippoTest();
  const mine = (q.data?.records?.labels ?? []).filter(l => l.purchase_id === purchase.id);
  const label = mine.find(l => l.kind === 'label');
  const invoice = mine.find(l => l.kind === 'customs_invoice');
  const usable = COMPLETED_STATES.has(purchase.state);
  const missingDetails = purchase.completed_at && (!purchase.carrier || !purchase.carrier_account_id);
  return (
    <li className="py-2">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone={STATE_TONE[purchase.state] ?? 'neutral'}>{STATE_LABEL[purchase.state] ?? purchase.state}</Badge>
        <span className="text-xs text-muted">
          #{purchase.id} · {purchase.carrier ?? purchase.rate_summary.carrier} {purchase.service_level ?? purchase.rate_summary.service} ·{' '}
          {purchase.amount ?? purchase.rate_summary.amount} {purchase.currency ?? purchase.rate_summary.currency}
        </span>
        {purchase.test_mode === true && <Badge tone="info">Shippo test mode confirmed</Badge>}
      </div>
      {purchase.tracking_number && (
        <p className="mt-1 text-xs text-muted">
          Tracking {purchase.tracking_number} ({purchase.carrier ?? 'carrier not recorded'}
          {purchase.carrier_account_id ? `, carrier account ${purchase.carrier_account_id}` : ''})
        </p>
      )}
      {missingDetails && (
        <div className="mt-1 flex flex-wrap items-center gap-2">
          <span className="text-xs text-review">
            {!purchase.carrier ? 'Carrier/service not recorded for this attempt.' : 'Carrier account id not recorded for this attempt.'}
          </span>
          <Button size="sm" variant="outline" disabled={!valid || recover.isPending} onClick={() => recover.mutate({staff, purchase_id: purchase.id})}>
            <RefreshCw aria-hidden className={recover.isPending ? 'animate-spin' : ''} />{recover.isPending ? 'Recovering…' : 'Recover details'}
          </Button>
        </div>
      )}
      <ActionMessage error={recover.error} />
      {recover.data?.note && <p className="mt-1 text-xs text-muted">{recover.data.note}</p>}
      {purchase.error && <p className="mt-1 text-xs text-danger">{purchase.error}</p>}
      {purchase.resolution && <p className="mt-1 text-xs text-muted">Resolved by {purchase.resolved_by}: {purchase.resolution}</p>}
      {purchase.state === 'unknown' && <ResolveForm purchase={purchase} />}
      {usable && (
        <div className="mt-2 space-y-1">
          <Button size="sm" variant="outline" disabled={!valid || fetchLabel.isPending} onClick={() => fetchLabel.mutate({staff, purchase_id: purchase.id})}>
            <Download aria-hidden />{fetchLabel.isPending ? 'Fetching…' : label ? 'Already stored' : 'Fetch and store TEST label'}
          </Button>
          <ActionMessage error={fetchLabel.error} />
          {label && <LabelLine label={label} title="TEST label" />}
          {invoice && <LabelLine label={invoice} title="Customs invoice" />}
          {!invoice && purchase.commercial_invoice_source_url && !label && (
            <p className="text-xs text-muted">Shippo also returned a customs invoice for this purchase; fetching the label above stores it too.</p>
          )}
        </div>
      )}
    </li>
  );
}

function NewShipmentForm({defaultParcel}: {defaultParcel: {length: string; width: string; height: string; dimension_unit: 'in' | 'cm'; weight: string; weight_unit: 'lb' | 'kg' | 'oz' | 'g'} | null}) {
  const {name: staff, valid} = useStaff();
  const rates = useOp<{shipment_id: number; rates: Rate[]; note: string | null}>('rates');
  const form = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: {
      destination: 'US', ...SYNTHETIC_US,
      length: defaultParcel?.length ?? '9', width: defaultParcel?.width ?? '6', height: defaultParcel?.height ?? '6',
      dimension_unit: defaultParcel?.dimension_unit ?? 'in', weight: defaultParcel?.weight ?? '2', weight_unit: defaultParcel?.weight_unit ?? 'kg',
      contents_type: 'MERCHANDISE', non_delivery_option: 'RETURN', certify: false, certify_signer: '', items: [],
    },
  });
  const {errors} = form.formState;
  const destination = form.watch('destination');
  const { fields, append, remove } = useFieldArray({control: form.control, name: 'items'});
  React.useEffect(() => {
    if (!defaultParcel) return;
    form.reset({...form.getValues(), length: defaultParcel.length, width: defaultParcel.width, height: defaultParcel.height,
      dimension_unit: defaultParcel.dimension_unit, weight: defaultParcel.weight, weight_unit: defaultParcel.weight_unit});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [defaultParcel?.length, defaultParcel?.width, defaultParcel?.height, defaultParcel?.dimension_unit, defaultParcel?.weight, defaultParcel?.weight_unit]);

  const applySynthetic = (country: 'US' | 'CA') => {
    const s = country === 'CA' ? SYNTHETIC_CA : SYNTHETIC_US;
    form.setValue('destination', country);
    Object.entries(s).forEach(([k, v]) => form.setValue(k as keyof FormValues, v));
  };

  const submit = form.handleSubmit(async v => {
    const customs = v.destination === 'CA' ? {
      contents_type: v.contents_type!, contents_explanation: v.contents_explanation, non_delivery_option: v.non_delivery_option!,
      certify: v.certify === true, certify_signer: v.certify_signer ?? '', items: v.items ?? [],
      incoterm: v.incoterm || undefined, eel_pfc: v.eel_pfc || undefined, aes_itn: v.aes_itn || undefined,
      b13a_filing_option: v.b13a_filing_option || undefined, b13a_number: v.b13a_number || undefined,
    } : null;
    await rates.mutateAsync({
      staff,
      ship_to: {name: v.name, company: v.company, street1: v.street1, street2: v.street2, city: v.city, state: v.state, zip: v.zip, country: v.destination, phone: v.phone, email: v.email},
      parcel: {length: v.length, width: v.width, height: v.height, dimension_unit: v.dimension_unit, weight: v.weight, weight_unit: v.weight_unit},
      customs,
    });
  });

  const field = (name: keyof FormValues, label: string, props: React.ComponentProps<'input'> = {}) => (
    <div className="space-y-1">
      <Label htmlFor={`st-${name}`}>{label}</Label>
      <Input id={`st-${name}`} aria-invalid={Boolean(errors[name as keyof typeof errors])} {...form.register(name)} {...props} />
      <FieldError message={errors[name as keyof typeof errors]?.message as string | undefined} />
    </div>
  );

  return (
    <div className="space-y-4">
      <div>
        <Label>Destination (this app covers US1 shipments to the US and Canada only)</Label>
        <div className="mt-1 flex gap-2">
          <Button type="button" size="sm" variant={destination === 'US' ? 'secondary' : 'outline'} onClick={() => applySynthetic('US')}>United States</Button>
          <Button type="button" size="sm" variant={destination === 'CA' ? 'secondary' : 'outline'} onClick={() => applySynthetic('CA')}>Canada</Button>
        </div>
      </div>

      <fieldset className="space-y-2 rounded-xl border border-line p-3">
        <legend className="mb-1 flex items-center gap-2 text-xs font-semibold text-ink"><MapPinHouse aria-hidden className="size-3.5" />Synthetic test recipient — never a real customer or OMS order</legend>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {field('name', 'Name')}{field('company', 'Company (optional)')}
          {field('street1', 'Street address')}{field('street2', 'Street address 2 (optional)')}
          {field('city', 'City')}{field('state', `State / province${destination === 'US' || destination === 'CA' ? '' : ' (optional)'}`)}
          {field('zip', 'Postal code')}{field('phone', 'Phone')}
          {field('email', 'Email')}
        </div>
      </fieldset>

      <fieldset className="space-y-2 rounded-xl border border-line p-3">
        <legend className="mb-1 flex items-center gap-2 text-xs font-semibold text-ink"><Package aria-hidden className="size-3.5" />Parcel for this test (starts from the saved Shippo default profile; changes here do not alter the saved profile)</legend>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-6">
          {field('length', `Length (${form.watch('dimension_unit')})`)}
          {field('width', `Width (${form.watch('dimension_unit')})`)}
          {field('height', `Height (${form.watch('dimension_unit')})`)}
          <div className="space-y-1"><Label htmlFor="st-dimension_unit">Unit</Label><NativeSelect id="st-dimension_unit" {...form.register('dimension_unit')}>{DIMENSION_UNITS.map(u => <option key={u} value={u}>{u}</option>)}</NativeSelect></div>
          {field('weight', 'Weight')}
          <div className="space-y-1"><Label htmlFor="st-weight_unit">Unit</Label><NativeSelect id="st-weight_unit" {...form.register('weight_unit')}>{WEIGHT_UNITS.map(u => <option key={u} value={u}>{u}</option>)}</NativeSelect></div>
        </div>
      </fieldset>

      {destination === 'CA' && (
        <fieldset className="space-y-3 rounded-xl border border-review-line bg-review-soft/40 p-3">
          <legend className="mb-1 text-xs font-semibold text-review">Customs declaration — required for Canada. Nothing here is prefilled or invented; enter real test values.</legend>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="st-contents_type">Contents type</Label>
              <NativeSelect id="st-contents_type" {...form.register('contents_type')}>{CONTENTS_TYPES.map(c => <option key={c} value={c}>{c}</option>)}</NativeSelect>
            </div>
            <div className="space-y-1">
              <Label htmlFor="st-non_delivery_option">If undeliverable</Label>
              <NativeSelect id="st-non_delivery_option" {...form.register('non_delivery_option')}>{NON_DELIVERY.map(c => <option key={c} value={c}>{c}</option>)}</NativeSelect>
            </div>
            {form.watch('contents_type') === 'OTHER' && field('contents_explanation', 'Explain contents (required for OTHER)')}
            {field('certify_signer', 'Certifying signer (name)')}
          </div>
          <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" {...form.register('certify')} />I certify the customs information given is accurate</label>
          <div className="space-y-2">
            {fields.map((f, i) => (
              <div key={f.id} className="grid grid-cols-2 gap-2 rounded-lg border border-line bg-surface p-2 sm:grid-cols-4">
                <Input placeholder="Description" {...form.register(`items.${i}.description`)} />
                <Input placeholder="Qty" inputMode="numeric" {...form.register(`items.${i}.quantity`)} />
                <Input placeholder="Net weight" inputMode="decimal" {...form.register(`items.${i}.net_weight`)} />
                <NativeSelect {...form.register(`items.${i}.mass_unit`)}>{WEIGHT_UNITS.map(u => <option key={u} value={u}>{u}</option>)}</NativeSelect>
                <Input placeholder="Value amount" inputMode="decimal" {...form.register(`items.${i}.value_amount`)} />
                <Input placeholder="Value currency (USD)" {...form.register(`items.${i}.value_currency`)} />
                <Input placeholder="Origin country (US)" {...form.register(`items.${i}.origin_country`)} />
                <div className="flex gap-1"><Input placeholder="Tariff # (optional)" {...form.register(`items.${i}.tariff_number`)} />
                  <Button type="button" size="icon-sm" variant="ghost" onClick={() => remove(i)}><Trash2 aria-hidden /></Button>
                </div>
              </div>
            ))}
            <Button type="button" size="sm" variant="outline" onClick={() => append({description: '', quantity: 1, net_weight: '', mass_unit: 'kg', value_amount: '', value_currency: 'USD', origin_country: 'US', tariff_number: ''})}>
              <Plus aria-hidden />Add customs item
            </Button>
          </div>
        </fieldset>
      )}

      {destination === 'CA' && (
        <fieldset className="space-y-2 rounded-xl border border-line p-3">
          <legend className="mb-1 text-xs font-semibold text-ink">Export compliance (optional) — nothing here is chosen for you; pick one if your carrier needs it, or leave it blank and let Shippo say so</legend>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="space-y-1">
              <Label htmlFor="st-incoterm">Incoterm</Label>
              <NativeSelect id="st-incoterm" {...form.register('incoterm')}>
                <option value="">Not set</option>
                {INCOTERMS.map(c => <option key={c} value={c}>{c}</option>)}
              </NativeSelect>
            </div>
            <div className="space-y-1">
              <Label htmlFor="st-eel_pfc">EEL/PFC</Label>
              <NativeSelect id="st-eel_pfc" {...form.register('eel_pfc')}>
                <option value="">Not set</option>
                {EEL_PFC.map(c => <option key={c} value={c}>{c}{c === 'NOEEI_30_36' ? ' (Shippo: typical for most US → CA shipments)' : ''}</option>)}
              </NativeSelect>
            </div>
            {form.watch('eel_pfc') === 'AES_ITN' && field('aes_itn', 'AES ITN (required for this EEL/PFC choice)')}
            <div className="space-y-1">
              <Label htmlFor="st-b13a_filing_option">B13A filing</Label>
              <NativeSelect id="st-b13a_filing_option" {...form.register('b13a_filing_option')}>
                <option value="">Not set</option>
                {B13A.map(c => <option key={c} value={c}>{c}</option>)}
              </NativeSelect>
            </div>
            {form.watch('b13a_filing_option') && field('b13a_number', 'B13A number (required for this filing option)')}
          </div>
        </fieldset>
      )}

      <ActionMessage error={rates.error} />
      {rates.data?.note && <p role="status" className="rounded-lg border border-review-line bg-review-soft px-3 py-2 text-xs text-review">{rates.data.note}</p>}
      <Button disabled={!valid || rates.isPending} onClick={submit}>
        <PackageSearch aria-hidden />{rates.isPending ? 'Getting test rates…' : 'Get test rates'}
      </Button>
    </div>
  );
}

function LabelFormatControl({current}: {current: string | null}) {
  const {name: staff, valid} = useStaff();
  const setFormat = useOp<{label_file_type: string | null}>('set-label-format');
  const [value, setValue] = React.useState(current ?? '');
  React.useEffect(() => setValue(current ?? ''), [current]);
  return (
    <div className="flex flex-wrap items-end gap-2">
      <div className="space-y-1">
        <Label htmlFor="shippo-label-format">Label print format (applies to future purchases only)</Label>
        <NativeSelect id="shippo-label-format" className="w-64" value={value} onChange={e => setValue(e.target.value)}>
          <option value="">Shippo dashboard default (current: {current ?? 'not sent — dashboard decides'})</option>
          {LABEL_FILE_TYPES.map(f => <option key={f} value={f}>{f}</option>)}
        </NativeSelect>
      </div>
      <Button size="sm" variant="outline" disabled={!valid || setFormat.isPending || value === (current ?? '')}
        onClick={() => setFormat.mutate({staff, label_file_type: value || null})}>
        {setFormat.isPending ? 'Saving…' : 'Save'}
      </Button>
      <ActionMessage error={setFormat.error} />
    </div>
  );
}

export function ShippoTest() {
  const q = useShippoTest();
  const auth = useOp<Check>('auth');
  const profiles = usePackageProfiles();
  if (q.isPending) return <div className="space-y-4" aria-busy="true"><Skeleton className="h-16 rounded-xl" /><Skeleton className="h-64 rounded-2xl" /></div>;
  if (q.isError && !q.data) return <Card><ErrorState title="Shippo test status could not be loaded" message={q.error.message} onRetry={() => q.refetch()} retrying={q.isFetching} /></Card>;
  const s = q.data!;
  const c = s.config;
  const assignment = profiles.data?.assignments.find(a => a.assignment === 'us1_shippo');
  const profile = assignment?.profile_id ? profiles.data?.profiles.find(p => p.id === assignment.profile_id) : undefined;
  const version = profile?.versions.find(v => v.version === profile.current_version);
  const defaultParcel = version ? {
    length: String(version.length), width: String(version.width), height: String(version.height), dimension_unit: version.dimension_unit,
    weight: version.packed_weight != null ? String(version.packed_weight) : '2', weight_unit: version.packed_weight_unit ?? 'kg',
  } : null;
  const shipments = s.records?.shipments ?? [];
  const purchases = s.records?.purchases ?? [];
  const caTested = purchases.some(p => (p.state === 'succeeded' || p.state === 'confirmed_purchased')
    && shipments.find(sh => sh.id === p.shipment_id)?.destination_country === 'CA');

  return (
    <div className="space-y-5">
      <div role="note" className="flex items-start gap-3 rounded-xl bg-info px-4 py-3 text-sm text-white">
        <FlaskConical aria-hidden className="mt-0.5 size-4 shrink-0" />
        <p><span className="font-semibold">Shippo TEST mode.</span> Synthetic recipients and TEST labels only, kept apart from live orders. Nothing here imports Shopify/eBay orders, updates the review queue,
          parcels or readiness, or updates any marketplace fulfilment. Live booking stays {s.live_booking_enabled ? 'ON (check .env)' : 'off'}.</p>
      </div>
      <StaffBar />
      <Card className="space-y-3 p-5">
        <div className="flex items-center gap-3"><IconTile icon={ShieldAlert} tone="info" size="sm" /><h2 className="text-sm font-semibold">Shippo integration status</h2></div>
        <StatusRow icon={Settings2} title="Configuration" state={c.usable ? 'ok' : 'fail'}
          detail={<>
            Mode {c.mode || 'not set'} · API token {c.token_set ? (c.token_is_test ? 'set (test token)' : 'set (NOT a test token)') : 'missing'} ·
            ship-from {c.ship_from ? `${c.ship_from.city}, ${c.ship_from.state ?? ''} ${c.ship_from.country}`.trim() : 'not configured'}
            {c.mock ? ' · LOCAL MOCK (test instance)' : ''}
            {c.problems.length > 0 && <span className="block text-danger">{c.problems.join('; ')}</span>}
          </>} />
        <StatusRow icon={KeyRound} title="Authentication" state={s.auth ? (s.auth.ok ? 'ok' : 'fail') : 'none'}
          detail={s.auth ? `${s.auth.detail} · ${formatTimestamp(s.auth.at)}` : 'No token check run since the server started.'} />
        <StatusRow icon={Undo2Icon} title="Return address" state={c.ship_return ? 'ok' : c.return_address_configured ? 'fail' : 'none'}
          detail={c.ship_return
            ? <>Explicitly set: {c.ship_return.city}, {c.ship_return.state ?? ''} {c.ship_return.country} — sent as <code>address_return</code> on every rate request.</>
            : c.return_address_configured
              ? 'SHIPPO_SHIP_RETURN_* is partially set; complete it or clear it entirely.'
              : <>Not configured. This account has a different default sender and return address; Shippo does not document what happens to returns when
                  <code> address_return</code> is omitted, so this app sends none and assumes neither the ship-from address above nor your dashboard return
                  address applies. Set SHIPPO_SHIP_RETURN_* in .env, or check the Shippo dashboard for what a return label would actually use.</>} />
        <p className="text-xs text-muted">Canada customs: {caTested ? 'tested with a successful test purchase' : 'not yet tested'}. Rate shopping and label purchase use SHIPPO_API_TOKEN directly; this status never calls Shippo on page load.</p>
        <div className="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" disabled={!c.usable || auth.isPending} onClick={() => auth.mutate({})}><KeyRound aria-hidden />{auth.isPending ? 'Checking token…' : 'Test authentication'}</Button>
        </div>
        <ActionMessage error={auth.error} />
        <div className="border-t border-line pt-3">
          <LabelFormatControl current={s.label_format} />
          <p className="mt-1 text-xs text-muted">Our printer model and paper size are not confirmed, so this is never assumed to be a thermal format. Leaving it on the dashboard default
            changes nothing here; choosing PDF_4x6, PDF_A4 or another format applies to purchases made after saving. Labels already stored are never regenerated.</p>
        </div>
      </Card>

      <Card className="p-5">
        <div className="mb-3 flex items-center gap-3"><IconTile icon={PackageSearch} tone="primary" size="sm" /><h2 className="text-sm font-semibold">New test shipment: get rates</h2></div>
        {!c.ship_from && <p className="mb-3 rounded-lg border border-danger-line bg-danger-soft px-3 py-2 text-xs text-danger">Configure SHIPPO_SHIP_FROM_* in .env before requesting rates; the ship-from address is never guessed.</p>}
        <NewShipmentForm defaultParcel={defaultParcel} />
      </Card>

      <Card className="p-5">
        <div className="mb-3 flex items-center gap-3"><IconTile icon={FlaskConical} tone="info" size="sm" /><h2 className="text-sm font-semibold">Test shipments, purchases and labels</h2></div>
        <p className="mb-2 text-xs text-muted">Select a rate explicitly; the cheapest is never chosen automatically. Preview and download open the stored original file; neither purchases another label.</p>
        {shipments.length ? <ul className="divide-y divide-line">{shipments.map(sh => <ShipmentCard key={sh.id} shipment={sh} purchases={purchases} />)}</ul>
          : <p className="text-sm text-muted">No test shipments yet.</p>}
      </Card>
    </div>
  );
}
