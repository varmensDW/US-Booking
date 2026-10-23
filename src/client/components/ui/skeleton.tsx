import * as React from 'react';
import {cn} from '@/client/lib/utils';

// Pulse stops under prefers-reduced-motion (globals.css).
export function Skeleton({className, ...props}: React.ComponentProps<'div'>) {
  return <div aria-hidden className={cn('animate-pulse rounded-md bg-line/80', className)} {...props} />;
}
