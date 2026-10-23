'use client';

// Settings → Wayfair Sandbox. Every Wayfair call is an explicit button press; the page itself only
// reads local status. Results are sandbox data: they are listed here only and are never linked to
// live orders, parcels or readiness (the OMS stays the only source of orders).
import * as React from 'react';
import {useMutation, useQuery, useQueryClient} from '@tanstack/react-query';
import {useForm} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z} from 'zod';
import {CircleCheck, CircleX, Download, FileText, FlaskConical, KeyRound, ListOrdered, Search, Settings2, ShieldAlert} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Input} from '@/client/components/ui/input';
import {Skeleton} from '@/client/components/ui/skeleton';
import {FieldError, Label, NativeSelect, Textarea} from '@/client/components/ui/field';
import {ActionMessage, ErrorState, IconTile} from '@/client/components/bits';
import {ApiError} from '@/client/lib/api';
import {StaffBar, useStaff} from '@/client/lib/staff';
import {formatTimestamp} from '@/client/lib/format';
import {measure} from '@/shared/actions';

interface Check {ok: boolean; at: string; detail: string; expires_at?: string | null; count?: number | null}
interface Registration {
  id: number; po_number: string; supplier_id: string | null; warehouse_id: string | null; state: string; source: string;
  request_summary: {warehouse_id?: string | null; package_units?: unknown[] | null} | null;
  response_summary: {event_id?: string | null; pickup_date?: string | null; tracking?: Array<{carrier: string | null; tracking_number: string | null}>;
                     documents?: Record<string, boolean>} | null;
  error: string | null; requested_by: string; requested_at: string; resolved_by: string | null; resolution: string | null;
}
interface Label {id: number; registration_id: number; po_number: string; content_type: string; file_name: string; size_bytes: number; sha256: string; fetched_by: string; fetched_at: string}
interface Status {
  config: {mode: string; client_id_set: boolean; client_secret_set: boolean; supplier_id: string | null; warehouse_id: string | null;
           order_import_enabled: boolean; mock: boolean; problems: string[]; usable: boolean};
  auth: Check | null;
  orders: Check | null;
  live_booking_enabled: boolean;
  records: {registrations: Registration[]; labels: Label[]} | null;
  error?: string;
}
interface SandboxOrder {po_number: string; po_date: string | null; supplier_id: string | null; account_match: string; products: Array<{part_number: string; quantity: number}>; also_in_oms: boolean; oms_refs: string[]}

async function post<T>(op: string, body: unknown): Promise<T> {
  const res = await fetch(`/api/wayfair-sandbox/${op}`, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)})
    .catch(() => { throw new ApiError('The local server is not reachable', 0); });
  const json = await res.json().catch(() => null);
  if (!res.ok) throw new ApiError(json?.error ?? `Request failed (${res.status})`, res.status);
  return json.result as T;
}
function useSandbox() {
  return useQuery({
    queryKey: ['wayfair-sandbox'],
    queryFn: async (): Promise<Status> => {
      const res = await fetch('/api/wayfair-sandbox', {cache: 'no-store'});
      const json = await res.json().catch(() => null);
      if (!json?.config) throw new ApiError(json?.error ?? `Request failed (${res.status})`, res.status);
      return json;
    },
  });
}
function useOp<T>(op: string) {
  const qc = useQueryClient();
  return useMutation({mutationFn: (body: unknown) => post<T>(op, body), onSettled: () => qc.invalidateQueries({queryKey: ['wayfair-sandbox']})});
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
  succeeded: 'success', found_existing: 'info', failed: 'danger', unknown: 'review', requested: 'review', resolved_not_registered: 'neutral',
};
const STATE_LABEL: Record<string, string> = {
  succeeded: 'Registered', found_existing: 'Already registered at Wayfair', failed: 'Failed', unknown: 'Outcome unknown',
  requested: 'In flight', resolved_not_registered: 'Resolved: not registered',
};

const pkgSchema = z.object({length: measure, width: measure, height: measure, weight: measure});

function RegisterForm({order, onDone}: {order: SandboxOrder; onDone: () => void}) {
  const {name: staff} = useStaff();
  const reg = useOp<{result: string; error?: string | null}>('register');
  const [withPkg, setWithPkg] = React.useState(false);
  const form = useForm<z.input<typeof pkgSchema>>({resolver: zodResolver(pkgSchema), defaultValues: {length: '', width: '', height: '', weight: ''}});
  const {errors} = form.formState;
  const submit = async (pkg: z.input<typeof pkgSchema> | null) => {
    const r = await reg.mutateAsync({staff, po_number: order.po_number, package: pkg});
    if (r.result === 'succeeded' || r.result === 'existing') onDone();
  };
  const field = (f: 'length' | 'width' | 'height' | 'weight', label: string) => (
    <div className="space-y-1">
      <Label htmlFor={`wf-${order.po_number}-${f}`}>{label}</Label>
      <Input id={`wf-${order.po_number}-${f}`} inputMode="decimal" aria-invalid={Boolean(errors[f])} {...form.register(f)} />
      <FieldError message={errors[f]?.message} />
    </div>
  );
  return (
    <div className="mt-2 space-y-3 rounded-xl border border-violet-line bg-violet-soft/40 p-3">
      <p className="text-xs text-muted">
        Registers sandbox PO <span className="font-mono">{order.po_number}</span> with Wayfair&apos;s sandbox. Wayfair is asked first whether it is already
        registered, and a PO registered here (or with an unknown outcome) is never registered again. Normally the PO is registered with
        Wayfair-managed packaging: no package units are sent and Wayfair uses the package data it holds. Send package units only as an exception.
      </p>
      <label className="inline-flex items-center gap-2 text-sm"><input type="checkbox" checked={withPkg} onChange={e => setWithPkg(e.target.checked)} />Packaging exception: send package units (consolidated or custom packaging, cm and kg)</label>
      {withPkg && (
        <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <legend className="mb-1 text-xs font-semibold text-ink">One carton holding every ordered unit</legend>
          {field('length', 'Length (cm)')}{field('width', 'Width (cm)')}{field('height', 'Height (cm)')}{field('weight', 'Weight (kg)')}
        </fieldset>
      )}
      <ActionMessage error={reg.error} />
      {reg.data && reg.data.result !== 'succeeded' && reg.data.result !== 'existing' && (
        <p role="status" className="text-xs font-medium text-review">Result: {STATE_LABEL[reg.data.result] ?? reg.data.result}{reg.data.error ? `: ${reg.data.error}` : ''}</p>
      )}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" disabled={reg.isPending} onClick={withPkg ? form.handleSubmit(v => submit(v)) : () => submit(null)}>
          {reg.isPending ? 'Registering (up to 20 s)…' : 'Register in sandbox'}
        </Button>
        <Button size="sm" variant="ghost" onClick={onDone}>Cancel</Button>
      </div>
    </div>
  );
}

function OrderRow({order}: {order: SandboxOrder}) {
  const {valid} = useStaff();
  const [registering, setRegistering] = React.useState(false);
  const check = useOp<{events_returned: number; matching: unknown[]; note: string | null}>('check-registration');
  return (
    <li className="py-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm font-semibold text-ink">{order.po_number}</span>
        <Badge tone={order.account_match === 'mismatch' ? 'danger' : order.account_match === 'not_configured' ? 'review' : 'success'}>
          {order.account_match === 'supplier' ? 'Supplier matches' : order.account_match === 'warehouse' ? 'Warehouse id matches'
            : order.account_match === 'mismatch' ? `Supplier ${order.supplier_id} not ours` : `Supplier ${order.supplier_id ?? '?'} (not verified)`}
        </Badge>
        {order.also_in_oms && <Badge tone="info">Possibly OMS order {order.oms_refs.join(', ')}: not linked</Badge>}
        <span className="text-xs text-muted">{order.po_date ?? ''}</span>
      </div>
      <p className="mt-1 text-xs text-muted">{order.products.map(p => `${p.part_number} × ${p.quantity}`).join(', ') || 'no products'}</p>
      <div className="mt-2 flex flex-wrap gap-2">
        <Button size="sm" variant="outline" disabled={check.isPending} onClick={() => check.mutate({po_number: order.po_number})}>
          <Search aria-hidden />{check.isPending ? 'Checking…' : 'Check registration at Wayfair'}
        </Button>
        {!registering && (
          <Button size="sm" variant="outline" disabled={!valid || order.account_match === 'mismatch'} onClick={() => setRegistering(true)}>
            <FlaskConical aria-hidden />Register in sandbox…
          </Button>
        )}
      </div>
      <ActionMessage error={check.error} />
      {check.data && (
        <p role="status" className="mt-1 text-xs text-muted">
          {check.data.matching.length ? 'Wayfair has a registration for this PO.' : 'Wayfair returned no registration for this PO.'}
          {check.data.note ? ` ${check.data.note}` : ''}
        </p>
      )}
      {registering && <RegisterForm order={order} onDone={() => setRegistering(false)} />}
    </li>
  );
}

function ResolveForm({reg}: {reg: Registration}) {
  const {name: staff, valid} = useStaff();
  const resolve = useOp('resolve');
  const [outcome, setOutcome] = React.useState('');
  const [evidence, setEvidence] = React.useState('');
  return (
    <div className="mt-2 space-y-2 rounded-lg border border-review-line bg-review-soft px-3 py-2">
      <p className="text-xs text-review">The registration request may or may not have reached Wayfair, so it is not repeated automatically. Find out (Check registration, Wayfair support) and record the outcome.</p>
      <div className="grid gap-2 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor={`rs-${reg.id}`}>Outcome</Label>
          <NativeSelect id={`rs-${reg.id}`} value={outcome} onChange={e => setOutcome(e.target.value)}>
            <option value="" disabled>Choose…</option>
            <option value="found_existing">Wayfair has it registered</option>
            <option value="resolved_not_registered">Wayfair did not register it</option>
          </NativeSelect>
        </div>
      </div>
      <Label htmlFor={`rse-${reg.id}`}>Evidence</Label>
      <Textarea id={`rse-${reg.id}`} rows={2} value={evidence} onChange={e => setEvidence(e.target.value)} />
      <ActionMessage error={resolve.error} />
      <Button size="sm" disabled={!valid || !outcome || evidence.trim().length < 3 || resolve.isPending}
        onClick={() => resolve.mutate({staff, id: reg.id, outcome, evidence})}>Record outcome</Button>
    </div>
  );
}

function RegistrationRow({reg, labels}: {reg: Registration; labels: Label[]}) {
  const {name: staff, valid} = useStaff();
  const fetchLabel = useOp<{label_id: number}>('fetch-label');
  const mine = labels.filter(l => l.registration_id === reg.id);
  const rs = reg.response_summary;
  return (
    <li className="py-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-mono text-sm font-semibold text-ink">{reg.po_number}</span>
        <Badge tone={STATE_TONE[reg.state] ?? 'neutral'}>{STATE_LABEL[reg.state] ?? reg.state}</Badge>
        <span className="text-xs text-muted">#{reg.id} · {reg.requested_by}, {formatTimestamp(reg.requested_at)}{reg.source === 'lookup' ? ' · found by lookup' : ''}</span>
      </div>
      <p className="mt-1 text-xs text-muted">
        {reg.source === 'lookup' ? 'Registered outside this app.'
          : reg.request_summary?.package_units ? 'Packaging exception: package units were sent.'
          : 'Wayfair-managed packaging: no package units sent.'}{' '}
        Package details not returned to this app.
      </p>
      {rs && (
        <p className="mt-1 text-xs text-muted">
          {rs.event_id ? `Event ${rs.event_id}` : ''}{rs.pickup_date ? ` · pickup ${rs.pickup_date}` : ''}
          {rs.tracking?.length ? ` · tracking ${rs.tracking.map(t => `${t.carrier ?? ''} ${t.tracking_number ?? ''}`.trim()).join(', ')}` : ''}
          {rs.documents ? ` · documents: ${Object.entries(rs.documents).filter(([, v]) => v).map(([k]) => k.replace('_', ' ')).join(', ') || 'none listed'}` : ''}
        </p>
      )}
      {reg.error && <p className="mt-1 text-xs text-danger">{reg.error}</p>}
      {reg.resolution && <p className="mt-1 text-xs text-muted">Resolved by {reg.resolved_by}: {reg.resolution}</p>}
      {reg.state === 'unknown' && <ResolveForm reg={reg} />}
      {(reg.state === 'succeeded' || reg.state === 'found_existing') && (
        <div className="mt-2 space-y-1">
          <Button size="sm" variant="outline" disabled={!valid || fetchLabel.isPending} onClick={() => fetchLabel.mutate({staff, registration_id: reg.id})}>
            <Download aria-hidden />{fetchLabel.isPending ? 'Downloading…' : mine.length ? 'Download a fresh copy from Wayfair' : 'Fetch sandbox label'}
          </Button>
          <ActionMessage error={fetchLabel.error} />
          {mine.map(l => (
            <p key={l.id} className="flex flex-wrap items-center gap-2 text-xs">
              <Badge tone="violet">SANDBOX label</Badge>
              <a className="font-medium text-primary underline" href={`/api/wayfair-sandbox/labels/${l.id}?inline=1`} target="_blank" rel="noopener">Preview</a>
              <a className="font-medium text-primary underline" href={`/api/wayfair-sandbox/labels/${l.id}`}>Download</a>
              <span className="text-muted">{l.content_type}, {l.size_bytes} bytes, fetched {formatTimestamp(l.fetched_at)} · sha256 {l.sha256.slice(0, 12)}…</span>
            </p>
          ))}
        </div>
      )}
    </li>
  );
}

export function WayfairSandbox() {
  const q = useSandbox();
  const auth = useOp<Check>('auth');
  const lookup = useOp<{orders: SandboxOrder[]; note: string | null}>('orders');
  const [hasResponse, setHasResponse] = React.useState('false');
  const [limit, setLimit] = React.useState('5');
  if (q.isPending) return <div className="space-y-4" aria-busy="true"><Skeleton className="h-16 rounded-xl" /><Skeleton className="h-64 rounded-2xl" /></div>;
  if (q.isError && !q.data) return <Card><ErrorState title="Wayfair sandbox status could not be loaded" message={q.error.message} onRetry={() => q.refetch()} retrying={q.isFetching} /></Card>;
  const s = q.data!;
  const c = s.config;
  return (
    <div className="space-y-5">
      <div role="note" className="flex items-start gap-3 rounded-xl bg-violet px-4 py-3 text-sm text-white">
        <FlaskConical aria-hidden className="mt-0.5 size-4 shrink-0" />
        <p><span className="font-semibold">Wayfair SANDBOX.</span> Test data from Wayfair&apos;s sandbox, kept apart from live orders. Nothing here imports orders, changes the review queue,
          parcels or readiness, sends shipment notices, updates inventory or prints labels. Live booking stays {s.live_booking_enabled ? 'ON (check .env)' : 'off'}.</p>
      </div>
      <StaffBar />
      <Card className="space-y-3 p-5">
        <div className="flex items-center gap-3"><IconTile icon={ShieldAlert} tone="violet" size="sm" /><h2 className="text-sm font-semibold">Wayfair integration status</h2></div>
        <StatusRow icon={Settings2} title="Configuration" state={c.usable ? 'ok' : 'fail'}
          detail={<>
            Mode {c.mode || 'not set'} · client id {c.client_id_set ? 'set' : 'missing'} · client secret {c.client_secret_set ? 'set' : 'missing'} ·
            supplier id {c.supplier_id ?? 'not set'} · Wayfair warehouse id {c.warehouse_id ?? 'not set (Wayfair uses the PO\'s warehouse)'} ·
            order import {c.order_import_enabled ? 'ON (not supported)' : 'off (orders come from the OMS)'}{c.mock ? ' · LOCAL MOCK (test instance)' : ''}
            {c.problems.length > 0 && <span className="block text-danger">{c.problems.join('; ')}</span>}
            {c.usable && !c.supplier_id && <span className="block text-review">Set WAYFAIR_SUPPLIER_ID to verify orders belong to our account; registration is refused until then.</span>}
          </>} />
        <StatusRow icon={KeyRound} title="Authentication" state={s.auth ? (s.auth.ok ? 'ok' : 'fail') : 'none'}
          detail={s.auth ? `${s.auth.detail} · ${formatTimestamp(s.auth.at)}${s.auth.expires_at ? ` · token valid until ${formatTimestamp(s.auth.expires_at)}` : ''}` : 'No token requested since the server started.'} />
        <StatusRow icon={ListOrdered} title="Order access" state={s.orders ? (s.orders.ok ? 'ok' : 'fail') : 'none'}
          detail={s.orders ? `${s.orders.detail} · ${formatTimestamp(s.orders.at)}` : 'No sandbox orders looked up since the server started.'} />
        <p className="text-xs text-muted">Label access is shown per registration below; neither authentication nor an order list proves it. Sandbox success never marks the live Wayfair route verified.</p>
        <div className="flex flex-wrap gap-2">
          <Button size="sm" variant="outline" disabled={!c.usable || auth.isPending} onClick={() => auth.mutate({})}><KeyRound aria-hidden />{auth.isPending ? 'Requesting token…' : 'Test authentication'}</Button>
        </div>
        <ActionMessage error={auth.error} />
      </Card>

      <Card className="p-5">
        <div className="mb-3 flex items-center gap-3"><IconTile icon={ListOrdered} tone="primary" size="sm" /><h2 className="text-sm font-semibold">Sandbox purchase orders</h2></div>
        <div className="flex flex-wrap items-end gap-3">
          <div className="space-y-1">
            <Label htmlFor="wf-has">Orders</Label>
            <NativeSelect id="wf-has" value={hasResponse} onChange={e => setHasResponse(e.target.value)} className="w-56">
              <option value="false">Open (no response sent yet)</option>
              <option value="true">Already accepted</option>
              <option value="any">Any</option>
            </NativeSelect>
          </div>
          <div className="space-y-1">
            <Label htmlFor="wf-limit">How many</Label>
            <NativeSelect id="wf-limit" value={limit} onChange={e => setLimit(e.target.value)} className="w-24">
              {['1', '5', '10'].map(n => <option key={n} value={n}>{n}</option>)}
            </NativeSelect>
          </div>
          <Button size="sm" disabled={!c.usable || lookup.isPending}
            onClick={() => lookup.mutate({limit: Number(limit), has_response: hasResponse === 'any' ? null : hasResponse === 'true'})}>
            <Search aria-hidden />{lookup.isPending ? 'Looking up…' : 'Look up sandbox orders'}
          </Button>
        </div>
        <p className="mt-2 text-xs text-muted">Only PO numbers, dates, supplier ids and part numbers are requested; no customer names or addresses. Results are not saved.</p>
        <ActionMessage error={lookup.error} />
        {lookup.data?.note && <p role="status" className="mt-2 rounded-lg border border-review-line bg-review-soft px-3 py-2 text-xs text-review">{lookup.data.note}</p>}
        {lookup.data && lookup.data.orders.length > 0 && <ul className="mt-2 divide-y divide-line">{lookup.data.orders.map(o => <OrderRow key={o.po_number} order={o} />)}</ul>}
      </Card>

      <Card className="p-5">
        <div className="mb-3 flex items-center gap-3"><IconTile icon={FileText} tone="violet" size="sm" /><h2 className="text-sm font-semibold">Sandbox registrations and labels</h2></div>
        <p className="mb-2 text-xs text-muted">Wayfair documents that sandbox labels are often static example files. Wait about 15 minutes after registering before fetching a label.
          Preview and download open the stored original file; neither contacts Wayfair or registers again. The number of pages in a label file is not a carton count.</p>
        {s.records?.registrations.length
          ? <ul className="divide-y divide-line">{s.records.registrations.map(r => <RegistrationRow key={r.id} reg={r} labels={s.records!.labels} />)}</ul>
          : <p className="text-sm text-muted">No sandbox registrations yet.</p>}
      </Card>
    </div>
  );
}
