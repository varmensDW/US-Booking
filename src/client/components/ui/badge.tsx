import * as React from 'react';
import {cva, type VariantProps} from 'class-variance-authority';
import {cn} from '@/client/lib/utils';

// Status badges always carry a text label; colour is never the only signal.
const badgeVariants = cva(
  'inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-xs font-medium whitespace-nowrap [&_svg]:size-3.5 [&_svg]:shrink-0',
  {
    variants: {
      tone: {
        neutral: 'border-line bg-canvas text-muted',
        primary: 'border-primary-line bg-primary-soft text-primary',
        teal: 'border-teal-line bg-teal-soft text-teal-strong',
        review: 'border-review-line bg-review-soft text-review',
        danger: 'border-danger-line bg-danger-soft text-danger',
        success: 'border-success-line bg-success-soft text-success',
        info: 'border-info-line bg-info-soft text-info',
        violet: 'border-violet-line bg-violet-soft text-violet',
        orange: 'border-orange-line bg-orange-soft text-orange',
      },
    },
    defaultVariants: {tone: 'neutral'},
  },
);

export type BadgeTone = NonNullable<VariantProps<typeof badgeVariants>['tone']>;

export function Badge({className, tone, ...props}: React.ComponentProps<'span'> & VariantProps<typeof badgeVariants>) {
  return <span data-slot="badge" className={cn(badgeVariants({tone}), className)} {...props} />;
}
