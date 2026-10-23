// Timestamps from the booking database (timestamptz) are shown in the viewer's time zone WITH the
// zone name. OMS order dates are raw values whose source zone is not verified: they are shown as
// written in the OMS and labelled as such, never converted.

const withZone = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZoneName: 'short',
});
const timeWithZone = new Intl.DateTimeFormat('en-GB', {hour: '2-digit', minute: '2-digit', second: '2-digit', timeZoneName: 'short'});

export function formatTimestamp(value: string | null | undefined): string {
  if (!value) return 'never';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? value : withZone.format(d);
}

export function formatTime(value: string | null | undefined): string {
  if (!value) return '';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? value : timeWithZone.format(d);
}

export function formatRelative(value: string | null | undefined, now = Date.now()): string {
  if (!value) return 'never';
  const diff = Math.round((now - new Date(value).getTime()) / 1000);
  if (Number.isNaN(diff)) return value;
  if (diff < 45) return 'just now';
  if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.round(diff / 3600)} h ago`;
  return `${Math.round(diff / 86400)} d ago`;
}

// "2026-10-22T23:17:22" -> "22 Oct 2026, 23:17" without any time-zone conversion.
export function formatOmsRaw(value: string | null | undefined): string {
  if (!value) return 'not recorded';
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(value);
  if (!m) return value;
  const month = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][Number(m[2]) - 1];
  return `${Number(m[3])} ${month} ${m[1]}, ${m[4]}:${m[5]}`;
}

export const OMS_TIME_NOTE = 'OMS time as recorded; time zone not verified';
