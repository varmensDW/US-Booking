import {SettingsTabs} from '@/client/components/settings-tabs';

export default function SettingsLayout({children}: {children: React.ReactNode}) {
  return (
    <>
      <SettingsTabs />
      {children}
    </>
  );
}
