// Request checks for state-changing API routes. The app listens on 127.0.0.1 only; these checks
// stop another website open in the same browser from triggering writes (cross-site requests).

// True when the request comes from this app's own pages (or from a non-browser client that sends
// no Origin header, such as curl on the same machine).
export function sameOrigin(req: Request): boolean {
  const origin = req.headers.get('origin');
  if (!origin) return req.headers.get('sec-fetch-site') !== 'cross-site';
  try {
    return new URL(origin).host === req.headers.get('host');
  } catch {
    return false;
  }
}

export function isJson(req: Request): boolean {
  return (req.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase() === 'application/json';
}
