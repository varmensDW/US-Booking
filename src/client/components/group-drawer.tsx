'use client';

import * as React from 'react';
import {motion} from 'motion/react';
import {
  Ban, Boxes, ChevronDown, CircleCheck, CircleDashed, ClipboardList, Eye, EyeOff, FileText, GitMerge, Info, MapPin,
  Route, ShieldAlert, Truck,
} from 'lucide-react';
import {Sheet, SheetContent, SheetDescription, SheetTitle} from '@/client/components/ui/sheet';
import {Badge} from '@/client/components/ui/badge';
import {Skeleton} from '@/client/components/ui/skeleton';
import {ChannelBadge, CopyButton, CountryFlag, ErrorState, IconTile, NotConfirmed, Section} from '@/client/components/bits';
import {ParcelSection} from '@/client/components/parcel-prep';
import {CaseCloseForm, DestinationConfirmForm, RevokeConfirmation} from '@/client/components/review-actions';
import {StaffBar} from '@/client/lib/staff';
import {useGroupDetail, useStatus} from '@/client/lib/api';
import {
  CASE_LABELS, CASE_TONE, confirmedIso2, countryName, customsState, omsStatusLabel, PROVIDERS, REQUIREMENT_LABELS,
  requirementSort, routeReadiness, STATUS_TONE,
} from '@/client/lib/domain';
import {formatOmsRaw, formatTimestamp, OMS_TIME_NOTE} from '@/client/lib/format';
import type {DetailOrder, GroupDetail, QueueGroup, Requirement} from '@/shared/types';


const ROLE_LABEL = {single: 'Single order', merge_parent: 'Main order (merge parent)', merge_child: 'Merged order'} as const;

function OrdersSection({orders}: {orders: DetailOrder[]}) {
  return (
    <Section icon={GitMerge} tone="violet" title={orders.length > 1 ? `Orders in this group (${orders.length})` : 'Order'}>
      <ul className="divide-y divide-line">
        {orders.map(o => (
          <li key={o.oms_order_id} className="flex flex-wrap items-start gap-x-4 gap-y-2 py-3 first:pt-0 last:pb-0">
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-1">
                <span className="font-mono text-[13px] font-semibold text-ink break-all">{o.platform_order_ref}</span>
                <CopyButton value={o.platform_order_ref} label={`Copy order reference ${o.platform_order_ref}`} />
              </div>
              <p className="mt-0.5 text-xs text-muted">
                OMS order {o.oms_order_id} · {ROLE_LABEL[o.role]}
                {o.role === 'merge_child' && o.oms_merge_raw ? ` into ${o.oms_merge_raw}` : ''}
              </p>
              <p className="mt-1 text-xs text-muted">
                Ordered {formatOmsRaw(o.order_date_raw)} <span className="text-subtle">({OMS_TIME_NOTE})</span>
              </p>
            </div>
            <div className="flex flex-wrap items-center gap-1.5">
              <ChannelBadge channel={o.channel} />
              <Badge tone={STATUS_TONE[o.oms_status] ?? 'neutral'}>{omsStatusLabel(o.oms_status)}</Badge>
              {o.warehouse_id !== 32 && <Badge tone="danger">Warehouse {o.warehouse_id}</Badge>}
            </div>
            {o.account_name && <p className="w-full text-xs text-muted">Account: {o.account_name}</p>}
          </li>
        ))}
      </ul>
    </Section>
  );
}

function DestinationSection({orders}: {orders: DetailOrder[]}) {
  const [showAddress, setShowAddress] = React.useState(false);
  return (
    <Section icon={MapPin} tone="teal" title="Destination"
      aside={
        <button type="button" onClick={() => setShowAddress(s => !s)} aria-pressed={showAddress}
          className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-xs font-medium text-primary hover:bg-primary-soft">
          {showAddress ? <EyeOff aria-hidden className="size-3.5" /> : <Eye aria-hidden className="size-3.5" />}
          {showAddress ? 'Hide ship-to address' : 'Show ship-to address'}
        </button>
      }>
      <ul className="space-y-3">
        {orders.map(o => {
          const iso = confirmedIso2(o.destination);
          const active = o.confirmations.find(c => c.status === 'active');
          return (
            <li key={o.oms_order_id} className="rounded-xl border border-line p-3">
              <div className="flex flex-wrap items-center justify-between gap-2">
                {iso ? <CountryFlag iso2={iso} /> : o.destination.source === 'conflict'
                  ? <NotConfirmed label="Destination conflict: map and confirmation disagree" className="text-danger" />
                  : <NotConfirmed />}
                {orders.length > 1 && <span className="font-mono text-xs text-muted">{o.platform_order_ref}</span>}
              </div>
              <p className="mt-2 text-xs text-muted">
                {iso
                  ? o.destination.source === 'country_map'
                    ? `Resolved automatically: OMS country id ${o.destination.oms_country_id} is a verified mapping (${countryName(iso)}). No confirmation needed.`
                    : 'Confirmed by staff with evidence for this address.'
                  : o.destination.source === 'conflict'
                    ? 'The verified country mapping and the staff confirmation disagree. Revoke the confirmation if it is wrong.'
                    : <>{o.destination.oms_country_id == null ? 'The OMS has no country id for this ship-to' : `OMS country id ${o.destination.oms_country_id} has no verified mapping`}, so staff must confirm this destination. It is not inferred from the US1 warehouse or the marketplace.</>}
              </p>
              {o.destination.stale && <p className="mt-1 text-xs text-review">A confirmation exists for an earlier address and no longer applies.</p>}
              {o.confirmations.length > 0 && (
                <ul className="mt-2 space-y-1 text-xs">
                  {o.confirmations.map(c => (
                    <li key={c.id} className="flex flex-wrap items-center gap-1.5">
                      <Badge tone={c.valid_for_current_address ? 'success' : 'neutral'}>{c.status === 'revoked' ? 'Revoked' : c.valid_for_current_address ? 'Valid' : 'Not valid for current address'}</Badge>
                      <span className="text-muted">{countryName(c.destination_iso2)} · {c.evidence_type.replaceAll('_', ' ')} · {c.confirmed_by}, {formatTimestamp(c.confirmed_at)}</span>
                      {c.status === 'active' && <span className="w-full text-muted">Evidence: {c.evidence_ref}</span>}
                      {c.revoke_reason && <span className="text-muted">— {c.revoke_reason}</span>}
                      {c.status === 'active' && <RevokeConfirmation order={o} confirmationId={c.id} />}
                    </li>
                  ))}
                </ul>
              )}
              {!active && !iso && <p className="mt-1 text-xs text-muted">No staff confirmation recorded yet.</p>}
              {o.destination.source === 'unresolved' && <DestinationConfirmForm order={o} />}
              {showAddress && (
                <address className="mt-2 rounded-lg bg-canvas px-3 py-2 text-xs not-italic leading-relaxed text-ink">
                  {[o.ship.name, o.ship.company, o.ship.line1, o.ship.line2, o.ship.line3].filter(Boolean).map((l, i) => <span key={i} className="block">{l}</span>)}
                  <span className="block">{[o.ship.city, o.ship.region || '(state missing)', o.ship.postcode].filter(Boolean).join(', ')}</span>
                  <span className="mt-1 block text-muted">Phone {o.ship.phone_present ? 'on file' : 'missing'} · email {o.ship.email_present ? 'on file' : 'missing'}</span>
                </address>
              )}
            </li>
          );
        })}
      </ul>
    </Section>
  );
}

function ItemsSection({detail}: {detail: GroupDetail}) {
  const [openPack, setOpenPack] = React.useState<number | null>(null);
  const multi = detail.orders.length > 1;
  const refOf = (id: number) => detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id);
  const totalQty = detail.lines.reduce((n, l) => n + l.quantity_ordered, 0);
  return (
    <Section icon={ClipboardList} tone="primary" title="Ordered items (from the OMS)"
      aside={<span className="text-xs tabular-nums text-muted">{detail.lines.length} lines · {totalQty} ordered</span>}>
      <p className="mb-3 text-xs text-muted">What the customer ordered, exactly as in the OMS. Pack SKUs stay as ordered. These are not parcel contents.</p>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[440px] text-sm">
          <thead>
            <tr className="text-left text-xs font-semibold uppercase tracking-wide text-muted">
              <th scope="col" className="pb-2 pr-3">Ordered SKU</th>
              {multi && <th scope="col" className="pb-2 pr-3">Order</th>}
              <th scope="col" className="pb-2 pr-3 text-right">Qty</th>
              <th scope="col" className="pb-2">Pack</th>
            </tr>
          </thead>
          <tbody>
            {detail.lines.map(l => (
              <React.Fragment key={l.oms_order_item_id}>
                <tr className="border-t border-line align-top">
                  <td className="py-2.5 pr-3">
                    <span className="font-mono text-[13px] font-medium text-ink break-all">{l.item_sku}</span>
                    <span className="block text-xs text-muted">
                      {l.real_sku ? (l.real_sku !== l.item_sku ? `Internal SKU ${l.real_sku}` : 'Internal SKU matches') : <span className="text-review">Internal SKU missing</span>}
                    </span>
                  </td>
                  {multi && <td className="py-2.5 pr-3 font-mono text-xs text-muted">{refOf(l.oms_order_id)}</td>}
                  <td className="py-2.5 pr-3 text-right font-semibold tabular-nums text-ink">{l.quantity_ordered}</td>
                  <td className="py-2.5">
                    {(l.combo_count ?? 0) > 1 ? <Badge tone="violet">Pack of {l.combo_count}</Badge> : <span className="text-xs text-muted">Single item</span>}
                    {l.components.length > 0 && (
                      <button type="button" onClick={() => setOpenPack(p => (p === l.oms_order_item_id ? null : l.oms_order_item_id))}
                        aria-expanded={openPack === l.oms_order_item_id}
                        className="mt-1 flex items-center gap-1 rounded text-xs text-primary hover:underline">
                        <ChevronDown aria-hidden className={`size-3.5 transition-transform duration-150 ${openPack === l.oms_order_item_id ? 'rotate-180' : ''}`} />
                        {l.components.length} component reference row{l.components.length === 1 ? '' : 's'}
                      </button>
                    )}
                  </td>
                </tr>
                {openPack === l.oms_order_item_id && (
                  <tr>
                    <td colSpan={multi ? 4 : 3} className="pb-3">
                      <motion.div initial={{opacity: 0, height: 0}} animate={{opacity: 1, height: 'auto'}} transition={{duration: 0.15}}
                        className="rounded-lg border border-dashed border-line-strong bg-canvas px-3 py-2 text-xs">
                        <p className="mb-1 text-muted">OMS component reference only: not ordered units and not confirmed parcel contents.</p>
                        <ul className="space-y-0.5">
                          {l.components.map((c, i) => <li key={i} className="font-mono text-ink">{c.sku} <span className="text-muted">× {c.qty ?? '?'}</span></li>)}
                        </ul>
                      </motion.div>
                    </td>
                  </tr>
                )}
              </React.Fragment>
            ))}
          </tbody>
        </table>
      </div>
    </Section>
  );
}

function EvidenceSection({orders}: {orders: DetailOrder[]}) {
  return (
    <Section icon={Truck} tone="info" title="Shipment evidence in the OMS">
      <div className="mb-3 flex items-start gap-2 rounded-xl border border-info-line bg-info-soft px-3 py-2 text-xs text-info">
        <Info aria-hidden className="mt-0.5 size-3.5 shrink-0" />
        <p>Missing tracking is <span className="font-semibold">not</span> proof that an order has not been labelled. Amazon and Wayfair shipment rows in the OMS never carry tracking, and labels may exist outside the OMS.</p>
      </div>
      <ul className="space-y-2">
        {orders.map(o => {
          const s = o.oms_shipments;
          const signal = (s?.tracked_not_cancelled ?? 0) > 0 || o.oms_shipped_flag === 1;
          return (
            <li key={o.oms_order_id} className="rounded-xl border border-line px-3 py-2 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                {orders.length > 1 && <span className="font-mono text-xs text-muted">{o.platform_order_ref}</span>}
                <Badge tone={signal ? 'danger' : 'neutral'}>{signal ? 'OMS shows shipping activity' : 'Prior label: not established'}</Badge>
              </div>
              <dl className="mt-2 grid grid-cols-1 gap-x-4 gap-y-1 text-xs sm:grid-cols-2">
                <div><dt className="inline text-muted">OMS shipment rows: </dt><dd className="inline text-ink tabular-nums">{s ? s.total : 'not recorded'}</dd></div>
                <div><dt className="inline text-muted">With tracking (not cancelled): </dt><dd className="inline text-ink tabular-nums">{s ? s.tracked_not_cancelled : 'not recorded'}</dd></div>
                {s && s.statuses.length > 0 && <div><dt className="inline text-muted">Row statuses: </dt><dd className="inline text-ink">{s.statuses.join(', ')}</dd></div>}
                <div><dt className="inline text-muted">OMS “shipped” flag: </dt><dd className="inline text-ink">{o.oms_shipped_flag === 1 ? 'set (meaning unconfirmed)' : o.oms_shipped_flag === 0 ? 'not set' : 'not recorded'}</dd></div>
                {o.oms_shipped_error && <div className="sm:col-span-2"><dt className="inline text-muted">OMS shipping message: </dt><dd className="inline text-ink">{o.oms_shipped_error}</dd></div>}
                {o.ebay_cancel_status && <div><dt className="inline text-muted">eBay cancellation status: </dt><dd className="inline text-ink">{o.ebay_cancel_status}</dd></div>}
                {(o.ebay_cancel_requests?.length ?? 0) > 0 && <div><dt className="inline text-muted">eBay cancellation requests: </dt><dd className="inline text-ink">{o.ebay_cancel_requests!.map(r => r.status ?? 'pending').join(', ')}</dd></div>}
              </dl>
            </li>
          );
        })}
      </ul>
    </Section>
  );
}

function requirementView(r: Requirement, detail: GroupDetail): {label: string; tone: 'review' | 'success' | 'neutral' | 'info'; text: string} {
  if (r.requirement === 'customs_declaration') {
    const order = detail.orders.find(o => o.oms_order_id === r.oms_order_id);
    const state = customsState(order?.destination, r);
    if (state === 'awaiting_destination') return {label: 'Awaiting destination', tone: 'info', text: 'Applies only if the destination is confirmed as Canada.'};
    if (state === 'not_required') return {label: 'Not required', tone: 'neutral', text: `Confirmed destination ${countryName(confirmedIso2(order!.destination)!)}: no customs declaration.`};
    if (state === 'provided') return {label: 'Provided', tone: 'success', text: r.detail ?? ''};
    return {label: 'Missing', tone: 'review', text: 'Canada destination: contents description, value and origin are needed (HS code where the service requires it).'};
  }
  const provider = PROVIDERS[detail.group.provider] ?? detail.group.provider;
  if (r.status === 'unmet' && r.requirement === 'provider_account') {
    return {label: 'Missing', tone: 'review', text: `No ${provider} account has been assigned to this group yet.`};
  }
  if (r.status === 'unmet' && r.requirement === 'routing_verified') {
    return {label: 'Missing', tone: 'review', text: `The ${provider} route has no verified routing rule yet, so it cannot be booked.`};
  }
  if (r.status === 'met') return {label: 'Met', tone: 'success', text: r.detail ?? ''};
  if (r.status === 'not_applicable') return {label: 'Not applicable', tone: 'neutral', text: r.detail ?? ''};
  return {label: 'Missing', tone: 'review', text: r.detail ?? ''};
}

function RequirementsSection({detail}: {detail: GroupDetail}) {
  const [showMet, setShowMet] = React.useState(false);
  const rows = [...detail.requirements].sort(requirementSort).map(r => ({r, v: requirementView(r, detail)}));
  const outstanding = rows.filter(x => x.v.tone === 'review');
  const rest = rows.filter(x => x.v.tone !== 'review');
  const multi = detail.orders.length > 1;
  const refOf = (id: number | null) => (id == null ? 'whole group' : detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id));
  const row = ({r, v}: (typeof rows)[number]) => (
    <li key={r.id} className="flex flex-wrap items-start gap-x-3 gap-y-1 py-2.5">
      <Badge tone={v.tone}>{v.label}</Badge>
      <div className="min-w-0 flex-1 text-sm">
        <span className="font-medium text-ink">{REQUIREMENT_LABELS[r.requirement] ?? r.requirement}</span>
        {(multi || r.oms_order_id == null) && <span className="text-xs text-muted"> · {refOf(r.oms_order_id)}</span>}
        {v.text && <p className="text-xs text-muted">{v.text}</p>}
        {!r.checked_by.startsWith('system:') && <p className="text-xs text-muted">Checked by {r.checked_by}, {formatTimestamp(r.checked_at)}</p>}
      </div>
    </li>
  );
  return (
    <Section icon={ShieldAlert} tone="review" title="Review requirements"
      aside={<span className="text-xs text-muted tabular-nums">{outstanding.length} outstanding</span>}>
      {outstanding.length === 0 ? <p className="text-sm text-muted">No outstanding requirement recorded.</p> : <ul className="divide-y divide-line">{outstanding.map(row)}</ul>}
      {rest.length > 0 && (
        <>
          <button type="button" onClick={() => setShowMet(s => !s)} aria-expanded={showMet}
            className="mt-2 flex items-center gap-1 rounded text-xs font-medium text-primary hover:underline">
            <ChevronDown aria-hidden className={`size-3.5 transition-transform duration-150 ${showMet ? 'rotate-180' : ''}`} />
            {showMet ? 'Hide' : 'Show'} {rest.length} met, not applicable or pending item{rest.length === 1 ? '' : 's'}
          </button>
          {showMet && <ul className="mt-1 divide-y divide-line">{rest.map(row)}</ul>}
        </>
      )}
    </Section>
  );
}

function FindingsSection({detail}: {detail: GroupDetail}) {
  const open = detail.cases.filter(c => c.status === 'open');
  const closed = detail.cases.filter(c => c.status !== 'open');
  const refOf = (id: number | null) => (id == null ? '' : detail.orders.find(o => o.oms_order_id === id)?.platform_order_ref ?? String(id));
  return (
    <Section icon={FileText} tone={open.length ? 'danger' : 'neutral'} title="Findings for staff decision"
      aside={<span className="text-xs text-muted tabular-nums">{open.length} open</span>}>
      {detail.cases.length === 0 ? <p className="text-sm text-muted">No findings recorded for this group.</p> : (
        <ul className="space-y-2">
          {[...open, ...closed].map(c => (
            <li key={c.id} className="rounded-xl border border-line px-3 py-2">
              <div className="flex flex-wrap items-center gap-2">
                <Badge tone={c.status === 'open' ? (CASE_TONE[c.case_type] ?? 'review') : 'neutral'}>
                  {c.status === 'open' ? <CircleDashed aria-hidden /> : <CircleCheck aria-hidden />}
                  {c.status === 'open' ? 'Open' : c.status === 'resolved' ? 'Resolved' : 'Dismissed'}
                </Badge>
                <span className="text-sm font-medium text-ink">{CASE_LABELS[c.case_type] ?? c.case_type}</span>
                {detail.orders.length > 1 && c.oms_order_id && <span className="font-mono text-xs text-muted">{refOf(c.oms_order_id)}</span>}
              </div>
              <p className="mt-1 text-xs text-muted">
                Opened {formatTimestamp(c.opened_at)}
                {typeof c.details.reason === 'string' ? ` · ${c.details.reason}` : ''}
                {c.details.recurrence_of ? ` · recurrence of finding ${String(c.details.recurrence_of)}` : ''}
              </p>
              {c.status !== 'open' && <p className="mt-1 text-xs text-muted">{c.status === 'resolved' ? 'Resolved' : 'Dismissed'} by {c.resolved_by}, {formatTimestamp(c.resolved_at)}: {c.resolution}</p>}
              {c.status === 'open' && <CaseCloseForm c={c} />}
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}

function RouteSection({detail}: {detail: GroupDetail}) {
  const status = useStatus();
  const channels = [...new Set(detail.orders.map(o => o.channel))];
  const readiness = routeReadiness(detail.group.provider, channels, status.data?.routing ?? detail.routing, status.data?.live_booking_enabled);
  return (
    <Section icon={Route} tone="primary" title="Provider route">
      <div className="flex flex-wrap items-center gap-2 text-sm">
        {channels.map(c => <ChannelBadge key={c} channel={c} />)}
        <span aria-hidden className="text-subtle">→</span>
        <span className="font-semibold text-ink">{PROVIDERS[detail.group.provider] ?? detail.group.provider}</span>
        <Badge tone={readiness.tone}>{readiness.label}</Badge>
      </div>
      <p className="mt-2 text-xs text-muted">{readiness.detail}</p>
      <p className="mt-1 text-xs text-muted">Provider account: {detail.group.provider_account === 'unassigned' ? 'not assigned yet' : detail.group.provider_account}</p>
      {detail.group.provider === 'shippo' && status.data && (
        <p className="mt-1 text-xs text-muted">Shippo mode {status.data.shippo.mode}; API token {status.data.shippo.token_configured ? 'configured' : 'not configured'}.</p>
      )}
    </Section>
  );
}

function DrawerBody({detail}: {detail: GroupDetail}) {
  return (
    <div className="space-y-4">
      <div className="flex items-start gap-3 rounded-xl border border-line bg-surface px-4 py-3 text-sm text-muted">
        <Ban aria-hidden className="mt-0.5 size-4 shrink-0 text-subtle" />
        <p><span className="font-medium text-ink">Purchase and print are not available</span> in this phase (live booking is off). You can prepare parcels and record review decisions; none of them makes an order eligible for purchase on its own.</p>
      </div>
      <StaffBar />
      <OrdersSection orders={detail.orders} />
      <DestinationSection orders={detail.orders} />
      <ItemsSection detail={detail} />
      <ParcelSection detail={detail} />
      <EvidenceSection orders={detail.orders} />
      <RequirementsSection detail={detail} />
      <FindingsSection detail={detail} />
      <RouteSection detail={detail} />
    </div>
  );
}

export function GroupDrawer({groupId, onClose, queueGroup, returnFocusTo}: {groupId: number | null; onClose: () => void; queueGroup: QueueGroup | null; returnFocusTo?: React.RefObject<HTMLElement | null>}) {
  const detail = useGroupDetail(groupId);
  const title = queueGroup?.main_ref ?? detail.data?.orders[0]?.platform_order_ref ?? 'Order details';
  return (
    <Sheet open={groupId != null} onOpenChange={open => !open && onClose()}>
      <SheetContent aria-describedby="drawer-desc" onCloseAutoFocus={e => {
        // Return keyboard focus to the row's "View details" button that opened the drawer.
        if (returnFocusTo?.current?.isConnected) { e.preventDefault(); returnFocusTo.current.focus(); }
      }}>
        <div className="border-b border-line bg-surface px-5 py-4 pr-14">
          <div className="flex items-center gap-3">
            <IconTile icon={Boxes} tone="primary" />
            <div className="min-w-0">
              <SheetTitle className="flex items-center gap-1 font-mono text-base font-semibold text-ink break-all">
                {title}
                {queueGroup && <CopyButton value={queueGroup.main_ref} label={`Copy order reference ${queueGroup.main_ref}`} />}
              </SheetTitle>
              <SheetDescription id="drawer-desc" className="text-xs text-muted">
                Fulfilment group {queueGroup?.group_key ?? groupId}
                {queueGroup && queueGroup.order_count > 1 ? ` · ${queueGroup.order_count} orders merged in the OMS` : ''}
                {detail.data ? ` · state: ${detail.data.group.state}` : ''}
              </SheetDescription>
            </div>
          </div>
        </div>
        <div className="flex-1 overflow-y-auto px-4 py-4 sm:px-5">
          {detail.isPending && groupId != null ? (
            <div className="space-y-4" aria-busy="true" aria-label="Loading order details">
              {[0, 1, 2].map(i => <Skeleton key={i} className="h-36 w-full rounded-2xl" />)}
            </div>
          ) : detail.isError && !detail.data ? (
            <ErrorState title="Order details could not be loaded" message={detail.error.message} onRetry={() => detail.refetch()} retrying={detail.isFetching} />
          ) : detail.data ? (
            <DrawerBody detail={detail.data} />
          ) : null}
        </div>
      </SheetContent>
    </Sheet>
  );
}
