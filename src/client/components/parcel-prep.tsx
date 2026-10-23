'use client';

// Parcel preparation in the order drawer: draft parcels, measurements with their source (default
// profile or staff-entered), and contents allocated from the ordered lines. Every change is a staff
// action checked by the database (allocation limits, purchase/label locks, stale edits).
import * as React from 'react';
import Link from 'next/link';
import {useForm} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z} from 'zod';
import {motion} from 'motion/react';
import {
  AlertTriangle, Boxes, CircleCheck, Info, Lock, PackageOpen, PackagePlus, Pencil, RotateCcw, Ruler, Scale, Settings2, Trash2, Undo2,
} from 'lucide-react';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Input} from '@/client/components/ui/input';
import {FieldError, Label, NativeSelect, Textarea} from '@/client/components/ui/field';
import {ActionMessage, Section} from '@/client/components/bits';
import {useAction} from '@/client/lib/api';
import {useStaff} from '@/client/lib/staff';
import {formatDimensions, formatMeasure, formatWeight, unitLabel} from '@/client/lib/domain';
import {formatTimestamp} from '@/client/lib/format';
import {DIMENSION_UNITS, measure, WEIGHT_UNITS} from '@/shared/actions';
import type {ContentsChange, DetailLine, DetailParcel, GroupDetail, ProfileVersion} from '@/shared/types';

// Units a line can still take: none once the OMS no longer returns it.
const openUnits = (l: DetailLine) => (l.absent_from_oms_since ? 0 : l.quantity_ordered - l.allocated_qty);

function profileSummary(v: ProfileVersion): string {
  const dims = formatDimensions(v.length, v.width, v.height, v.dimension_unit);
  return v.packed_weight != null ? `${dims} · ${formatWeight(v.packed_weight, v.packed_weight_unit)} total packed weight` : `${dims} · no default weight`;
}

function DefaultNote({detail}: {detail: GroupDetail}) {
  const d = detail.package_default;
  return (
    <div className="flex items-start gap-2 rounded-xl border border-teal-line bg-teal-soft px-3 py-2 text-xs text-teal-strong">
      <Boxes aria-hidden className="mt-0.5 size-3.5 shrink-0" />
      {d ? (
        <p>
          New parcels start with <span className="font-semibold">{d.profile_name}</span> (version {d.values.version}): {profileSummary(d.values)}.
          Change values only when the actual package differs.
        </p>
      ) : (
        <p>
          No default package profile is assigned to this route, so each parcel needs its dimensions and weight entered.{' '}
          <Link href="/settings/package-profiles" className="font-semibold underline">Set defaults in Settings → Package Profiles</Link>.
        </p>
      )}
    </div>
  );
}

function AllocationTable({detail}: {detail: GroupDetail}) {
  const multi = detail.orders.length > 1;
  const refOf = (id: number) => detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id);
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <caption className="sr-only">Ordered units and how many are already in parcels</caption>
        <thead>
          <tr className="text-left text-xs font-semibold uppercase tracking-wide text-muted">
            <th scope="col" className="pb-2 pr-3">Ordered SKU</th>
            {multi && <th scope="col" className="pb-2 pr-3">Order</th>}
            <th scope="col" className="pb-2 pr-3 text-right">Ordered</th>
            <th scope="col" className="pb-2 pr-3 text-right">In parcels</th>
            <th scope="col" className="pb-2 text-right"><span className="sm:hidden">Left</span><span className="hidden sm:inline">Remaining</span></th>
          </tr>
        </thead>
        <tbody>
          {detail.lines.map(l => {
            const remaining = openUnits(l);
            return (
              <tr key={l.oms_order_item_id} className="border-t border-line">
                <td className="py-2 pr-3 font-mono text-[13px] text-ink break-all">
                  {l.item_sku}
                  {l.absent_from_oms_since && <span className="block font-sans text-xs font-medium text-danger">No longer in the OMS</span>}
                </td>
                {multi && <td className="py-2 pr-3 font-mono text-xs text-muted">{refOf(l.oms_order_id)}</td>}
                <td className="py-2 pr-3 text-right tabular-nums">{l.quantity_ordered}</td>
                <td className="py-2 pr-3 text-right tabular-nums">{l.allocated_qty}</td>
                <td className={`py-2 text-right font-semibold tabular-nums ${remaining < 0 || (l.absent_from_oms_since && l.allocated_qty > 0) ? 'text-danger' : remaining > 0 ? 'text-review' : 'text-success'}`}>
                  {l.absent_from_oms_since ? (l.allocated_qty > 0 ? `Remove ${l.allocated_qty}` : '0') : remaining < 0 ? `Over by ${-remaining}` : remaining}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function SourceBadge({source}: {source: DetailParcel['dimensions_source']}) {
  if (source === 'profile') return <Badge tone="teal"><Boxes aria-hidden />Default profile</Badge>;
  if (source === 'staff') return <Badge tone="violet"><Pencil aria-hidden />Custom</Badge>;
  return <Badge tone="review">Not entered</Badge>;
}

function MeasureRow({icon: Icon, label, value, source, parcel}: {icon: typeof Ruler; label: string; value: string; source: DetailParcel['dimensions_source']; parcel: DetailParcel}) {
  return (
    <div className="rounded-lg bg-canvas px-3 py-2">
      <dt className="flex items-center gap-1.5 text-xs text-muted"><Icon aria-hidden className="size-3.5" />{label}</dt>
      <dd className="mt-1 flex flex-wrap items-center gap-2">
        <span className="font-semibold tabular-nums text-ink">{value}</span>
        <SourceBadge source={source} />
      </dd>
      <dd className="mt-0.5 text-xs text-muted">
        {source === 'profile' && parcel.profile ? `From ${parcel.profile.name}, version ${parcel.profile.values.version}`
          : source === 'staff' ? `Entered by ${parcel.measured_by}, ${formatTimestamp(parcel.measured_at)}` : 'Needed before booking'}
      </dd>
    </div>
  );
}

const measureSchema = z.object({
  length: measure, width: measure, height: measure, dimension_unit: z.enum(DIMENSION_UNITS, {message: 'Choose a unit'}),
  weight: measure, weight_unit: z.enum(WEIGHT_UNITS, {message: 'Choose a unit'}),
});
type MeasureValues = z.input<typeof measureSchema>;

function MeasureForm({parcel, onDone}: {parcel: DetailParcel; onDone: () => void}) {
  const {name: staff} = useStaff();
  const save = useAction('parcel-measure');
  const form = useForm<MeasureValues>({
    resolver: zodResolver(measureSchema),
    defaultValues: {
      length: formatMeasure(parcel.length), width: formatMeasure(parcel.width), height: formatMeasure(parcel.height),
      // No unit is pre-selected for an empty value: units are always chosen, never assumed.
      dimension_unit: parcel.dimension_unit ?? ('' as MeasureValues['dimension_unit']), weight: formatMeasure(parcel.weight),
      weight_unit: parcel.weight_unit ?? ('' as MeasureValues['weight_unit']),
    },
  });
  const {errors, dirtyFields} = form.formState;
  const submit = form.handleSubmit(async v => {
    // Only the parts staff changed become staff-entered; untouched default values keep their source.
    const dimsChanged = !parcel.dimensions_source || dirtyFields.length || dirtyFields.width || dirtyFields.height || dirtyFields.dimension_unit;
    const weightChanged = !parcel.weight_source || dirtyFields.weight || dirtyFields.weight_unit;
    if (!dimsChanged && !weightChanged) return onDone();
    await save.mutateAsync({
      staff, parcel_id: parcel.id, expected_row_version: parcel.row_version,
      ...(dimsChanged ? {dimensions: {length: v.length, width: v.width, height: v.height, unit: v.dimension_unit}} : {}),
      ...(weightChanged ? {weight: {value: v.weight, unit: v.weight_unit}} : {}),
    });
    onDone();
  });
  const num = (field: 'length' | 'width' | 'height' | 'weight', label: string) => (
    <div className="space-y-1">
      <Label htmlFor={`p${parcel.id}-${field}`}>{label}</Label>
      <Input id={`p${parcel.id}-${field}`} inputMode="decimal" autoComplete="off" aria-invalid={Boolean(errors[field])}
        aria-describedby={errors[field] ? `p${parcel.id}-${field}-err` : undefined} {...form.register(field)} />
      <FieldError id={`p${parcel.id}-${field}-err`} message={errors[field]?.message} />
    </div>
  );
  return (
    <motion.form onSubmit={submit} noValidate initial={{opacity: 0, y: -4}} animate={{opacity: 1, y: 0}}
      className="mt-3 space-y-3 rounded-xl border border-primary-line bg-primary-soft/40 p-3" aria-label={`Edit measurements of parcel ${parcel.parcel_no}`}>
      <p className="text-xs text-muted">Change only what differs from the actual package. Changed values are recorded as entered by you; unchanged default values stay marked as default.</p>
      <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <legend className="mb-1 text-xs font-semibold text-ink">Dimensions</legend>
        {num('length', 'Length')}{num('width', 'Width')}{num('height', 'Height')}
        <div className="space-y-1">
          <Label htmlFor={`p${parcel.id}-dunit`}>Unit</Label>
          <NativeSelect id={`p${parcel.id}-dunit`} aria-invalid={Boolean(errors.dimension_unit)} {...form.register('dimension_unit')}>
            <option value="" disabled>Choose…</option>
            {DIMENSION_UNITS.map(u => <option key={u} value={u}>{unitLabel(u)}</option>)}
          </NativeSelect>
          <FieldError message={errors.dimension_unit?.message} />
        </div>
      </fieldset>
      <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <legend className="mb-1 text-xs font-semibold text-ink">Total packed shipment weight</legend>
        {num('weight', 'Weight')}
        <div className="space-y-1">
          <Label htmlFor={`p${parcel.id}-wunit`}>Unit</Label>
          <NativeSelect id={`p${parcel.id}-wunit`} aria-invalid={Boolean(errors.weight_unit)} {...form.register('weight_unit')}>
            <option value="" disabled>Choose…</option>
            {WEIGHT_UNITS.map(u => <option key={u} value={u}>{unitLabel(u)}</option>)}
          </NativeSelect>
          <FieldError message={errors.weight_unit?.message} />
        </div>
      </fieldset>
      <ActionMessage error={save.error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save measurements'}</Button>
        <Button type="button" size="sm" variant="ghost" onClick={onDone}>Cancel</Button>
      </div>
    </motion.form>
  );
}

function ContentsList({items, lines, multi, refOf}: {items: Array<{oms_order_item_id: number; quantity: number}>; lines: DetailLine[]; multi: boolean; refOf: (id: number) => string}) {
  return (
    <ul className="space-y-1 text-sm">
      {items.map(i => {
        const l = lines.find(x => x.oms_order_item_id === i.oms_order_item_id);
        return (
          <li key={i.oms_order_item_id} className="flex flex-wrap items-baseline gap-x-2">
            <span className="font-mono text-[13px] text-ink break-all">{l?.item_sku ?? i.oms_order_item_id}</span>
            <span className="font-semibold tabular-nums text-ink">× {i.quantity}</span>
            {multi && l && <span className="font-mono text-xs text-muted">{refOf(l.oms_order_id)}</span>}
          </li>
        );
      })}
    </ul>
  );
}

function ContentsEditor({parcel, detail, onDone}: {parcel: DetailParcel; detail: GroupDetail; onDone: () => void}) {
  const {name: staff} = useStaff();
  const save = useAction('parcel-contents');
  const current = (id: number) => parcel.items.find(i => i.oms_order_item_id === id)?.quantity ?? 0;
  const maxFor = (l: DetailLine) => (l.absent_from_oms_since ? 0 : Math.max(l.quantity_ordered - l.allocated_qty + current(l.oms_order_item_id), 0));
  const form = useForm<{q: Record<string, string>}>({
    defaultValues: {q: Object.fromEntries(detail.lines.map(l => [String(l.oms_order_item_id), String(current(l.oms_order_item_id))]))},
  });
  const [problem, setProblem] = React.useState<string | null>(null);
  const multi = detail.orders.length > 1;
  const refOf = (id: number) => detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id);
  const submit = (confirm: boolean) => form.handleSubmit(async v => {
    const items = [];
    for (const l of detail.lines) {
      const raw = (v.q[String(l.oms_order_item_id)] ?? '').trim() || '0';
      if (!/^\d{1,6}$/.test(raw) || Number(raw) > maxFor(l)) {
        setProblem(`${l.item_sku}: enter a whole number from 0 to ${maxFor(l)}.`);
        return;
      }
      if (Number(raw) > 0 || current(l.oms_order_item_id) > 0) items.push({oms_order_item_id: l.oms_order_item_id, quantity: Number(raw)});
    }
    setProblem(null);
    await save.mutateAsync({staff, parcel_id: parcel.id, expected_row_version: parcel.row_version, items, confirm});
    onDone();
  });
  return (
    <form onSubmit={submit(false)} noValidate className="mt-2 space-y-3 rounded-xl border border-primary-line bg-primary-soft/40 p-3"
      aria-label={`Choose contents of parcel ${parcel.parcel_no}`}>
      <ul className="space-y-2">
        {detail.lines.map(l => {
          const fid = `p${parcel.id}-q${l.oms_order_item_id}`;
          return (
            <li key={l.oms_order_item_id} className="flex flex-wrap items-center gap-x-3 gap-y-1">
              <label htmlFor={fid} className="min-w-0 flex-1 text-sm">
                <span className="font-mono text-[13px] text-ink break-all">{l.item_sku}</span>
                {multi && <span className="ml-2 font-mono text-xs text-muted">{refOf(l.oms_order_id)}</span>}
                <span className="block text-xs text-muted">{l.quantity_ordered} ordered · up to {maxFor(l)} available for this parcel</span>
              </label>
              <Input id={fid} inputMode="numeric" className="w-24 text-right tabular-nums" {...form.register(`q.${l.oms_order_item_id}`)} />
            </li>
          );
        })}
      </ul>
      {problem && <FieldError message={problem} />}
      <ActionMessage error={save.error} />
      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" onClick={submit(true)} disabled={save.isPending}><CircleCheck aria-hidden />Save and confirm contents</Button>
        <Button type="submit" size="sm" variant="outline" disabled={save.isPending}>Save without confirming</Button>
        <Button type="button" size="sm" variant="ghost" onClick={onDone}>Cancel</Button>
      </div>
    </form>
  );
}

function changeText(c: ContentsChange, refOf: (id: number) => string): string {
  switch (c.kind) {
    case 'ordered_quantity_changed':
      return `${c.sku}: ordered quantity changed from ${c.from} to ${c.to}; ${c.packed_here} packed in this parcel${c.below_packed ? `, ${c.packed_all_parcels} in all parcels, more than ordered` : ''}.`;
    case 'sku_changed': return `Line ${c.line}: SKU changed from ${c.from} to ${c.to}.`;
    case 'line_no_longer_in_oms': return `${c.sku}: the OMS no longer has this line; ${c.packed_here} packed in this parcel.`;
    case 'line_back_in_oms': return `${c.sku}: the line is back in the OMS.`;
    case 'order_added_to_group': return `Order ${refOf(c.order!)} was merged into this group.`;
    case 'order_removed_from_group': return `Order ${refOf(c.order!)} is no longer in this group.`;
    case 'order_left_group': return `${c.sku}: its order ${refOf(c.order!)} is no longer in this group.`;
    case 'packed_quantity_edited': return `${c.sku}: packed quantity changed by staff from ${c.from} to ${c.to}.`;
    case 'item_added_to_parcel': return `${c.sku}: ${c.to} added to this parcel by staff.`;
    case 'item_taken_out_of_parcel': return `${c.sku}: taken out of this parcel by staff (was ${c.from}).`;
    default: return 'Order data changed.';
  }
}

function AcknowledgeForm({parcel}: {parcel: DetailParcel}) {
  const {name: staff, valid} = useStaff();
  const ack = useAction('discrepancy-acknowledge');
  const [open, setOpen] = React.useState(false);
  const form = useForm<{evidence: string}>({defaultValues: {evidence: ''}});
  const d = parcel.discrepancy!;
  const id = `ack-${d.id}`;
  if (!open) {
    return <Button size="sm" variant="outline" className="mt-1" disabled={!valid} onClick={() => setOpen(true)}>Acknowledge with evidence</Button>;
  }
  return (
    <form noValidate className="mt-1 space-y-2" onSubmit={form.handleSubmit(async v => {
      await ack.mutateAsync({staff, discrepancy_id: d.id, expected_current_hash: d.current_hash, evidence: v.evidence});
      setOpen(false);
    })}>
      <Label htmlFor={id} className="text-ink">Why can the booked parcel stay as it is?</Label>
      <Textarea id={id} rows={2} {...form.register('evidence', {validate: v => v.trim().length >= 3 || 'Record the evidence (at least 3 characters)'})} />
      <FieldError message={form.formState.errors.evidence?.message} />
      <ActionMessage error={ack.error} />
      <div className="flex gap-2">
        <Button type="submit" size="sm" disabled={ack.isPending}>Acknowledge</Button>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
      </div>
    </form>
  );
}

// What changed in the order since these contents were confirmed, and what staff must do.
function DiscrepancyPanel({parcel, detail, editable}: {parcel: DetailParcel; detail: GroupDetail; editable: boolean}) {
  const d = parcel.discrepancy;
  if (!d) return null;
  const refOf = (id: number) => detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id);
  if (d.status !== 'open') {
    return (
      <p className="mb-2 text-xs text-muted">
        Earlier order change {d.status === 'reconciled' ? 'reconciled' : 'acknowledged'} by {d.resolved_by}, {formatTimestamp(d.resolved_at)}{d.resolution ? `: ${d.resolution}` : ''}
      </p>
    );
  }
  return (
    <div role="status" className="mb-3 space-y-2 rounded-xl border border-danger-line bg-danger-soft px-3 py-2 text-xs text-danger">
      <p className="flex items-center gap-1.5 font-semibold"><AlertTriangle aria-hidden className="size-3.5" />
        {parcel.locked ? 'The order changed after this parcel was booked' : 'The order changed after these contents were confirmed'}
      </p>
      {d.changes.length ? (
        <ul className="list-disc space-y-0.5 pl-5">{d.changes.map((c, i) => <li key={i}>{changeText(c, refOf)}</li>)}</ul>
      ) : <p>The order data matches the earlier confirmation again; confirm the contents to clear this.</p>}
      <p className="text-ink">
        Previously confirmed by {d.confirmed_by}, {formatTimestamp(d.confirmed_at)}:{' '}
        {d.confirmed_basis.items.map(i => `${i.sku} × ${i.packed} (of ${i.ordered} ordered)`).join(', ') || 'no items'}.
      </p>
      <p className="text-ink">
        {parcel.locked
          ? 'The booked parcel and its shipment were not changed. Further purchases for this group stay blocked until this is resolved.'
          : 'Nothing was changed automatically. Check the package, change the items if needed, then confirm the contents again.'}
      </p>
      {parcel.locked && editable && <AcknowledgeForm parcel={parcel} />}
    </div>
  );
}

function ParcelCard({parcel, detail, editable}: {parcel: DetailParcel; detail: GroupDetail; editable: boolean}) {
  const {name: staff} = useStaff();
  const [mode, setMode] = React.useState<'view' | 'measure' | 'contents' | 'remove'>('view');
  const measureAction = useAction('parcel-measure');
  const contents = useAction('parcel-contents');
  const confirm = useAction('parcel-confirm');
  const remove = useAction('parcel-remove');
  const canEdit = editable && !parcel.locked;
  const multi = detail.orders.length > 1;
  const refOf = (id: number) => detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id);
  const proposed = detail.lines.filter(l => openUnits(l) > 0)
    .map(l => ({oms_order_item_id: l.oms_order_item_id, quantity: openUnits(l)}));
  const base = {staff, parcel_id: parcel.id, expected_row_version: parcel.row_version};
  const error = measureAction.error ?? contents.error ?? confirm.error ?? remove.error;
  const busy = measureAction.isPending || contents.isPending || confirm.isPending || remove.isPending;
  const v = parcel.profile?.values;

  return (
    <li className="rounded-xl border border-line p-3 sm:p-4">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-ink">Parcel {parcel.parcel_no}</span>
        <Badge tone={parcel.contents_status === 'confirmed' ? 'success' : parcel.contents_status === 'stale' ? 'danger' : 'review'}>
          {parcel.contents_status === 'confirmed' ? 'Contents confirmed' : parcel.contents_status === 'stale' ? 'Contents need reconciliation' : 'Contents not confirmed'}
        </Badge>
        {parcel.discrepancy?.status === 'open' && parcel.locked && <Badge tone="danger"><AlertTriangle aria-hidden />Order changed after booking</Badge>}
        {parcel.locked && <Badge tone="danger"><Lock aria-hidden />Locked: purchase or label active</Badge>}
        {canEdit && mode !== 'remove' && (
          <Button size="sm" variant="ghost" className="ml-auto text-danger hover:bg-danger-soft hover:text-danger" onClick={() => setMode('remove')}>
            <Trash2 aria-hidden />Remove
          </Button>
        )}
      </div>
      {mode === 'remove' && (
        <div role="group" aria-label="Confirm removal" className="mt-2 flex flex-wrap items-center gap-2 rounded-lg border border-danger-line bg-danger-soft px-3 py-2 text-sm text-danger">
          <span className="flex-1">Remove parcel {parcel.parcel_no}? Its items return to “remaining”.</span>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => remove.mutate(base, {onSuccess: () => setMode('view')})}>Yes, remove</Button>
          <Button size="sm" variant="ghost" onClick={() => setMode('view')}>Keep</Button>
        </div>
      )}

      <dl className="mt-3 grid gap-2 sm:grid-cols-2">
        <MeasureRow icon={Ruler} label="Dimensions (L × W × H)" parcel={parcel} source={parcel.dimensions_source}
          value={formatDimensions(parcel.length, parcel.width, parcel.height, parcel.dimension_unit)} />
        <MeasureRow icon={Scale} label="Total packed shipment weight" parcel={parcel} source={parcel.weight_source}
          value={formatWeight(parcel.weight, parcel.weight_unit)} />
      </dl>
      {canEdit && mode !== 'measure' && (
        <div className="mt-2 flex flex-wrap gap-2">
          <Button size="sm" variant="outline" onClick={() => setMode('measure')}><Pencil aria-hidden />
            {parcel.dimensions_source && parcel.weight_source ? 'Package differs? Edit' : 'Enter measurements'}
          </Button>
          {v && parcel.dimensions_source === 'staff' && (
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => measureAction.mutate({...base, dimensions: 'profile'})}>
              <RotateCcw aria-hidden />Use default dimensions ({formatDimensions(v.length, v.width, v.height, v.dimension_unit)})
            </Button>
          )}
          {v && v.packed_weight != null && parcel.weight_source === 'staff' && (
            <Button size="sm" variant="ghost" disabled={busy} onClick={() => measureAction.mutate({...base, weight: 'profile'})}>
              <RotateCcw aria-hidden />Use default weight ({formatWeight(v.packed_weight, v.packed_weight_unit)})
            </Button>
          )}
        </div>
      )}
      {mode === 'measure' && <MeasureForm parcel={parcel} onDone={() => setMode('view')} />}

      <div className="mt-4 border-t border-line pt-3">
        <h4 className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted">Contents</h4>
        <DiscrepancyPanel parcel={parcel} detail={detail} editable={editable} />
        {parcel.contents_status === 'confirmed' ? (
          <>
            <ContentsList items={parcel.items} lines={detail.lines} multi={multi} refOf={refOf} />
            <p className="mt-1 text-xs text-muted">Confirmed by {parcel.confirmed_by}, {formatTimestamp(parcel.confirmed_at)}</p>
            {canEdit && (
              <Button size="sm" variant="ghost" className="mt-2" disabled={busy} onClick={() => confirm.mutate({...base, confirmed: false})}>
                <Undo2 aria-hidden />Unconfirm to change contents
              </Button>
            )}
          </>
        ) : mode === 'contents' ? (
          <ContentsEditor parcel={parcel} detail={detail} onDone={() => setMode('view')} />
        ) : parcel.items.length === 0 ? (
          proposed.length > 0 ? (
            <div className="rounded-lg border border-dashed border-line-strong px-3 py-2">
              <p className="mb-1 text-xs text-muted">Proposed: every ordered item not yet in a parcel. Check the package, then confirm. A package profile never confirms contents.</p>
              <ContentsList items={proposed} lines={detail.lines} multi={multi} refOf={refOf} />
              {canEdit && (
                <div className="mt-2 flex flex-wrap gap-2">
                  <Button size="sm" variant="teal" disabled={busy} onClick={() => contents.mutate({...base, items: proposed, confirm: true})}>
                    <CircleCheck aria-hidden />Confirm these contents
                  </Button>
                  <Button size="sm" variant="outline" onClick={() => setMode('contents')}>Choose items (split)</Button>
                </div>
              )}
            </div>
          ) : <p className="text-sm text-muted">Every ordered unit is already in another parcel.</p>
        ) : (
          <>
            <ContentsList items={parcel.items} lines={detail.lines} multi={multi} refOf={refOf} />
            {canEdit && (
              <div className="mt-2 flex flex-wrap gap-2">
                <Button size="sm" variant="teal" disabled={busy} onClick={() => confirm.mutate({...base, confirmed: true})}>
                  <CircleCheck aria-hidden />{parcel.contents_status === 'stale' ? 'Confirm contents again' : 'Confirm contents'}
                </Button>
                <Button size="sm" variant="outline" onClick={() => setMode('contents')}>Change items</Button>
              </div>
            )}
          </>
        )}
      </div>
      <div className="mt-2"><ActionMessage error={error} /></div>
    </li>
  );
}

export function ParcelSection({detail}: {detail: GroupDetail}) {
  const {name: staff, valid} = useStaff();
  const create = useAction('parcel-create');
  const inReview = detail.group.state === 'review';
  const editable = inReview && valid;
  const remaining = detail.lines.reduce((n, l) => n + l.quantity_ordered - l.allocated_qty, 0);
  return (
    <Section icon={PackageOpen} tone="teal" title="Parcel preparation"
      aside={<span className="text-xs tabular-nums text-muted">{detail.parcels.length} parcel{detail.parcels.length === 1 ? '' : 's'} · {remaining} unit{remaining === 1 ? '' : 's'} remaining</span>}>
      <div className="space-y-3">
        <DefaultNote detail={detail} />
        {detail.allocation_problems && (
          <div role="status" className="flex items-start gap-2 rounded-xl border border-danger-line bg-danger-soft px-3 py-2 text-xs text-danger">
            <AlertTriangle aria-hidden className="mt-0.5 size-3.5 shrink-0" />
            <p><span className="font-semibold">Packed units no longer match the order:</span> {detail.allocation_problems}. Nothing was changed automatically; reduce the parcels below and confirm again.</p>
          </div>
        )}
        <AllocationTable detail={detail} />
        {!inReview && (
          <p className="flex items-start gap-2 text-xs text-muted"><Info aria-hidden className="mt-0.5 size-3.5 shrink-0" />
            This group is {detail.group.state}; parcels can be changed only while it is in review.</p>
        )}
        {inReview && !valid && <p className="text-xs text-review">Enter your name at the top of this panel to prepare parcels.</p>}
        {detail.parcels.length > 0 && (
          <ul className="space-y-3">{detail.parcels.map(p => <ParcelCard key={p.id} parcel={p} detail={detail} editable={editable} />)}</ul>
        )}
        {detail.parcels.length === 0 && (
          <p className="text-sm text-muted">No parcels yet. The ordered items above are not parcel contents until staff confirm them.</p>
        )}
        <div className="flex flex-wrap items-center gap-3">
          <Button size="sm" disabled={!editable || create.isPending} onClick={() => create.mutate({staff, group_id: detail.group.id})}>
            <PackagePlus aria-hidden />{create.isPending ? 'Creating…' : detail.parcels.length ? 'Add another parcel (split)' : 'Create draft parcel'}
          </Button>
          <Link href="/settings/package-profiles" className="inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline">
            <Settings2 aria-hidden className="size-3.5" />Package defaults
          </Link>
        </div>
        <ActionMessage error={create.error} />
      </div>
    </Section>
  );
}
