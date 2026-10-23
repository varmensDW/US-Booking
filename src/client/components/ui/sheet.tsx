'use client';

import * as React from 'react';
import {Dialog as SheetPrimitive} from 'radix-ui';
import {X} from 'lucide-react';
import {cn} from '@/client/lib/utils';

// Accessible side drawer (Radix Dialog): focus is trapped, Escape closes, focus returns to the
// trigger, and the title/description are announced.
export const Sheet = SheetPrimitive.Root;
export const SheetTitle = SheetPrimitive.Title;
export const SheetDescription = SheetPrimitive.Description;

export function SheetContent({className, children, ...props}: React.ComponentProps<typeof SheetPrimitive.Content>) {
  return (
    <SheetPrimitive.Portal>
      <SheetPrimitive.Overlay
        className="fixed inset-0 z-40 bg-navy/40 backdrop-blur-[1px] data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=closed]:animate-out data-[state=closed]:fade-out-0 duration-200"
      />
      <SheetPrimitive.Content
        className={cn(
          'fixed inset-y-0 right-0 z-50 flex w-full flex-col bg-canvas shadow-drawer sm:max-w-2xl',
          'data-[state=open]:animate-in data-[state=open]:slide-in-from-right data-[state=closed]:animate-out data-[state=closed]:slide-out-to-right duration-200 ease-out',
          className,
        )}
        {...props}
      >
        {children}
        <SheetPrimitive.Close
          className="absolute right-4 top-4 rounded-lg p-1.5 text-muted transition-colors duration-150 hover:bg-surface hover:text-ink"
          aria-label="Close details"
        >
          <X className="size-5" aria-hidden />
        </SheetPrimitive.Close>
      </SheetPrimitive.Content>
    </SheetPrimitive.Portal>
  );
}
