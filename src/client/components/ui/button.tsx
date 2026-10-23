import * as React from 'react';
import {cva, type VariantProps} from 'class-variance-authority';
import {Slot} from 'radix-ui';
import {cn} from '@/client/lib/utils';

const buttonVariants = cva(
  'inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-lg text-sm font-medium transition-[background-color,border-color,color,box-shadow,transform] duration-150 active:scale-[0.97] disabled:pointer-events-none disabled:opacity-55 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*=size-])]:size-4',
  {
    variants: {
      variant: {
        primary: 'bg-primary text-white shadow-sm hover:bg-primary-hover',
        secondary: 'bg-primary-soft text-primary hover:bg-[#E0E7FF]',
        outline: 'border border-line bg-surface text-ink shadow-sm hover:border-line-strong hover:bg-canvas',
        ghost: 'text-muted hover:bg-canvas hover:text-ink',
        teal: 'bg-teal-strong text-white shadow-sm hover:bg-[#115E59]',
      },
      size: {
        sm: 'h-8 px-3 text-[13px]',
        md: 'h-9 px-4',
        lg: 'h-10 px-5',
        icon: 'size-9',
        'icon-sm': 'size-8',
      },
    },
    defaultVariants: {variant: 'primary', size: 'md'},
  },
);

export interface ButtonProps extends React.ComponentProps<'button'>, VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

export function Button({className, variant, size, asChild = false, ...props}: ButtonProps) {
  const Comp = asChild ? Slot.Root : 'button';
  return <Comp data-slot="button" className={cn(buttonVariants({variant, size}), className)} {...props} />;
}

export {buttonVariants};
