import type {Metadata} from 'next';
import {WayfairSandbox} from '@/client/components/wayfair-sandbox';

export const metadata: Metadata = {title: 'Wayfair Sandbox · Settings · US Booking'};

export default function WayfairSandboxPage() {
  return <WayfairSandbox />;
}
