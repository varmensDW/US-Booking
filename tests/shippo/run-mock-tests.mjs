// Exercises the dashboard's Shippo TEST API against tests/shippo/mock-server.mjs. The app must be
// a synthetic instance (USB_ENV_FILE) whose env file sets SHIPPO_MODE=test, SHIPPO_API_TOKEN (a
// shippo_test_ token matching what the mock expects), SHIPPO_SHIP_FROM_* (country US) and
// SHIPPO_TEST_MOCK_URL=<mock>. SHIPPO_SHIP_RETURN_* is deliberately left UNSET in that env file;
// this script sets it mid-run (same trick as the live-token check) to exercise the configured path
// without needing a second app instance.
// usage: node run-mock-tests.mjs <appBase> <mockBase> <token> <envFile> <serverLogFile>
import fs from 'node:fs';

const [app, mock, token, envFile, serverLog] = process.argv.slice(2);
const staff = 'Synthetic Tester';
const results = [];
const check = (label, ok, extra = '') => { results.push(ok); console.log(`${ok ? 'PASS' : 'FAIL'} [S ${label}]${extra ? ' ' + extra : ''}`); };
const responses = [];
async function op(name, body) {
  const r = await fetch(`${app}/api/shippo-test/${name}`, {method: 'POST', headers: {'Content-Type': 'application/json', Origin: app}, body: JSON.stringify(body)});
  const text = await r.text();
  responses.push(text);
  return {status: r.status, body: JSON.parse(text)};
}
const scenario = s => fetch(`${mock}/__scenario`, {method: 'POST', body: JSON.stringify(s)});
const mockState = async () => (await fetch(`${mock}/__state`)).json();
const status = async () => { const r = await fetch(`${app}/api/shippo-test`); const t = await r.text(); responses.push(t); return JSON.parse(t); };
// The staff-selected rate, in full, is what the app sends to /purchase as rate_summary -- exactly
// what a real "click the radio button" selection would carry, carrier_account_id included.
const pick = (rates, service) => rates.find(x => x.service === service);
const purchaseArgs = (shipmentId, rate) => ({shipment_id: shipmentId, rate_object_id: rate.rate_object_id, rate_summary: rate});

const US_TO = {name: 'Mr Hippo', street1: 'Broadway 1', city: 'New York', state: 'NY', zip: '10007', country: 'US', phone: '+1 555 341 9393', email: 'mrhippo@shippo.com'};
const CA_TO = {name: 'Mr Hippo', street1: '100 Queen St W', city: 'Toronto', state: 'ON', zip: 'M5H 2N2', country: 'CA', phone: '+1 555 341 9393', email: 'mrhippo@shippo.com'};
const PARCEL = {length: '9', width: '6', height: '6', dimension_unit: 'in', weight: '2', weight_unit: 'kg'};
const CUSTOMS = {
  contents_type: 'MERCHANDISE', non_delivery_option: 'RETURN', certify: true, certify_signer: 'Synthetic Tester',
  items: [{description: 'Synthetic test item', quantity: 1, net_weight: '2', mass_unit: 'kg', value_amount: '25.00', value_currency: 'USD', origin_country: 'US'}],
  eel_pfc: 'NOEEI_30_36',
};

let s = await status();
check('status before any call: configured, mock, no auth result yet, live booking off, no label format forced',
  s.config.usable && s.config.mock && s.config.token_is_test && s.auth === null && s.live_booking_enabled === false && s.label_format === null);
check('return address reported as not configured, with an explanation rather than a silent default',
  s.config.ship_return === null && s.config.return_address_configured === false);

// Authentication.
await scenario({auth: 'reject'});
let r = await op('auth', {});
check('rejected token reported as an authentication failure', r.status === 502 && r.body.kind === 'auth', r.body.error);
await scenario({auth: 'down'});
r = await op('auth', {});
check('carrier_accounts outage reported as a provider error', r.status === 502 && r.body.kind === 'provider', r.body.error);
await scenario({auth: 'ok'});
r = await op('auth', {});
check('valid test token confirmed without creating anything', r.status === 200 && r.body.result.ok === true);
let before = (await mockState()).calls;
check('authentication never created a shipment or transaction', before.shipments === 0 && before.transactions === 0);

// Rate shopping: units, carrier_account_id, empty/errored answers, Canada customs requirement.
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
check('US rate shopping returns both mock rates with carrier/service/amount/currency/estimate/carrier_account_id',
  r.status === 200 && r.body.result.rates.length === 2
    && r.body.result.rates.every(x => x.carrier && x.service && x.amount && x.currency && 'estimated_days' in x && x.carrier_account_id));
const usShipmentId = r.body.result.shipment_id;
const usRates = r.body.result.rates;
let sentBody = JSON.parse((await mockState()).bodies.at(-1));
check('units sent to Shippo exactly as entered (distance_unit, mass_unit on the parcel)',
  sentBody.parcels[0].distance_unit === 'in' && sentBody.parcels[0].mass_unit === 'kg' && sentBody.parcels[0].length === '9');
check('no address_return is sent while SHIPPO_SHIP_RETURN_* is not configured', !('address_return' in sentBody));

r = await op('rates', {staff, ship_to: CA_TO, parcel: PARCEL, customs: null});
check('Canada without customs is refused by this app before calling Shippo', r.status === 422 && /Customs information is required/.test(r.body.error), r.body.error);
let shipmentsBefore = (await mockState()).calls.shipments;
check('the refused Canada request never reached Shippo', (await mockState()).calls.shipments === shipmentsBefore);

r = await op('rates', {staff, ship_to: CA_TO, parcel: PARCEL, customs: CUSTOMS});
check('Canada with customs attached gets rates, and the shipment record keeps the customs sent', r.status === 200 && r.body.result.rates.length === 2);
const caShipmentId = r.body.result.shipment_id;
const caRates = r.body.result.rates;
sentBody = JSON.parse((await mockState()).bodies.at(-1));
check('customs_declaration (including the optional eel_pfc) sent to Shippo for the Canada request',
  sentBody.customs_declaration?.items?.[0]?.description === 'Synthetic test item' && sentBody.customs_declaration?.eel_pfc === 'NOEEI_30_36');

await scenario({rates: 'empty'});
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
check('an empty rate answer is shown with a note and the carrier message, not hidden',
  r.status === 200 && r.body.result.rates.length === 0 && /returned no rates/i.test(r.body.result.note)
    && r.body.result.messages.some(m => /no service available/i.test(m.text ?? '')));
await scenario({rates: 'ok'});

// Purchase: explicit rate selection (never cheapest), success with the test-mode marker, and the
// selected rate's carrier/service/amount/currency/carrier_account_id land on the attempt itself
// (not just in rate_summary) -- this is the fix for "carrier not recorded".
const expensive = pick(usRates, 'Priority Mail Express');
r = await op('purchase', {staff, ...purchaseArgs(usShipmentId, expensive)});
check('purchasing the MORE EXPENSIVE, explicitly selected rate succeeds (nothing auto-picks the cheapest)',
  r.status === 200 && r.body.result.state === 'succeeded');
sentBody = JSON.parse((await mockState()).bodies.at(-1));
check('the exact rate id staff selected is what was sent to Shippo, with no label_file_type (dashboard default)',
  sentBody.rate === expensive.rate_object_id && !('label_file_type' in sentBody));
s = await status();
let purchase1 = s.records.purchases.find(p => p.shipment_id === usShipmentId);
check('a succeeded purchase carries Shippo\'s test-mode marker and a tracking number',
  purchase1.test_mode === true && Boolean(purchase1.tracking_number));
check('the attempt itself (not only rate_summary) now carries carrier, service, amount, currency and carrier_account_id',
  purchase1.carrier === expensive.carrier && purchase1.service_level === expensive.service
    && Number(purchase1.amount) === Number(expensive.amount) && purchase1.currency === expensive.currency
    && purchase1.carrier_account_id === expensive.carrier_account_id);

// Once a shipment has a purchased label, it is done: no second purchase, no further rate selection.
r = await op('purchase', {staff, ...purchaseArgs(usShipmentId, pick(usRates, 'Priority Mail'))});
check('a shipment with an already-purchased label refuses a second purchase', r.status === 409 && /already has a purchased label/.test(r.body.error), r.body.error);

// Duplicate clicks / concurrent purchases on the same test shipment.
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const dupShipmentId = r.body.result.shipment_id;
const dupRate = pick(r.body.result.rates, 'Priority Mail');
const txnBefore = (await mockState()).calls.transactions;
const [d1, d2] = await Promise.all([op('purchase', {staff, ...purchaseArgs(dupShipmentId, dupRate)}), op('purchase', {staff, ...purchaseArgs(dupShipmentId, dupRate)})]);
const dupStatuses = [d1.status, d2.status].sort();
check('two concurrent purchase requests for the same test shipment: exactly one is accepted',
  dupStatuses[0] === 200 && dupStatuses[1] === 409);
check('exactly one purchase reached Shippo despite the double click', (await mockState()).calls.transactions === txnBefore + 1);

// An HTTP 500 and a timeout are both recorded as unknown (never a silent failure or a silent retry).
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sid500 = r.body.result.shipment_id;
const rate500 = pick(r.body.result.rates, 'Priority Mail');
await scenario({purchase: '500'});
r = await op('purchase', {staff, ...purchaseArgs(sid500, rate500)});
check('HTTP 500 during purchase is recorded as unknown, not failed or silently succeeded', r.status === 200 && r.body.result.state === 'unknown');
let txnBeforeRepeat = (await mockState()).calls.transactions;
r = await op('purchase', {staff, ...purchaseArgs(sid500, rate500)});
check('an unknown outcome is never retried automatically', r.status === 409 && /unknown/.test(r.body.error) && (await mockState()).calls.transactions === txnBeforeRepeat, r.body.error);

await scenario({purchase: 'timeout'});
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidTimeout = r.body.result.shipment_id;
const rateTimeout = pick(r.body.result.rates, 'Priority Mail');
const t0 = Date.now();
r = await op('purchase', {staff, ...purchaseArgs(sidTimeout, rateTimeout)});
check('a timed-out purchase is recorded as unknown', r.status === 200 && r.body.result.state === 'unknown' && Date.now() - t0 >= 19000,
  `${Math.round((Date.now() - t0) / 1000)} s`);
await scenario({purchase: 'ok'});

// A genuine HTTP 500 with no body gave Shippo no chance to return a transaction id: there is
// nothing to reconcile against, and fetching a label must say so rather than guess. But the
// carrier/service the attempt went after is still known (from the selected rate), so it is not
// lost even though the purchase never completed.
s = await status();
const unknown500 = s.records.purchases.find(p => p.shipment_id === sid500);
check('an unknown purchase with no provider transaction id recorded has none to reconcile with, but keeps the attempted carrier/service',
  unknown500.provider_transaction_id === null && unknown500.carrier === rate500.carrier && unknown500.service_level === rate500.service);
r = await op('resolve', {staff, id: unknown500.id, outcome: 'confirmed_purchased', evidence: 'synthetic: Shippo dashboard confirms this transaction as SUCCESS, test mode'});
check('staff resolve an unknown outcome with evidence', r.status === 200 && r.body.result.state === 'confirmed_purchased');
r = await op('fetch-label', {staff, purchase_id: unknown500.id});
check('fetching a label without a provider transaction id to reconcile against is refused, not guessed', r.status === 409 && /cannot be reconciled/.test(r.body.error), r.body.error);

// 'QUEUED' (a non-definite outcome that DID return a transaction id) is the case that can be
// reconciled: resolving it, then fetching, re-checks Shippo's own record before trusting a label.
await scenario({purchase: 'queued'});
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidQueued = r.body.result.shipment_id;
const rateQueued = pick(r.body.result.rates, 'Priority Mail');
r = await op('purchase', {staff, ...purchaseArgs(sidQueued, rateQueued)});
check('a QUEUED response (no definite outcome) is recorded as unknown', r.status === 200 && r.body.result.state === 'unknown');
await scenario({purchase: 'ok'});
s = await status();
const unknownQueued = s.records.purchases.find(p => p.shipment_id === sidQueued);
check('the QUEUED purchase kept Shippo\'s transaction id for reconciliation', Boolean(unknownQueued.provider_transaction_id));
r = await op('resolve', {staff, id: unknownQueued.id, outcome: 'confirmed_purchased', evidence: 'synthetic: Shippo dashboard confirms this transaction as SUCCESS, test mode'});
check('staff resolve the QUEUED outcome with evidence', r.status === 200 && r.body.result.state === 'confirmed_purchased');
await scenario({reconcile: 'resolved_success'});
let labelCallsBefore = (await mockState()).calls.label;
let txnGetBefore = (await mockState()).calls.transaction_get;
r = await op('fetch-label', {staff, purchase_id: unknownQueued.id});
check('fetching a label for a confirmed-purchased outcome reconciles with Shippo first, then downloads it',
  r.status === 200 && (await mockState()).calls.transaction_get === txnGetBefore + 1 && (await mockState()).calls.label === labelCallsBefore + 1
    && /^[0-9a-f]{64}$/.test(r.body.result.sha256));
await scenario({reconcile: 'none'});

// A rejected (ERROR) and a not-test-mode transaction are recorded, never shown as usable.
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidErr = r.body.result.shipment_id;
const rateErr = pick(r.body.result.rates, 'Priority Mail');
await scenario({purchase: 'error'});
r = await op('purchase', {staff, ...purchaseArgs(sidErr, rateErr)});
check('a rejected (ERROR) transaction is recorded as failed with Shippo\'s message', r.status === 200 && r.body.result.state === 'failed');
r = await op('purchase', {staff, ...purchaseArgs(sidErr, rateErr)});
check('a failed attempt may still be retried on the same test shipment', r.status === 200);
await scenario({purchase: 'error'});
// (leave sidErr's second attempt as 'requested' is avoided -- revert to ok before finishing it)
await scenario({purchase: 'ok'});

r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidNotTest = r.body.result.shipment_id;
const rateNotTest = pick(r.body.result.rates, 'Priority Mail');
await scenario({purchase: 'not_test'});
r = await op('purchase', {staff, ...purchaseArgs(sidNotTest, rateNotTest)});
check('a transaction Shippo did not mark test mode is rejected, not presented as a usable label', r.status === 200 && r.body.result.state === 'rejected_not_test');
s = await status();
const notTestPurchase = s.records.purchases.find(p => p.shipment_id === sidNotTest);
r = await op('fetch-label', {staff, purchase_id: notTestPurchase.id});
check('no label can be fetched for a rejected-not-test purchase', r.status === 409, r.body.error);
await scenario({purchase: 'ok'});

// Stored-label reuse: reopening never buys another label or calls Shippo again.
s = await status();
const succeeded = s.records.purchases.find(p => p.shipment_id === usShipmentId && p.state === 'succeeded');
const callsBeforeFirstFetch = (await mockState()).calls;
r = await op('fetch-label', {staff, purchase_id: succeeded.id});
check('first fetch for a succeeded purchase downloads and stores the label', r.status === 200 && r.body.result.already_stored === false);
const callsAfterFirstFetch = (await mockState()).calls;
check('the first fetch called Shippo exactly once for the label', callsAfterFirstFetch.label === callsBeforeFirstFetch.label + 1);
r = await op('fetch-label', {staff, purchase_id: succeeded.id});
check('a second fetch for the same purchase reuses the stored file, not a new download', r.status === 200 && r.body.result.already_stored === true);
check('the second fetch made no new call to Shippo', (await mockState()).calls.label === callsAfterFirstFetch.label);
const labelId = r.body.result.label_id;
const callsBeforeReopen = (await mockState()).calls;
for (const q of ['?inline=1', '', '']) await (await fetch(`${app}/api/shippo-test/labels/${labelId}${q}`)).arrayBuffer();
const callsAfterReopen = (await mockState()).calls;
check('reopening the stored label (preview, download, reprint) contacts Shippo zero times and buys nothing new',
  callsAfterReopen.transactions === callsBeforeReopen.transactions && callsAfterReopen.label === callsBeforeReopen.label
    && callsAfterReopen.shipments === callsBeforeReopen.shipments);

// Canada: a succeeded international purchase also stores the commercial invoice Shippo returned,
// alongside (not instead of) the label.
const caExpensive = pick(caRates, 'Priority Mail Express');
r = await op('purchase', {staff, ...purchaseArgs(caShipmentId, caExpensive)});
check('Canada test purchase succeeds with the selected (non-cheapest) rate', r.status === 200 && r.body.result.state === 'succeeded');
r = await op('fetch-label', {staff, purchase_id: r.body.result.purchase_id});
check('fetching the label for a Canada purchase also stores the commercial invoice Shippo returned',
  r.status === 200 && r.body.result.customs_invoice !== null);

// Label format: unset by default (no label_file_type sent); setting it applies to the NEXT
// purchase only, and never touches an already-stored label.
r = await op('set-label-format', {staff, label_file_type: 'BOGUS'});
check('an unsupported label format is refused by the route schema', r.status === 422);
r = await op('set-label-format', {staff, label_file_type: 'PDF_4x6'});
check('a supported label format is accepted', r.status === 200 && r.body.result.label_file_type === 'PDF_4x6');
s = await status();
check('the saved label format is reflected in status', s.label_format === 'PDF_4x6');
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidFormat = r.body.result.shipment_id;
const rateFormat = pick(r.body.result.rates, 'Priority Mail');
r = await op('purchase', {staff, ...purchaseArgs(sidFormat, rateFormat)});
sentBody = JSON.parse((await mockState()).bodies.at(-1));
check('the saved label format is sent on the next purchase', sentBody.label_file_type === 'PDF_4x6');
const storedLabelBefore = (await (await fetch(`${app}/api/shippo-test/labels/${labelId}`)).arrayBuffer());
r = await op('set-label-format', {staff, label_file_type: null});
check('the format can be cleared back to the Shippo dashboard default', r.status === 200 && r.body.result.label_file_type === null);
const storedLabelAfter = (await (await fetch(`${app}/api/shippo-test/labels/${labelId}`)).arrayBuffer());
check('changing the format later never alters an already-stored label', Buffer.from(storedLabelBefore).equals(Buffer.from(storedLabelAfter)));

// Recover details: a rate whose /shipments listing omitted carrier_account (simulating the gap in
// attempts made before this fix) still has it recoverable from a direct, read-only GET /rates/{id}
// lookup -- never guessed from the tracking number. The already-saved carrier/service/amount from
// rate_summary are not re-fetched or overwritten, only the missing carrier_account_id is filled.
await scenario({rates: 'no_carrier_account'});
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
check('a rate missing carrier_account_id in the listing is still accepted (recoverable later)',
  r.status === 200 && r.body.result.rates.every(x => !x.carrier_account_id));
const sidGap = r.body.result.shipment_id;
const rateGap = pick(r.body.result.rates, 'Priority Mail');
await scenario({rates: 'ok'});
r = await op('purchase', {staff, ...purchaseArgs(sidGap, rateGap)});
check('the purchase succeeds even without carrier_account_id on the selected rate', r.status === 200 && r.body.result.state === 'succeeded');
s = await status();
const gapPurchase = s.records.purchases.find(p => p.shipment_id === sidGap);
check('the attempt has carrier/service but not carrier_account_id, matching the historical gap', Boolean(gapPurchase.carrier) && !gapPurchase.carrier_account_id);
const rateGetBefore = (await mockState()).calls.rate_get;
r = await op('recover-details', {staff, purchase_id: gapPurchase.id});
check('recover-details looks the rate up read-only and fills carrier_account_id',
  r.status === 200 && r.body.result.carrier_account_id && (await mockState()).calls.rate_get === rateGetBefore + 1);
r = await op('recover-details', {staff, purchase_id: gapPurchase.id});
check('a second recover-details call is a no-op (nothing left missing, no further Shippo lookup)',
  r.status === 200 && (await mockState()).calls.rate_get === rateGetBefore + 1);
await scenario({rates: 'no_carrier_account', rate_lookup: 'not_found'});
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
const sidGap2 = r.body.result.shipment_id;
const rateGap2 = pick(r.body.result.rates, 'Priority Mail');
r = await op('purchase', {staff, ...purchaseArgs(sidGap2, rateGap2)});
await scenario({rates: 'ok'});
s = await status();
const gapPurchase2 = s.records.purchases.find(p => p.shipment_id === sidGap2);
check('this second gap attempt is also missing carrier_account_id, as set up', !gapPurchase2.carrier_account_id);
r = await op('recover-details', {staff, purchase_id: gapPurchase2.id});
check('an expired/missing rate is reported plainly, not treated as an error or a guess',
  r.status === 200 && /no longer has this rate/i.test(r.body.result.note ?? ''), JSON.stringify(r.body));
await scenario({rate_lookup: 'ok'});

// Return address: explicitly configuring it makes it sent as address_return on every request;
// Shippo's documented default for an omitted address_return is still unverified, so this app never
// infers one. (projectEnv() re-reads .env on every call; no app restart needed for this check.)
const envBefore = fs.readFileSync(envFile, 'utf8');
fs.writeFileSync(envFile, envBefore + '\nSHIPPO_SHIP_RETURN_NAME=Returns Dept\nSHIPPO_SHIP_RETURN_STREET1=1 Returns Way\nSHIPPO_SHIP_RETURN_CITY=Reno\n'
  + 'SHIPPO_SHIP_RETURN_STATE=NV\nSHIPPO_SHIP_RETURN_ZIP=89501\nSHIPPO_SHIP_RETURN_COUNTRY=US\nSHIPPO_SHIP_RETURN_PHONE=+1 555 000 1111\nSHIPPO_SHIP_RETURN_EMAIL=returns@example.test\n');
s = await status();
check('once configured, the return address is reported distinctly from the ship-from address', s.config.ship_return?.city === 'Reno' && s.config.return_address_configured === true);
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
sentBody = JSON.parse((await mockState()).bodies.at(-1));
check('address_return is sent, separate from address_from, once explicitly configured',
  sentBody.address_return?.city === 'Reno' && sentBody.address_from?.city !== 'Reno');
fs.writeFileSync(envFile, envBefore);
s = await status();
check('removing the return address restores the "not configured" report (no silent fallback either way)',
  s.config.ship_return === null && s.config.return_address_configured === false);

// A live (non-test) token is refused by this workflow even if it is placed in the running server's
// env file mid-session (projectEnv() re-reads .env on every call; no restart needed for this check).
fs.writeFileSync(envFile, envBefore.replace(/^SHIPPO_API_TOKEN=.*$/m, 'SHIPPO_API_TOKEN=shippo_live_not_allowed_here'));
r = await op('rates', {staff, ship_to: US_TO, parcel: PARCEL, customs: null});
check('a live-looking token is refused before any call to Shippo', r.status === 409 && /not a Shippo TEST token/.test(r.body.error), r.body.error);
fs.writeFileSync(envFile, envBefore);
r = await op('auth', {});
check('restoring the test token makes the integration usable again', r.status === 200 && r.body.result.ok === true);

// Request guards and live-table isolation.
const xs = await fetch(`${app}/api/shippo-test/auth`, {method: 'POST', headers: {'Content-Type': 'application/json', Origin: 'https://evil.example'}, body: '{}'});
check('cross-site request refused', xs.status === 403);
const q = await (await fetch(`${app}/api/queue`)).json();
check('live tables untouched: no booking attempts or labels from Shippo test activity',
  q.totals.booking_attempts === 0 && q.totals.labels === 0);
const leaked = [...responses, fs.existsSync(serverLog) ? fs.readFileSync(serverLog, 'utf8') : ''].some(t => t.includes(token));
check('no Shippo API token in any API response or the server log', !leaked);

console.log(`${results.filter(Boolean).length}/${results.length} passed`);
process.exit(results.every(Boolean) ? 0 : 1);
