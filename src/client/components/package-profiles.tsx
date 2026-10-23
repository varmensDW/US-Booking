'use client';

// Settings → Package Profiles. Staff save named box profiles (dimensions with their unit, and
// optionally the total packed shipment weight and the empty packaging weight, each with its own
// unit) and choose the default profile for US1 Shippo and US1 Amazon orders. Saving an edit creates a
// new version; parcels already created keep the version they were created with.
import * as React from 'react';
import {useForm} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z} from 'zod';
import {AnimatePresence, motion} from 'motion/react';
import {Boxes, ChevronDown, History, PackagePlus, Pencil, Ruler, Scale, Star} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Input} from '@/client/components/ui/input';
import {Skeleton} from '@/client/components/ui/skeleton';
import {FieldError, Label, NativeSelect, Textarea} from '@/client/components/ui/field';
import {ActionMessage, EmptyState, ErrorState, IconTile} from '@/client/components/bits';
import {useAction, usePackageProfiles} from '@/client/lib/api';
import {StaffBar, useStaff} from '@/client/lib/staff';
import {ASSIGNMENTS, formatDimensions, formatMeasure, formatWeight, PROVIDERS, unitLabel} from '@/client/lib/domain';
import {formatTimestamp} from '@/client/lib/format';
import {DIMENSION_UNITS, measure, WEIGHT_UNITS} from '@/shared/actions';
import type {PackageProfile, ProfileAssignment, ProfileVersion} from '@/shared/types';

const optionalMeasure = z.union([z.literal(''), measure]);
const formSchema = z.object({
  name: z.string().trim().min(2, 'Name the profile (at least 2 characters)').max(80),
  length: measure, width: measure, height: measure,
  dimension_unit: z.enum(DIMENSION_UNITS, {message: 'Choose a unit'}),
  packed_weight: optionalMeasure, packed_weight_unit: z.union([z.literal(''), z.enum(WEIGHT_UNITS)]),
  empty_weight: optionalMeasure, empty_weight_unit: z.union([z.literal(''), z.enum(WEIGHT_UNITS)]),
  note: z.string().trim().max(500),
}).refine(v => !v.packed_weight || v.packed_weight_unit, {message: 'Choose a unit for the packed weight', path: ['packed_weight_unit']})
  .refine(v => !v.empty_weight || v.empty_weight_unit, {message: 'Choose a unit for the empty packaging weight', path: ['empty_weight_unit']});
type FormValues = z.input<typeof formSchema>;

function ValuesSummary({v}: {v: ProfileVersion}) {
  return (
    <dl className="grid gap-2 text-sm sm:grid-cols-3">
      <div className="rounded-lg bg-canvas px-3 py-2">
        <dt className="flex items-center gap-1.5 text-xs text-muted"><Ruler aria-hidden className="size-3.5" />Dimensions (L × W × H)</dt>
        <dd className="mt-0.5 font-semibold tabular-nums text-ink">{formatDimensions(v.length, v.width, v.height, v.dimension_unit)}</dd>
      </div>
      <div className="rounded-lg bg-canvas px-3 py-2">
        <dt className="flex items-center gap-1.5 text-xs text-muted"><Scale aria-hidden className="size-3.5" />Total packed shipment weight</dt>
        <dd className="mt-0.5 font-semibold tabular-nums text-ink">{v.packed_weight != null ? formatWeight(v.packed_weight, v.packed_weight_unit) : 'Not set: staff enter it per parcel'}</dd>
      </div>
      <div className="rounded-lg bg-canvas px-3 py-2">
        <dt className="text-xs text-muted">Empty packaging weight (reference only)</dt>
        <dd className="mt-0.5 font-semibold tabular-nums text-ink">{v.empty_weight != null ? formatWeight(v.empty_weight, v.empty_weight_unit) : 'Not set'}</dd>
      </div>
    </dl>
  );
}

function ProfileForm({profile, onDone}: {profile?: PackageProfile; onDone: () => void}) {
  const {name: staff, valid} = useStaff();
  const save = useAction('profile-save');
  const cur = profile?.versions[0];
  const form = useForm<FormValues>({
    resolver: zodResolver(formSchema),
    defaultValues: {
      name: profile?.name ?? '',
      length: formatMeasure(cur?.length), width: formatMeasure(cur?.width), height: formatMeasure(cur?.height),
      dimension_unit: cur?.dimension_unit ?? ('' as FormValues['dimension_unit']),
      packed_weight: formatMeasure(cur?.packed_weight), packed_weight_unit: cur?.packed_weight_unit ?? '',
      empty_weight: formatMeasure(cur?.empty_weight), empty_weight_unit: cur?.empty_weight_unit ?? '',
      note: cur?.note ?? '',
    },
  });
  const {errors} = form.formState;
  const fid = (f: string) => `pf-${profile?.id ?? 'new'}-${f}`;
  const field = (f: 'name' | 'length' | 'width' | 'height' | 'packed_weight' | 'empty_weight', label: string, numeric = true) => (
    <div className="space-y-1">
      <Label htmlFor={fid(f)}>{label}</Label>
      <Input id={fid(f)} inputMode={numeric ? 'decimal' : undefined} autoComplete="off" aria-invalid={Boolean(errors[f])} {...form.register(f)} />
      <FieldError message={errors[f]?.message} />
    </div>
  );
  const unit = (f: 'dimension_unit' | 'packed_weight_unit' | 'empty_weight_unit', units: readonly string[], optional: boolean) => (
    <div className="space-y-1">
      <Label htmlFor={fid(f)}>Unit</Label>
      <NativeSelect id={fid(f)} aria-invalid={Boolean(errors[f])} {...form.register(f)}>
        <option value="" disabled={!optional}>{optional ? 'None' : 'Choose…'}</option>
        {units.map(u => <option key={u} value={u}>{unitLabel(u)}</option>)}
      </NativeSelect>
      <FieldError message={errors[f]?.message} />
    </div>
  );
  const submit = form.handleSubmit(async v => {
    await save.mutateAsync({
      staff, name: v.name,
      ...(profile ? {profile_id: profile.id, expected_version: profile.current_version} : {}),
      length: v.length, width: v.width, height: v.height, dimension_unit: v.dimension_unit as 'in' | 'cm',
      ...(v.packed_weight ? {packed_weight: v.packed_weight, packed_weight_unit: v.packed_weight_unit as 'lb'} : {}),
      ...(v.empty_weight ? {empty_weight: v.empty_weight, empty_weight_unit: v.empty_weight_unit as 'lb'} : {}),
      ...(v.note ? {note: v.note} : {}),
    });
    onDone();
  });
  return (
    <motion.form onSubmit={submit} noValidate initial={{opacity: 0, y: -4}} animate={{opacity: 1, y: 0}}
      className="space-y-4 rounded-xl border border-primary-line bg-primary-soft/40 p-4" aria-label={profile ? `Edit ${profile.name}` : 'New package profile'}>
      {profile && <p className="text-xs text-muted">Saving creates version {(profile.current_version ?? 0) + 1}. The {profile.parcels_using} parcel{profile.parcels_using === 1 ? '' : 's'} already using this profile keep the values they were created with.</p>}
      <div className="grid gap-3 sm:grid-cols-2">{field('name', 'Profile name', false)}</div>
      <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <legend className="mb-1 text-xs font-semibold text-ink">Box dimensions</legend>
        {field('length', 'Length')}{field('width', 'Width')}{field('height', 'Height')}{unit('dimension_unit', DIMENSION_UNITS, false)}
      </fieldset>
      <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <legend className="mb-1 text-xs font-semibold text-ink">Total packed shipment weight <span className="font-normal text-muted">(optional; prefilled on new parcels)</span></legend>
        {field('packed_weight', 'Weight')}{unit('packed_weight_unit', WEIGHT_UNITS, true)}
      </fieldset>
      <fieldset className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <legend className="mb-1 text-xs font-semibold text-ink">Empty packaging weight <span className="font-normal text-muted">(optional; reference only, never used as a shipment weight)</span></legend>
        {field('empty_weight', 'Weight')}{unit('empty_weight_unit', WEIGHT_UNITS, true)}
      </fieldset>
      <div className="space-y-1">
        <Label htmlFor={fid('note')}>Note (optional)</Label>
        <Textarea id={fid('note')} rows={2} {...form.register('note')} />
      </div>
      <p className="text-xs text-muted">Units are stored exactly as chosen and never converted.</p>
      <ActionMessage error={save.error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" disabled={!valid || save.isPending}>{save.isPending ? 'Saving…' : profile ? 'Save new version' : 'Save profile'}</Button>
        <Button type="button" size="sm" variant="ghost" onClick={onDone}>Cancel</Button>
      </div>
    </motion.form>
  );
}

function AssignmentRow({a, profiles}: {a: ProfileAssignment; profiles: PackageProfile[]}) {
  const {name: staff, valid} = useStaff();
  const assign = useAction('profile-assign');
  const current = profiles.find(p => p.id === a.profile_id);
  const id = `as-${a.assignment}`;
  const meta = ASSIGNMENTS[a.assignment];
  return (
    <li className="space-y-3 py-4 first:pt-0 last:pb-0">
      <div className="flex flex-wrap items-start gap-3">
        <div className="min-w-0 flex-1">
          <p className="font-semibold text-ink">{meta?.label ?? a.assignment}</p>
          <p className="text-xs text-muted">{meta?.detail} · warehouse {a.warehouse_id} · {PROVIDERS[a.provider] ?? a.provider}</p>
        </div>
        <div className="w-full space-y-1 sm:w-64">
          <Label htmlFor={id}>Default profile</Label>
          <NativeSelect id={id} value={a.profile_id ?? ''} disabled={!valid || assign.isPending}
            onChange={e => assign.mutate({staff, assignment: a.assignment, profile_id: e.target.value ? Number(e.target.value) : null, expected_profile_id: a.profile_id})}>
            <option value="">No default (staff enter values)</option>
            {profiles.filter(p => p.approval_status === 'approved').map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
          </NativeSelect>
        </div>
      </div>
      {current?.versions[0] ? (
        <>
          <ValuesSummary v={current.versions[0]} />
          <p className="text-xs text-muted">Active default: {current.name}, version {current.current_version}. Assigned by {a.assigned_by}, {formatTimestamp(a.assigned_at)}.</p>
        </>
      ) : (
        <p className="rounded-lg border border-dashed border-line-strong px-3 py-2 text-sm text-muted">Not configured. New parcels on this route start empty.</p>
      )}
      <ActionMessage error={assign.error} />
    </li>
  );
}

function ProfileCard({p}: {p: PackageProfile}) {
  const [editing, setEditing] = React.useState(false);
  const [history, setHistory] = React.useState(false);
  const {valid} = useStaff();
  const v = p.versions[0];
  return (
    <li className="space-y-3 rounded-xl border border-line p-4">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-semibold text-ink">{p.name}</span>
        <Badge tone={p.approval_status === 'approved' ? 'success' : 'neutral'}>{p.approval_status === 'approved' ? `Version ${p.current_version}` : p.approval_status}</Badge>
        <span className="text-xs text-muted">{p.parcels_using} parcel{p.parcels_using === 1 ? '' : 's'} created from it</span>
        {!editing && (
          <Button size="sm" variant="outline" className="ml-auto" disabled={!valid} onClick={() => setEditing(true)}><Pencil aria-hidden />Edit</Button>
        )}
      </div>
      {v && <ValuesSummary v={v} />}
      {v && <p className="text-xs text-muted">Approved by {v.approved_by}, {formatTimestamp(v.approved_at)}{v.note ? ` · ${v.note}` : ''}</p>}
      <AnimatePresence>{editing && <ProfileForm profile={p} onDone={() => setEditing(false)} />}</AnimatePresence>
      {p.versions.length > 1 && (
        <div>
          <button type="button" onClick={() => setHistory(h => !h)} aria-expanded={history}
            className="flex items-center gap-1 rounded text-xs font-medium text-primary hover:underline">
            <ChevronDown aria-hidden className={`size-3.5 transition-transform duration-150 ${history ? 'rotate-180' : ''}`} />
            <History aria-hidden className="size-3.5" />{history ? 'Hide' : 'Show'} earlier versions ({p.versions.length - 1})
          </button>
          {history && (
            <ul className="mt-2 space-y-1 text-xs text-muted">
              {p.versions.slice(1).map(x => (
                <li key={x.version}>
                  Version {x.version}: {formatDimensions(x.length, x.width, x.height, x.dimension_unit)}
                  {x.packed_weight != null ? ` · ${formatWeight(x.packed_weight, x.packed_weight_unit)} packed` : ''}
                  {x.empty_weight != null ? ` · ${formatWeight(x.empty_weight, x.empty_weight_unit)} empty` : ''}
                  {' '}· {x.approved_by}, {formatTimestamp(x.approved_at)}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </li>
  );
}

export function PackageProfiles() {
  const q = usePackageProfiles();
  const [creating, setCreating] = React.useState(false);
  const {valid} = useStaff();
  if (q.isPending) return <div className="space-y-5" aria-busy="true"><Skeleton className="h-14 rounded-xl" /><Skeleton className="h-64 rounded-2xl" /></div>;
  if (q.isError && !q.data) {
    return <Card><ErrorState title="Package profiles could not be loaded" message={q.error.message} onRetry={() => q.refetch()} retrying={q.isFetching} /></Card>;
  }
  const {profiles, assignments} = q.data!;
  return (
    <div className="space-y-5">
      <StaffBar />
      <Card className="p-5">
        <div className="mb-1 flex items-center gap-3"><IconTile icon={Star} tone="teal" size="sm" /><h2 className="text-sm font-semibold">Default package per route</h2></div>
        <p className="mb-4 text-xs text-muted">
          A new draft parcel copies the assigned profile's dimensions and total packed weight. Staff change them only when the actual package differs;
          copied values are recorded as “Default profile”, not as measured by staff. Defaults never confirm parcel contents and never make an order eligible for purchase.
        </p>
        <ul className="divide-y divide-line">{assignments.map(a => <AssignmentRow key={a.assignment} a={a} profiles={profiles} />)}</ul>
      </Card>
      <Card className="p-5">
        <div className="mb-4 flex flex-wrap items-center gap-3">
          <IconTile icon={Boxes} tone="primary" size="sm" />
          <h2 className="flex-1 text-sm font-semibold">Package profiles</h2>
          {!creating && <Button size="sm" disabled={!valid} onClick={() => setCreating(true)}><PackagePlus aria-hidden />New profile</Button>}
        </div>
        <AnimatePresence>{creating && <div className="mb-4"><ProfileForm onDone={() => setCreating(false)} /></div>}</AnimatePresence>
        {profiles.length === 0 && !creating ? (
          <EmptyState title="No package profiles yet" icon={Boxes}>Create a profile with the real box dimensions, then assign it as a default above.</EmptyState>
        ) : (
          <ul className="space-y-3">{profiles.map(p => <ProfileCard key={p.id} p={p} />)}</ul>
        )}
      </Card>
    </div>
  );
}
