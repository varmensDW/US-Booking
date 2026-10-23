import * as React from 'react';
import {cn} from '@/client/lib/utils';

export function Input({className, ...props}: React.ComponentProps<'input'>) {
  return (
    <input
      data-slot="input"
      className={cn(
        'h-9 w-full rounded-lg border border-line bg-surface px-3 text-sm text-ink shadow-sm placeholder:text-subtle',
        'transition-[border-color,box-shadow] duration-150 hover:border-line-strong focus-visible:border-primary focus-visible:outline-none focus-visible:ring-3 focus-visible:ring-primary/25',
        className,
      )}
      {...props}
    />
  );
}
