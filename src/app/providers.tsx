'use client';

import * as React from 'react';
import {QueryClient, QueryClientProvider} from '@tanstack/react-query';
import {MotionConfig} from 'motion/react';
import {TooltipProvider} from '@/client/components/ui/tooltip';

export function Providers({children}: {children: React.ReactNode}) {
  const [client] = React.useState(() => new QueryClient({
    defaultOptions: {
      queries: {
        // Keep showing the last good data during background refreshes and after a failed refresh.
        staleTime: 15_000,
        retry: 1,
        refetchOnWindowFocus: true,
      },
    },
  }));
  return (
    <QueryClientProvider client={client}>
      {/* Motion follows the operating-system reduced-motion setting. */}
      <MotionConfig reducedMotion="user" transition={{duration: 0.2}}>
        <TooltipProvider delayDuration={250}>{children}</TooltipProvider>
      </MotionConfig>
    </QueryClientProvider>
  );
}
