'use client';

// Staff review decisions in the order drawer: destination confirmation for exceptions (orders the
// verified country map cannot resolve), revoking a confirmation, and closing a finding with
// evidence. Each form sends the version of the data it was shown, so a change made meanwhile (a sync,
// another person) is refused instead of overwritten.
import * as React from 'react';
import {useForm} from 'react-hook-form';
import {zodResolver} from '@hookform/resolvers/zod';
import {z} from 'zod';
import {CircleCheck, Undo2} from 'lucide-react';
import {Button} from '@/client/components/ui/button';
import {Input} from '@/client/components/ui/input';
import {FieldError, Label, NativeSelect, Textarea} from '@/client/components/ui/field';
import {ActionMessage} from '@/client/components/bits';
import {useAction} from '@/client/lib/api';
import {useStaff} from '@/client/lib/staff';
import {EVIDENCE_LABELS} from '@/client/lib/domain';
import {EVIDENCE_TYPES} from '@/shared/actions';
import type {DetailOrder, ReviewCaseRow} from '@/shared/types';

const confirmSchema = z.object({
  country: z.enum(['US', 'CA', 'other'], {message: 'Choose a country'}),
  other_iso2: z.string().trim(),
  evidence_type: z.enum(EVIDENCE_TYPES, {message: 'Choose the kind of evidence'}),
  evidence_ref: z.string().trim().min(3, 'Describe the evidence (at least 3 characters)').max(500),
}).refine(v => v.country !== 'other' || /^[A-Za-z]{2}$/.test(v.other_iso2), {message: 'Enter a two-letter country code', path: ['other_iso2']});
type ConfirmValues = z.input<typeof confirmSchema>;

export function DestinationConfirmForm({order}: {order: DetailOrder}) {
  const {name: staff, valid} = useStaff();
  const [open, setOpen] = React.useState(false);
  const save = useAction('destination-confirm');
  const form = useForm<ConfirmValues>({
    resolver: zodResolver(confirmSchema),
    defaultValues: {country: '' as ConfirmValues['country'], other_iso2: '', evidence_type: '' as ConfirmValues['evidence_type'], evidence_ref: ''},
  });
  const {errors} = form.formState;
  const country = form.watch('country');
  const fid = (f: string) => `dc-${order.oms_order_id}-${f}`;
  if (!open) {
    return (
      <Button size="sm" variant="outline" className="mt-2" disabled={!valid} onClick={() => setOpen(true)}>
        <CircleCheck aria-hidden />Confirm destination with evidence
      </Button>
    );
  }
  const submit = form.handleSubmit(async v => {
    await save.mutateAsync({
      staff, oms_order_id: order.oms_order_id, iso2: v.country === 'other' ? v.other_iso2.toUpperCase() : v.country,
      evidence_type: v.evidence_type, evidence_ref: v.evidence_ref, expected_address_hash: order.address_hash,
    });
    setOpen(false);
    form.reset();
  });
  return (
    <form onSubmit={submit} noValidate className="mt-2 space-y-3 rounded-xl border border-primary-line bg-primary-soft/40 p-3"
      aria-label={`Confirm destination of ${order.platform_order_ref}`}>
      <p className="text-xs text-muted">Only for this order and this ship-to address. A later address change in the OMS revokes it automatically.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor={fid('country')}>Destination country</Label>
          <NativeSelect id={fid('country')} aria-invalid={Boolean(errors.country)} {...form.register('country')}>
            <option value="" disabled>Choose…</option>
            <option value="US">United States</option>
            <option value="CA">Canada</option>
            <option value="other">Another country (out of scope)</option>
          </NativeSelect>
          <FieldError message={errors.country?.message} />
        </div>
        {country === 'other' && (
          <div className="space-y-1">
            <Label htmlFor={fid('iso')}>Two-letter country code</Label>
            <Input id={fid('iso')} maxLength={2} aria-invalid={Boolean(errors.other_iso2)} {...form.register('other_iso2')} />
            <FieldError message={errors.other_iso2?.message} />
          </div>
        )}
        <div className="space-y-1">
          <Label htmlFor={fid('etype')}>Evidence</Label>
          <NativeSelect id={fid('etype')} aria-invalid={Boolean(errors.evidence_type)} {...form.register('evidence_type')}>
            <option value="" disabled>Choose…</option>
            {EVIDENCE_TYPES.map(t => <option key={t} value={t}>{EVIDENCE_LABELS[t]}</option>)}
          </NativeSelect>
          <FieldError message={errors.evidence_type?.message} />
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor={fid('ref')}>What the evidence shows</Label>
        <Textarea id={fid('ref')} rows={2} aria-invalid={Boolean(errors.evidence_ref)} placeholder="For example: marketplace order page lists a US ship-to"
          {...form.register('evidence_ref')} />
        <FieldError message={errors.evidence_ref?.message} />
      </div>
      <ActionMessage error={save.error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Confirm destination'}</Button>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
      </div>
    </form>
  );
}

const reasonSchema = z.object({reason: z.string().trim().min(3, 'Give a reason (at least 3 characters)').max(500)});

export function RevokeConfirmation({order, confirmationId}: {order: DetailOrder; confirmationId: number}) {
  const {name: staff, valid} = useStaff();
  const [open, setOpen] = React.useState(false);
  const revoke = useAction('destination-revoke');
  const form = useForm<z.input<typeof reasonSchema>>({resolver: zodResolver(reasonSchema), defaultValues: {reason: ''}});
  const id = `rv-${confirmationId}`;
  if (!open) {
    return (
      <Button size="sm" variant="ghost" disabled={!valid} onClick={() => setOpen(true)}><Undo2 aria-hidden />Revoke</Button>
    );
  }
  return (
    <form noValidate className="mt-1 w-full space-y-2" onSubmit={form.handleSubmit(async v => {
      await revoke.mutateAsync({staff, confirmation_id: confirmationId, reason: v.reason, expected_address_hash: order.address_hash});
      setOpen(false);
    })}>
      <Label htmlFor={id}>Why is this confirmation wrong?</Label>
      <Input id={id} aria-invalid={Boolean(form.formState.errors.reason)} {...form.register('reason')} />
      <FieldError message={form.formState.errors.reason?.message} />
      <ActionMessage error={revoke.error} />
      <div className="flex gap-2">
        <Button type="submit" size="sm" variant="outline" disabled={revoke.isPending}>Revoke confirmation</Button>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
      </div>
    </form>
  );
}

// Findings closed only by their own reconciliation step (booking outcome, label retrieval).
const NOT_CLOSABLE_HERE = new Set(['booking_unknown', 'label_unretrievable', 'over_allocation']);

const closeSchema = z.object({
  outcome: z.enum(['resolved', 'dismissed'], {message: 'Choose an outcome'}),
  evidence: z.string().trim().min(3, 'Record the evidence for this decision (at least 3 characters)').max(1000),
});

export function CaseCloseForm({c}: {c: ReviewCaseRow}) {
  const {name: staff, valid} = useStaff();
  const [open, setOpen] = React.useState(false);
  const close = useAction('case-close');
  const form = useForm<z.input<typeof closeSchema>>({
    resolver: zodResolver(closeSchema), defaultValues: {outcome: '' as 'resolved', evidence: ''},
  });
  const {errors} = form.formState;
  if (NOT_CLOSABLE_HERE.has(c.case_type)) return <p className="mt-1 text-xs text-muted">Closed by its reconciliation step, not here.</p>;
  if (!open) {
    return (
      <Button size="sm" variant="outline" className="mt-2" disabled={!valid} onClick={() => setOpen(true)}>
        <CircleCheck aria-hidden />Record decision
      </Button>
    );
  }
  const fid = (f: string) => `cc-${c.id}-${f}`;
  return (
    <form noValidate className="mt-2 space-y-3 rounded-xl border border-primary-line bg-primary-soft/40 p-3"
      aria-label="Record a decision on this finding"
      onSubmit={form.handleSubmit(async v => {
        await close.mutateAsync({staff, case_id: c.id, outcome: v.outcome, evidence: v.evidence, expected_details_hash: c.details_hash});
        setOpen(false);
      })}>
      <fieldset className="space-y-1">
        <legend className="text-xs font-medium text-muted">Outcome</legend>
        <div className="flex flex-wrap gap-4 text-sm">
          <label className="inline-flex items-center gap-2"><input type="radio" value="resolved" {...form.register('outcome')} />Resolved (the problem was dealt with)</label>
          <label className="inline-flex items-center gap-2"><input type="radio" value="dismissed" {...form.register('outcome')} />Dismissed (not a problem)</label>
        </div>
        <FieldError message={errors.outcome?.message} />
      </fieldset>
      <div className="space-y-1">
        <Label htmlFor={fid('ev')}>Evidence</Label>
        <Textarea id={fid('ev')} rows={2} aria-invalid={Boolean(errors.evidence)} placeholder="What you checked and what it showed"
          {...form.register('evidence')} />
        <FieldError message={errors.evidence?.message} />
      </div>
      <p className="text-xs text-muted">Only this finding changes. Requirements and other findings stay as they are. If the same problem appears again later, a new finding opens.</p>
      <ActionMessage error={close.error} />
      <div className="flex flex-wrap gap-2">
        <Button type="submit" size="sm" disabled={close.isPending}>{close.isPending ? 'Saving…' : 'Save decision'}</Button>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
      </div>
    </form>
  );
}
