// Local stand-in for the Shippo API, for automated tests only. It follows the documented contract
// (ShippoToken auth, POST /shipments with rates in the response, POST /transactions, GET
// /transactions/{id} for reconciliation, GET /rates/{id}, a label URL) and can be switched into
// failure scenarios through POST /__scenario.
// usage: node tests/shippo/mock-server.mjs <port> <token>
import http from 'node:http';

const [port, token] = process.argv.slice(2);
const state = {
  scenario: {auth: 'ok', rates: 'ok', purchase: 'ok', reconcile: 'none', rate_lookup: 'ok'},
  calls: {carrier_accounts: 0, shipments: 0, transactions: 0, transaction_get: 0, rate_get: 0, label: 0, unauthorised: 0},
  bodies: [],
  transactions: new Map(),
  rates: new Map(),     // object_id -> {rate object, international}
  seq: 0,
};
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');
const INVOICE = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n(customs invoice)\n');

const json = (res, status, body) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
const read = req => new Promise(r => { let b = ''; req.on('data', d => (b += d)); req.on('end', () => r(b)); });
function authorised(req) {
  const t = /^ShippoToken (.+)$/.exec(req.headers.authorization ?? '')?.[1];
  if (!t || t !== token || state.scenario.auth === 'reject') { state.calls.unauthorised++; return false; }
  return true;
}
function makeRate(id, provider, name, amount, carrierAccount, international, omitCarrierAccountInListing) {
  const r = {object_id: id, amount, currency: 'USD', provider, servicelevel: {name, token: name.toLowerCase().replace(/\s+/g, '_')},
    estimated_days: 3, duration_terms: '3 business days', carrier_account: carrierAccount, test: true};
  // GET /rates/{id} always has carrier_account (Shippo's own record); the /shipments LISTING can
  // be made to omit it, simulating the gap this app had before carrier_account was mapped.
  state.rates.set(id, {rate: r, international});
  return omitCarrierAccountInListing ? {...r, carrier_account: undefined} : r;
}
const labelUrl = id => `http://127.0.0.1:${port}/label/${id}.pdf`;
const invoiceUrl = id => `http://127.0.0.1:${port}/invoice/${id}.pdf`;

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const raw = req.method === 'POST' ? await read(req) : '';
  if (url.pathname === '/__scenario') { Object.assign(state.scenario, JSON.parse(raw || '{}')); return json(res, 200, state.scenario); }
  if (url.pathname === '/__state') return json(res, 200, {calls: state.calls, bodies: state.bodies});

  if (url.pathname.startsWith('/carrier_accounts')) {
    state.calls.carrier_accounts++;
    if (state.scenario.auth === 'down') return json(res, 503, {detail: 'temporarily_unavailable'});
    if (!authorised(req)) return json(res, 401, {detail: 'Invalid token.'});
    return json(res, 200, {results: [{object_id: 'ca_mock', carrier: 'usps', active: true}], next: null, previous: null});
  }

  if (url.pathname === '/shipments' && req.method === 'POST') {
    state.calls.shipments++;
    state.bodies.push(raw);
    if (!authorised(req)) return json(res, 401, {detail: 'Invalid token.'});
    const body = JSON.parse(raw || '{}');
    const id = `shp_${++state.seq}`;
    const intl = body.address_to?.country !== 'US';
    if (state.scenario.rates === 'empty') {
      return json(res, 200, {object_id: id, status: 'SUCCESS', rates: [], messages: [{source: 'USPS', code: 'no_rate', text: 'No service available for this parcel'}]});
    }
    if (state.scenario.rates === 'error') return json(res, 400, {detail: 'Invalid address'});
    if (intl && !body.customs_declaration) {
      return json(res, 400, {detail: 'customs_declaration is required for an international shipment'});
    }
    const n = ++state.seq;
    const omit = state.scenario.rates === 'no_carrier_account';
    return json(res, 200, {
      object_id: id, status: 'SUCCESS',
      rates: [
        makeRate(`rate_cheap_${n}`, 'USPS', 'Priority Mail', '8.10', 'ca_usps_mock', intl, omit),
        makeRate(`rate_expensive_${n}`, 'USPS', 'Priority Mail Express', '32.50', 'ca_usps_mock', intl, omit),
      ],
      messages: [],
    });
  }

  if (url.pathname === '/transactions' && req.method === 'POST') {
    state.calls.transactions++;
    state.bodies.push(raw);
    if (!authorised(req)) return json(res, 401, {detail: 'Invalid token.'});
    const body = JSON.parse(raw || '{}');
    const id = `txn_${++state.seq}`;
    const s = state.scenario.purchase;
    if (s === '500') return json(res, 500, {detail: 'Internal error'});
    if (s === 'timeout') return; // never answers; the client times out
    const rateInfo = state.rates.get(body.rate);
    const intl = rateInfo?.international ?? false;
    let txn;
    if (s === 'error') txn = {object_id: id, status: 'ERROR', object_state: 'INVALID', test: true, tracking_number: null, label_url: null,
      commercial_invoice_url: null, messages: [{source: 'USPS', code: 'error', text: 'Could not purchase this rate'}], rate: body.rate};
    else if (s === 'queued') txn = {object_id: id, status: 'QUEUED', object_state: 'VALID', test: true, tracking_number: null, label_url: null,
      commercial_invoice_url: null, messages: [], rate: body.rate};
    else if (s === 'not_test') txn = {object_id: id, status: 'SUCCESS', object_state: 'VALID', test: false, tracking_number: `MOCKTRK-${id}`,
      label_url: labelUrl(id), commercial_invoice_url: null, messages: [], rate: body.rate};
    else txn = {object_id: id, status: 'SUCCESS', object_state: 'VALID', test: true, tracking_number: `MOCKTRK-${id}`, label_url: labelUrl(id),
      commercial_invoice_url: intl ? invoiceUrl(id) : null, messages: [], rate: body.rate};
    state.transactions.set(id, txn);
    return json(res, 200, txn);
  }

  const txnGet = /^\/transactions\/([A-Za-z0-9_]+)$/.exec(url.pathname);
  if (txnGet && req.method === 'GET') {
    state.calls.transaction_get++;
    if (!authorised(req)) return json(res, 401, {detail: 'Invalid token.'});
    let txn = state.transactions.get(txnGet[1]);
    if (!txn) return json(res, 404, {detail: 'not found'});
    if (state.scenario.reconcile === 'resolved_success' && txn.status !== 'SUCCESS') {
      txn = {...txn, status: 'SUCCESS', object_state: 'VALID', tracking_number: `MOCKTRK-${txn.object_id}`, label_url: labelUrl(txn.object_id)};
      state.transactions.set(txn.object_id, txn);
    }
    return json(res, 200, txn);
  }

  const rateGet = /^\/rates\/([A-Za-z0-9_]+)$/.exec(url.pathname);
  if (rateGet && req.method === 'GET') {
    state.calls.rate_get++;
    if (!authorised(req)) return json(res, 401, {detail: 'Invalid token.'});
    if (state.scenario.rate_lookup === 'not_found') return json(res, 404, {detail: 'not found'});
    const info = state.rates.get(rateGet[1]);
    if (!info) return json(res, 404, {detail: 'not found'});
    return json(res, 200, info.rate);
  }

  const label = /^\/label\/([A-Za-z0-9_]+)\.pdf$/.exec(url.pathname);
  if (label && req.method === 'GET') {
    state.calls.label++;
    res.writeHead(200, {'Content-Type': 'application/pdf', 'Content-Disposition': `attachment; filename="${label[1]}.pdf"`});
    return res.end(PDF);
  }
  const invoice = /^\/invoice\/([A-Za-z0-9_]+)\.pdf$/.exec(url.pathname);
  if (invoice && req.method === 'GET') {
    res.writeHead(200, {'Content-Type': 'application/pdf', 'Content-Disposition': `attachment; filename="${invoice[1]}-invoice.pdf"`});
    return res.end(INVOICE);
  }

  json(res, 404, {detail: 'not found'});
}).listen(Number(port), '127.0.0.1', () => console.log(`shippo mock on ${port}`));
