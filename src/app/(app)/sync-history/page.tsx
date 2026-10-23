import type {Metadata} from 'next';
import {SyncHistory} from '@/client/components/sync-history';

export const metadata: Metadata = {title: 'Sync History · US Booking'};

export default function SyncHistoryPage() {
  return <SyncHistory />;
}
