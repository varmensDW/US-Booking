// Local stand-in for the Wayfair SANDBOX API, for automated tests only. It follows the documented
// contract (token endpoint, GraphQL getDropshipPurchaseOrders / labelGenerationEvents / register,
// REST shipping_label) and can be switched into failure scenarios through POST /__scenario.
// usage: node tests/wayfair/mock-server.mjs <port> <client id> <client secret>
import http from 'node:http';

const [port, clientId, clientSecret] = process.argv.slice(2);
const AUDIENCE = 'https://sandbox.api.wayfair.com/';
const state = {
  scenario: {token: 'ok', orders: 'ok', register: 'ok', expiresIn: 3600},
  tokens: new Map(),          // token -> expiry (ms)
  registered: new Set(),
  calls: {token: 0, graphql: 0, register: 0, label: 0, unauthorised: 0},
  bodies: [],                 // request bodies seen (to check that no secret is sent where it should not be)
};
const ORDERS = [
  {poNumber: 'TEST_1', poDate: '2026-10-22 10:00:00', supplierId: 12345, products: [{partNumber: 'PART-A', quantity: 2, price: 10.5}]},
  {poNumber: 'TEST_2', poDate: '2026-10-22 11:00:00', supplierId: 99999, products: [{partNumber: 'PART-B', quantity: 1, price: 5}]},
  {poNumber: 'TEST_3', poDate: '2026-10-22 12:00:00', supplierId: 12345, products: [{partNumber: 'PART-C', quantity: 1, price: 7}]},
  {poNumber: 'TEST_4', poDate: '2026-10-22 13:00:00', supplierId: 12345, products: [{partNumber: 'PART-D', quantity: 1, price: 7}]},
  {poNumber: 'TEST_5', poDate: '2026-10-22 14:00:00', supplierId: 12345, products: [{partNumber: 'PART-E', quantity: 1, price: 7}]},
];
const PDF = Buffer.from('%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n');

const json = (res, status, body) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(body)); };
const read = req => new Promise(r => { let b = ''; req.on('data', d => (b += d)); req.on('end', () => r(b)); });
function authorised(req) {
  const t = /^Bearer (.+)$/.exec(req.headers.authorization ?? '')?.[1];
  const exp = t && state.tokens.get(t);
  if (!exp || exp < Date.now()) { state.calls.unauthorised++; return false; }
  return true;
}
const event = po => ({id: `evt-${po}`, poNumber: po, pickupDate: '2026-10-24 00:00:00', billOfLading: null,
  consolidatedShippingLabel: {url: `https://sandbox.api.wayfair.com/v1/shipping_label/${po}`}, customsDocument: null,
  purchaseOrder: {packingSlipUrl: `https://sandbox.api.wayfair.com/v1/packing_slip/${po}`},
  generatedShippingLabels: [{carrierCode: 'FDEG', trackingNumber: `MOCKTRK-${po}`}]});

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const raw = req.method === 'POST' ? await read(req) : '';
  if (url.pathname === '/__scenario') { Object.assign(state.scenario, JSON.parse(raw || '{}')); return json(res, 200, state.scenario); }
  if (url.pathname === '/__revoke') { state.tokens.clear(); return json(res, 200, {revoked: true}); }
  if (url.pathname === '/__state') return json(res, 200, {calls: state.calls, registered: [...state.registered], bodies: state.bodies});
  if (url.pathname === '/oauth/token' && req.method === 'POST') {
    state.calls.token++;
    const b = JSON.parse(raw || '{}');
    if (state.scenario.token === 'down') return json(res, 503, {error: 'temporarily_unavailable'});
    if (b.grant_type !== 'client_credentials' || b.audience !== AUDIENCE) return json(res, 400, {error: 'invalid_request', error_description: 'bad grant or audience'});
    if (b.client_id !== clientId || b.client_secret !== clientSecret || state.scenario.token === 'reject') {
      return json(res, 401, {error: 'access_denied', error_description: 'Unauthorized'});
    }
    const t = `mock-token-${state.calls.token}-${Math.random().toString(36).slice(2)}`;
    state.tokens.set(t, Date.now() + state.scenario.expiresIn * 1000);
    return json(res, 200, {access_token: t, expires_in: state.scenario.expiresIn, token_type: 'Bearer'});
  }
  if (url.pathname === '/v1/graphql' && req.method === 'POST') {
    state.calls.graphql++;
    state.bodies.push(raw);
    if (!authorised(req)) return json(res, 401, {errors: [{message: 'Unauthorized'}]});
    const {query, variables} = JSON.parse(raw || '{}');
    if (/getDropshipPurchaseOrders/.test(query)) {
      if (state.scenario.orders === 'empty') return json(res, 200, {data: {getDropshipPurchaseOrders: []}});
      if (state.scenario.orders === 'error') return json(res, 200, {errors: [{message: 'Not authorized to access purchase orders'}], data: {getDropshipPurchaseOrders: null}});
      const list = variables?.poNumbers?.length ? ORDERS.filter(o => variables.poNumbers.includes(o.poNumber)) : ORDERS;
      return json(res, 200, {data: {getDropshipPurchaseOrders: list.slice(0, variables?.limit ?? 10)}});
    }
    if (/labelGenerationEvents/.test(query)) {
      // Like the documented sandbox: a static example not tied to the requested PO.
      return json(res, 200, {data: {labelGenerationEvents: [event('CS_STATIC_EXAMPLE')]}});
    }
    if (/register\(/.test(query)) {
      state.calls.register++;
      const po = variables?.registrationInput?.poNumber;
      const s = state.scenario.register;
      if (s === 'graphql_error') return json(res, 200, {errors: [{message: 'Part number is not part of this purchase order'}], data: {purchaseOrders: {register: null}}});
      if (s === '500') return json(res, 500, {errors: [{message: 'Internal error'}]});
      if (s === 'timeout') return; // never answers; the client times out
      state.registered.add(po);
      return json(res, 200, {data: {purchaseOrders: {register: event(po)}}});
    }
    return json(res, 400, {errors: [{message: 'Unknown operation'}]});
  }
  const m = /^\/v1\/shipping_label\/([A-Za-z0-9_-]+)$/.exec(url.pathname);
  if (m && req.method === 'GET') {
    state.calls.label++;
    if (!authorised(req)) return json(res, 401, {error: 'Unauthorized'});
    if (!state.registered.has(m[1])) return json(res, 400, {error: 'Purchase order is not registered'});
    res.writeHead(200, {'Content-Type': 'application/pdf', 'Content-Disposition': `attachment; filename="${m[1]}.pdf"`});
    return res.end(PDF);
  }
  json(res, 404, {error: 'not found'});
}).listen(Number(port), '127.0.0.1', () => console.log(`wayfair mock on ${port}`));
