// Exercises the dashboard's Wayfair SANDBOX API against tests/wayfair/mock-server.mjs. The app must
// be a synthetic instance (USB_ENV_FILE) whose env file sets WAYFAIR_MODE=sandbox,
// WAYFAIR_SANDBOX_CLIENT_ID/SECRET (as the mock expects), WAYFAIR_SUPPLIER_ID=12345 and
// WAYFAIR_TEST_MOCK_URL=<mock>. usage: node run-mock-tests.mjs <appBase> <mockBase> <client secret> <server log file>
import fs from 'node:fs';

const [app, mock, secret, serverLog] = process.argv.slice(2);
const staff = 'Synthetic Tester';
const results = [];
const check = (label, ok, extra = '') => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} [W ${label}]${extra ? ' ' + extra : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const responses = [];
async function op(name, body) {
  const r = await fetch(`${app}/api/wayfair-sandbox/${name}`, {method: 'POST', headers: {'Content-Type': 'application/json', Origin: app}, body: JSON.stringify(body)});
  const text = await r.text();
  responses.push(text);
  return {status: r.status, body: JSON.parse(text)};
}
const scenario = s => fetch(`${mock}/__scenario`, {method: 'POST', body: JSON.stringify(s)});
const mockState = async () => (await fetch(`${mock}/__state`)).json();
const status = async () => { const r = await fetch(`${app}/api/wayfair-sandbox`); const t = await r.text(); responses.push(t); return JSON.parse(t); };

let s = await status();
check('status before any call: configured, no auth or order result yet, live booking off',
  s.config.usable && s.config.mock && s.auth === null && s.orders === null && s.live_booking_enabled === false && s.config.order_import_enabled === false);

// Credentials.
await scenario({token: 'reject'});
let r = await op('auth', {});
check('rejected credentials reported as an authentication failure', r.status === 502 && r.body.kind === 'auth' && /rejected the sandbox credentials/.test(r.body.error), r.body.error);
s = await status();
check('status shows the failed authentication separately', s.auth?.ok === false && s.orders === null);
await scenario({token: 'down'});
r = await op('auth', {});
check('token endpoint outage reported as a provider error', r.status === 502 && r.body.kind === 'provider', r.body.error);
await scenario({token: 'ok'});
r = await op('auth', {});
check('valid credentials give a sandbox token', r.status === 200 && r.body.result.ok === true && r.body.result.expires_at);

// Order access.
await scenario({orders: 'empty'});
r = await op('orders', {limit: 5, has_response: false});
check('empty sandbox answer: no orders, explicit note that this proves nothing about labels',
  r.status === 200 && r.body.result.orders.length === 0 && /does not show that registration or label access works/.test(r.body.result.note));
await scenario({orders: 'error'});
r = await op('orders', {limit: 5, has_response: false});
check('order permission error reported, not shown as an empty list', r.status === 502 && r.body.kind === 'graphql', r.body.error);
s = await status();
check('status shows the failed order access separately from authentication', s.orders?.ok === false && s.auth?.ok === true);
await scenario({orders: 'ok'});
r = await op('orders', {limit: 10, has_response: null});
const orders = r.body.result?.orders ?? [];
check('sample of sandbox orders returned with account check',
  r.status === 200 && orders.length === 6 && orders.find(o => o.po_number === 'TEST_1').account_match === 'supplier'
    && orders.find(o => o.po_number === 'TEST_2').account_match === 'mismatch');

// Token expiry and revocation.
await scenario({expiresIn: 2});
await op('auth', {});
let before = (await mockState()).calls.token;
await sleep(2500);
r = await op('orders', {limit: 1, has_response: null});
let after = (await mockState()).calls.token;
check('an expired token is renewed before the next call', r.status === 200 && after > before, `token requests ${before} -> ${after}`);
await scenario({expiresIn: 3600});
await op('auth', {});
await fetch(`${mock}/__revoke`, {method: 'POST'});
before = (await mockState()).calls.token;
r = await op('orders', {limit: 1, has_response: null});
after = (await mockState()).calls.token;
check('a token rejected with 401 is renewed once and the query repeated', r.status === 200 && after === before + 1);

// Registration.
r = await op('register', {staff, po_number: 'TEST_2', package: null});
check('a PO of another supplier is refused (wrong account)', r.status === 409 && /matches neither/.test(r.body.error), r.body.error);
r = await op('register', {staff, po_number: 'NOT_IN_SANDBOX', package: null});
check('a PO the sandbox does not return is refused', r.status === 404, r.body.error);
r = await op('check-registration', {po_number: 'TEST_1'});
check('static sandbox events for other POs are not taken as an existing registration',
  r.status === 200 && r.body.result.events_returned === 1 && r.body.result.matching.length === 0 && /static examples/.test(r.body.result.note));
let regBefore = (await mockState()).calls.register;
r = await op('register', {staff, po_number: 'TEST_1', package: {length: '30', width: '20', height: '15', weight: '2'}});
check('registration with explicitly entered test measurements succeeds',
  r.status === 200 && r.body.result.result === 'succeeded' && r.body.result.summary.tracking[0].tracking_number === 'MOCKTRK-TEST_1');
const body = JSON.parse((await mockState()).bodies.at(-1));
check('package units sent as documented (CARTON, KILOGRAMS, CENTIMETERS, one entry per unit)',
  body.variables.registrationInput.packageUnits[0].weight.unit === 'KILOGRAMS'
    && body.variables.registrationInput.packageUnits[0].dimensions.length.unit === 'CENTIMETERS'
    && body.variables.registrationInput.packageUnits[0].containedParts.length === 2
    && !('warehouseId' in body.variables.registrationInput));
r = await op('register', {staff, po_number: 'TEST_1', package: null});
check('a registered PO is not registered again (no second call to Wayfair)',
  r.status === 409 && (await mockState()).calls.register === regBefore + 1, r.body.error);
await scenario({register: 'graphql_error'});
r = await op('register', {staff, po_number: 'TEST_3', package: null});
check('a rejected registration is recorded as failed with Wayfair\'s message', r.status === 200 && r.body.result.result === 'failed'
  && /not part of this purchase order/.test(r.body.result.error));
await scenario({register: 'ok'});
r = await op('register', {staff, po_number: 'TEST_3', package: null});
check('a failed registration can be retried by staff', r.status === 200 && r.body.result.result === 'succeeded');
const wfManaged = JSON.parse((await mockState()).bodies.at(-1));
check('Wayfair-managed packaging: no packageUnits (and no measurement fields) sent',
  /register\(/.test(wfManaged.query) && !('packageUnits' in wfManaged.variables.registrationInput)
    && !/weight|dimensions|length/i.test(JSON.stringify(wfManaged.variables)));
await scenario({register: '500'});
r = await op('register', {staff, po_number: 'TEST_4', package: null});
check('HTTP 500 during registration is recorded as unknown', r.status === 200 && r.body.result.result === 'unknown');
regBefore = (await mockState()).calls.register;
await scenario({register: 'ok'});
r = await op('register', {staff, po_number: 'TEST_4', package: null});
check('an unknown outcome is never repeated automatically', r.status === 409 && /unknown/.test(r.body.error)
  && (await mockState()).calls.register === regBefore);
s = await status();
const unknown = s.records.registrations.find(x => x.po_number === 'TEST_4' && x.state === 'unknown');
r = await op('resolve', {staff, id: unknown.id, outcome: 'resolved_not_registered', evidence: 'synthetic: mock confirms no registration'});
check('staff resolve the unknown outcome with evidence', r.status === 200 && r.body.result.state === 'resolved_not_registered');
await scenario({register: 'timeout'});
const t0 = Date.now();
r = await op('register', {staff, po_number: 'TEST_5', package: null});
check('a timed-out registration is recorded as unknown', r.status === 200 && r.body.result.result === 'unknown' && Date.now() - t0 >= 19000,
  `${Math.round((Date.now() - t0) / 1000)} s`);
await scenario({register: 'ok'});

// An existing Wayfair registration found by lookup (poNumber returned as a number) blocks registering.
await scenario({events: 'numeric_match'});
regBefore = (await mockState()).calls.register;
r = await op('register', {staff, po_number: 'CS123456789', package: null});
const lookupBody = JSON.parse((await mockState()).bodies.at(-1));
check('lookup filters on the nine digits and a numeric poNumber match counts as already registered',
  r.status === 200 && r.body.result.result === 'existing' && lookupBody.variables.filters[0].equals === '123456789'
    && (await mockState()).calls.register === regBefore);
r = await op('register', {staff, po_number: 'CS123456789', package: null});
check('the found registration is recorded and blocks later attempts', r.status === 409 && /found_existing/.test(r.body.error));
await scenario({events: 'static'});

// Labels.
s = await status();
const reg1 = s.records.registrations.find(x => x.po_number === 'TEST_1' && x.state === 'succeeded');
r = await op('fetch-label', {staff, registration_id: reg1.id});
check('sandbox label downloaded and stored with its hash', r.status === 200 && r.body.result.content_type === 'application/pdf' && /^[0-9a-f]{64}$/.test(r.body.result.sha256));
const lbl = await fetch(`${app}/api/wayfair-sandbox/labels/${r.body.result.label_id}`);
const disp = lbl.headers.get('content-disposition') ?? '';
check('label served for preview/download, file name marked SANDBOX', lbl.status === 200 && (await lbl.text()).startsWith('%PDF') && /SANDBOX-TEST_1-/.test(disp));
const callsBeforeReopen = (await mockState()).calls;
for (const q of ['?inline=1', '', '']) await (await fetch(`${app}/api/wayfair-sandbox/labels/${r.body.result.label_id}${q}`)).arrayBuffer();
const callsAfterReopen = (await mockState()).calls;
check('reopening the stored label (preview, download, reprint) contacts Wayfair zero times and registers nothing',
  callsAfterReopen.register === callsBeforeReopen.register && callsAfterReopen.label === callsBeforeReopen.label
    && callsAfterReopen.graphql === callsBeforeReopen.graphql);
const reg5 = s.records.registrations.find(x => x.po_number === 'TEST_5');
r = await op('fetch-label', {staff, registration_id: reg5.id});
check('no label for a PO whose registration is unknown', r.status === 409, r.body.error);

// Request guards and isolation.
const xs = await fetch(`${app}/api/wayfair-sandbox/auth`, {method: 'POST', headers: {'Content-Type': 'application/json', Origin: 'https://evil.example'}, body: '{}'});
check('cross-site request refused', xs.status === 403);
const q = await (await fetch(`${app}/api/queue`)).json();
check('live tables untouched: no booking attempts, labels or new groups from sandbox data',
  q.totals.booking_attempts === 0 && q.totals.labels === 0 && !q.groups.some(g => /TEST_\d/.test(g.platform_order_refs.join(' '))));
const leaked = [...responses, fs.existsSync(serverLog) ? fs.readFileSync(serverLog, 'utf8') : '']
  .some(t => t.includes(secret) || /mock-token-/.test(t));
check('no client secret or access token in any API response or the server log', !leaked);
console.log(`${results.filter(Boolean).length}/${results.length} passed`);
process.exit(results.every(Boolean) ? 0 : 1);
