'use client';

import * as React from 'react';
import {motion} from 'motion/react';
import {
  AlertTriangle, Check, CloudOff, Copy, Globe, Inbox, Package, RefreshCw, ShoppingBag, Sofa, Tag, type LucideIcon,
} from 'lucide-react';
import {Badge} from '@/client/components/ui/badge';
import {Button} from '@/client/components/ui/button';
import {Tooltip} from '@/client/components/ui/tooltip';
import {cn} from '@/client/lib/utils';
import {CHANNELS, countryName, type GroupDestination} from '@/client/lib/domain';
import {formatTimestamp} from '@/client/lib/format';

const TILE_TONES = {
  primary: 'bg-primary-soft text-primary',
  teal: 'bg-teal-soft text-teal-strong',
  review: 'bg-review-soft text-review',
  danger: 'bg-danger-soft text-danger',
  success: 'bg-success-soft text-success',
  info: 'bg-info-soft text-info',
  violet: 'bg-violet-soft text-violet',
  orange: 'bg-orange-soft text-orange',
  neutral: 'bg-canvas text-muted',
} as const;
export type TileTone = keyof typeof TILE_TONES;

// Coloured icon container. Decorative: the adjacent text always carries the meaning.
export function IconTile({icon: Icon, tone = 'primary', size = 'md', className}: {icon: LucideIcon; tone?: TileTone; size?: 'sm' | 'md' | 'lg'; className?: string}) {
  const box = size === 'lg' ? 'size-11 rounded-xl' : size === 'sm' ? 'size-7 rounded-lg' : 'size-9 rounded-xl';
  const ico = size === 'lg' ? 'size-5' : size === 'sm' ? 'size-3.5' : 'size-[18px]';
  return (
    <span aria-hidden className={cn('inline-flex shrink-0 items-center justify-center', box, TILE_TONES[tone], className)}>
      <Icon className={ico} />
    </span>
  );
}

const CHANNEL_ICONS: Record<string, LucideIcon> = {Package, Tag, ShoppingBag, Sofa};
export function ChannelBadge({channel}: {channel: string}) {
  const c = CHANNELS[channel];
  const Icon = c ? CHANNEL_ICONS[c.icon] : Tag;
  return (
    <Badge tone={c?.tone ?? 'neutral'}>
      <Icon aria-hidden />
      {c?.label ?? channel}
    </Badge>
  );
}

// Crisp SVG flag (flag-icons) with the country name. Only ever rendered for a confirmed destination.
export function CountryFlag({iso2, className}: {iso2: string; className?: string}) {
  return (
    <span className={cn('inline-flex items-center gap-2 whitespace-nowrap', className)}>
      <span aria-hidden className={`fi fi-${iso2.toLowerCase()} rounded-[3px] shadow-[0_0_0_1px_rgb(15_23_42/0.12)]`} style={{width: '1.333em', height: '1em'}} />
      <span className="font-medium text-ink">{countryName(iso2)}</span>
    </span>
  );
}

export function NotConfirmed({label = 'Country not confirmed', className}: {label?: string; className?: string}) {
  return (
    <span className={cn('inline-flex items-center gap-2 whitespace-nowrap text-review', className)}>
      <Globe aria-hidden className="size-4 shrink-0" />
      <span className="font-medium">{label}</span>
    </span>
  );
}

export function DestinationCell({dest}: {dest: GroupDestination}) {
  if (dest.kind === 'confirmed') return <CountryFlag iso2={dest.iso2} />;
  if (dest.kind === 'conflict') {
    return (
      <span className="inline-flex items-center gap-2 text-danger">
        <AlertTriangle aria-hidden className="size-4" />
        <span className="font-medium">Destination conflict</span>
      </span>
    );
  }
  if (dest.kind === 'mixed') {
    return (
      <span className="inline-flex flex-wrap items-center gap-3">
        {dest.iso2s.map(i => <CountryFlag key={i} iso2={i} />)}
      </span>
    );
  }
  return (
    <span className="flex flex-col">
      <NotConfirmed />
      {dest.total > 1 && <span className="pl-6 text-xs text-muted">{dest.confirmed} of {dest.total} orders confirmed</span>}
    </span>
  );
}

export function CopyButton({value, label}: {value: string; label: string}) {
  const [copied, setCopied] = React.useState(false);
  const [failed, setFailed] = React.useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      setFailed(false);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setFailed(true);
    }
  };
  return (
    <Tooltip content={failed ? 'Copy failed: select the text instead' : copied ? 'Copied' : label}>
      <button
        type="button"
        onClick={copy}
        aria-label={label}
        className="inline-flex size-7 items-center justify-center rounded-md text-subtle transition-colors duration-150 hover:bg-primary-soft hover:text-primary"
      >
        <motion.span key={copied ? 'ok' : 'copy'} initial={{scale: 0.6, opacity: 0}} animate={{scale: 1, opacity: 1}} transition={{duration: 0.15}}>
          {copied ? <Check className="size-3.5 text-success" aria-hidden /> : <Copy className="size-3.5" aria-hidden />}
        </motion.span>
        <span className="sr-only" aria-live="polite">{copied ? 'Copied' : ''}</span>
      </button>
    </Tooltip>
  );
}

export function EmptyState({title, children, icon = Inbox}: {title: string; children?: React.ReactNode; icon?: LucideIcon}) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 px-6 py-14 text-center">
      <IconTile icon={icon} tone="primary" size="lg" />
      <p className="text-base font-semibold text-ink">{title}</p>
      {children && <div className="max-w-md text-sm text-muted">{children}</div>}
    </div>
  );
}

export function ErrorState({title, message, onRetry, retrying}: {title: string; message: string; onRetry?: () => void; retrying?: boolean}) {
  return (
    <div role="alert" className="flex flex-col items-center justify-center gap-3 px-6 py-14 text-center">
      <IconTile icon={CloudOff} tone="danger" size="lg" />
      <p className="text-base font-semibold text-ink">{title}</p>
      <p className="max-w-lg text-sm text-muted">{message}</p>
      {onRetry && (
        <Button variant="outline" onClick={onRetry} disabled={retrying}>
          <RefreshCw aria-hidden className={cn(retrying && 'animate-spin')} />
          {retrying ? 'Retrying…' : 'Try again'}
        </Button>
      )}
    </div>
  );
}

export function StaleBanner({message, dataTime}: {message: string; dataTime: string | null | undefined}) {
  return (
    <div role="status" className="flex items-start gap-3 rounded-xl border border-review-line bg-review-soft px-4 py-3 text-sm text-review">
      <AlertTriangle aria-hidden className="mt-0.5 size-4 shrink-0" />
      <p>
        <span className="font-semibold">Showing earlier data</span> (loaded {formatTimestamp(dataTime)}). The latest refresh failed: {message}
      </p>
    </div>
  );
}

// A titled panel in the order drawer.
export function Section({icon, tone, title, children, aside}: {icon: LucideIcon; tone: TileTone; title: string; children: React.ReactNode; aside?: React.ReactNode}) {
  return (
    <section className="rounded-2xl border border-line bg-surface p-4 shadow-card sm:p-5" aria-label={title}>
      <div className="mb-3 flex items-center gap-3">
        <IconTile icon={icon} tone={tone} size="sm" />
        <h3 className="flex-1 text-sm font-semibold text-ink">{title}</h3>
        {aside}
      </div>
      {children}
    </section>
  );
}

// The database's explanation when a staff action is refused (stale data, a lock, invalid input).
export function ActionMessage({error}: {error: Error | null}) {
  if (!error) return null;
  return (
    <div role="alert" className="flex items-start gap-2 rounded-lg border border-danger-line bg-danger-soft px-3 py-2 text-xs text-danger">
      <AlertTriangle aria-hidden className="mt-0.5 size-3.5 shrink-0" />
      <p>{error.message}</p>
    </div>
  );
}
