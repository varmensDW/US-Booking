import type {Metadata} from 'next';
import {SettingsView} from '@/client/components/settings-view';

export const metadata: Metadata = {title: 'Settings · US Booking'};

export default function SettingsPage() {
  return <SettingsView />;
}
