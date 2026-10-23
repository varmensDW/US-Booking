import * as React from 'react';
import {cn} from '@/client/lib/utils';

export function Label({className, ...props}: React.ComponentProps<'label'>) {
  return <label className={cn('text-xs font-medium text-muted', className)} {...props} />;
}

export function FieldError({message, id}: {message?: string; id?: string}) {
  if (!message) return null;
  return <p id={id} role="alert" className="text-xs font-medium text-danger">{message}</p>;
}

const control = 'w-full rounded-lg border border-line bg-surface px-3 text-sm text-ink shadow-sm transition-[border-color,box-shadow] duration-150 hover:border-line-strong focus-visible:border-primary focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-primary/25 aria-[invalid=true]:border-danger';

export function Textarea({className, ...props}: React.ComponentProps<'textarea'>) {
  return <textarea className={cn(control, 'min-h-20 py-2 placeholder:text-subtle', className)} {...props} />;
}

// Native select: keyboard and screen-reader behaviour of the platform, styled like Input.
export function NativeSelect({className, ...props}: React.ComponentProps<'select'>) {
  return <select className={cn(control, 'h-9 pr-8', className)} {...props} />;
}
