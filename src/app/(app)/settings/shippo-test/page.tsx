import type {Metadata} from 'next';
import {ShippoTest} from '@/client/components/shippo-test';

export const metadata: Metadata = {title: 'Shippo Test · Settings · US Booking'};

export default function ShippoTestPage() {
  return <ShippoTest />;
}
