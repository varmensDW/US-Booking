import * as React from 'react';
import {cn} from '@/client/lib/utils';

export function Card({className, ...props}: React.ComponentProps<'div'>) {
  return <div data-slot="card" className={cn('rounded-2xl border border-line bg-surface shadow-card', className)} {...props} />;
}

export function CardHeader({className, ...props}: React.ComponentProps<'div'>) {
  return <div className={cn('flex items-start justify-between gap-3 px-5 pt-5', className)} {...props} />;
}

export function CardTitle({className, ...props}: React.ComponentProps<'h3'>) {
  return <h3 className={cn('text-sm font-semibold text-ink', className)} {...props} />;
}

export function CardContent({className, ...props}: React.ComponentProps<'div'>) {
  return <div className={cn('px-5 pb-5 pt-3', className)} {...props} />;
}
