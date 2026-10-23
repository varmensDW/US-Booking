'use client';

import * as React from 'react';
import {Tooltip as TooltipPrimitive} from 'radix-ui';
import {cn} from '@/client/lib/utils';

export const TooltipProvider = TooltipPrimitive.Provider;

export function Tooltip({content, children, side = 'top'}: {content: React.ReactNode; children: React.ReactNode; side?: 'top' | 'bottom' | 'left' | 'right'}) {
  return (
    <TooltipPrimitive.Root>
      <TooltipPrimitive.Trigger asChild>{children}</TooltipPrimitive.Trigger>
      <TooltipPrimitive.Portal>
        <TooltipPrimitive.Content
          side={side}
          sideOffset={6}
          className={cn(
            'z-50 max-w-xs rounded-lg bg-navy px-3 py-2 text-xs leading-relaxed text-navy-text shadow-raised',
            'data-[state=delayed-open]:animate-in data-[state=delayed-open]:fade-in-0 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 duration-150',
          )}
        >
          {content}
          <TooltipPrimitive.Arrow className="fill-navy" />
        </TooltipPrimitive.Content>
      </TooltipPrimitive.Portal>
    </TooltipPrimitive.Root>
  );
}
