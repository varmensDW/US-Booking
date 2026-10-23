'use client';

import * as React from 'react';
import {Ban, Database, KeyRound, Route, ServerCrash, ShieldCheck, Workflow} from 'lucide-react';
import {Card} from '@/client/components/ui/card';
import {Badge} from '@/client/components/ui/badge';
import {Skeleton} from '@/client/components/ui/skeleton';
import {ErrorState, IconTile, ChannelBadge} from '@/client/components/bits';
import {useStatus} from '@/client/lib/api';
import {PROVIDERS, routeReadiness} from '@/client/lib/domain';
import {formatTimestamp} from '@/client/lib/format';

const ROUTES: Array<{channel: string; provider: string}> = [
  {channel: 'SHOPIFY', provider: 'shippo'},
  {channel: 'EBAY', provider: 'shippo'},
  {channel: 'AMAZON', provider: 'amazon_seller_central'},
  {channel: 'WAYFAIR', provider: 'wayfair_partner'},
];

function Row({label, children}: {label: string; children: React.ReactNode}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-t border-line py-2.5 text-sm first:border-t-0">
      <span className="text-muted">{label}</span>
      <span className="text-right text-ink">{children}</span>
    </div>
  );
}

export function SettingsView() {
  const status = useStatus();
  if (status.isPending) {
    return <div className="grid gap-5 lg:grid-cols-2" aria-busy="true">{[0, 1, 2, 3].map(i => <Skeleton key={i} className="h-48 rounded-2xl" />)}</div>;
  }
  if (status.isError && !status.data) {
    return <Card><ErrorState title="Status could not be checked" message={status.error.message} onRetry={() => status.refetch()} retrying={status.isFetching} /></Card>;
  }
  const s = status.data!;
  return (
    <div className="space-y-5">
      <p className="text-sm text-muted">Checked {formatTimestamp(s.checked_at)}. Connection settings are read-only here: they are changed in the project <code className="rounded bg-surface px-1 font-mono text-xs">.env</code> file on the server, and values are never shown. Package defaults are set under Package Profiles.</p>
      <div className="grid gap-5 lg:grid-cols-2">
        <Card className="p-5">
          <div className="mb-3 flex items-center gap-3"><IconTile icon={Database} tone="teal" size="sm" /><h2 className="text-sm font-semibold">Connections</h2></div>
          <Row label="Booking database">
            <Badge tone={s.booking.ok ? 'success' : 'danger'}>{s.booking.ok ? 'Connected' : 'Unavailable'}</Badge>
          </Row>
          <p className="pb-2 text-xs text-muted">{s.booking.ok ? `${s.booking.database} · role ${s.booking.role} · read-only check` : s.booking.detail}</p>
          <Row label="OMS (read-only)">
            <Badge tone={s.oms.ok ? 'success' : 'danger'}>{s.oms.ok ? 'Connected' : 'Unavailable'}</Badge>
          </Row>
          <p className="pb-2 text-xs text-muted">{s.oms.ok ? `${s.oms.database} · role ${s.oms.role} · checked with a read-only query, no import` : s.oms.detail}</p>
          <Row label="Sync Orders">
            <Badge tone={s.sync_available ? 'success' : 'danger'}>{s.sync_available ? 'Available' : 'Unavailable'}</Badge>
          </Row>
          {!s.sync_available && <p className="text-xs text-danger">{s.sync_unavailable_reason}</p>}
        </Card>

        <Card className="p-5">
          <div className="mb-3 flex items-center gap-3"><IconTile icon={Ban} tone="danger" size="sm" /><h2 className="text-sm font-semibold">Booking and printing</h2></div>
          <Row label="Live booking (ENABLE_LIVE_BOOKING)"><Badge tone={s.live_booking_enabled ? 'danger' : 'neutral'}>{s.live_booking_enabled ? 'On (not used in this phase)' : 'Off'}</Badge></Row>
          <Row label="Purchase labels"><Badge tone="neutral">Not available in this phase</Badge></Row>
          <Row label="Print labels"><Badge tone="neutral">Not available in this phase</Badge></Row>
          <Row label="Role setup"><span className="font-mono text-xs">{s.role_mode}</span></Row>
        </Card>

        <Card className="p-5 lg:col-span-2">
          <div className="mb-3 flex items-center gap-3"><IconTile icon={Route} tone="primary" size="sm" /><h2 className="text-sm font-semibold">Routes and integration readiness</h2></div>
          <p className="mb-3 text-xs text-muted">Readiness comes from the routing rules stored in the booking database ({s.routing.length} configured). A route without a verified rule cannot be booked.</p>
          <ul className="divide-y divide-line">
            {ROUTES.map(r => {
              const ready = routeReadiness(r.provider, [r.channel], s.routing, s.live_booking_enabled);
              return (
                <li key={r.channel} className="flex flex-wrap items-center gap-3 py-3">
                  <span className="w-28"><ChannelBadge channel={r.channel} /></span>
                  <Workflow aria-hidden className="size-4 text-subtle" />
                  <span className="min-w-44 font-medium text-ink">{PROVIDERS[r.provider]}</span>
                  <Badge tone={ready.tone}>{ready.label}</Badge>
                  <span className="w-full text-xs text-muted sm:w-auto sm:flex-1">{ready.detail}</span>
                </li>
              );
            })}
          </ul>
          <p className="mt-2 text-xs text-muted">Shippo: mode {s.shippo.mode}; API token {s.shippo.token_configured ? 'configured' : 'not configured'}.</p>
        </Card>

        <Card className="p-5">
          <div className="mb-3 flex items-center gap-3"><IconTile icon={KeyRound} tone="violet" size="sm" /><h2 className="text-sm font-semibold">Configuration (names only)</h2></div>
          {s.config.map(c => (
            <Row key={c.name} label={c.name}><Badge tone={c.configured ? 'success' : 'neutral'}>{c.configured ? 'Set' : 'Not set'}</Badge></Row>
          ))}
        </Card>

        <Card className="p-5">
          <div className="mb-3 flex items-center gap-3"><IconTile icon={s.booking.ok ? ShieldCheck : ServerCrash} tone="info" size="sm" /><h2 className="text-sm font-semibold">Applied database migrations</h2></div>
          {s.booking.migrations?.length ? (
            <ul className="space-y-1 font-mono text-xs text-ink">{s.booking.migrations.map(m => <li key={m}>{m}</li>)}</ul>
          ) : <p className="text-sm text-muted">Not available.</p>}
        </Card>
      </div>
    </div>
  );
}
