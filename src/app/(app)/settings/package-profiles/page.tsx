import type {Metadata} from 'next';
import {PackageProfiles} from '@/client/components/package-profiles';

export const metadata: Metadata = {title: 'Package Profiles · Settings · US Booking'};

export default function PackageProfilesPage() {
  return <PackageProfiles />;
}
