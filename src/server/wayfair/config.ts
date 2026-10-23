// Wayfair SANDBOX configuration (server-only). Values come from this project's .env through
// projectEnv(); none of them ever reaches the browser, a log line or an error message.
//
// Endpoints are taken from Wayfair's official developer documentation (developer.wayfair.io, pages
// "API Access Tokens", "Guide to Dropship Orders and ASN APIs", "Guide to the Registration & Shipping
// API"; read 2026-10-23). Only the sandbox is configured: there are no production constants here and
// nothing falls back to production.
import {envFileOverride, projectEnv} from '../db';

export const SANDBOX_ENDPOINTS = {
  tokenUrl: 'https://sso.auth.wayfair.com/oauth/token',
  audience: 'https://sandbox.api.wayfair.com/',
  graphqlUrl: 'https://sandbox.api.wayfair.com/v1/graphql',
  shippingLabelBase: 'https://sandbox.api.wayfair.com/v1/shipping_label/',
} as const;
export type Endpoints = {tokenUrl: string; audience: string; graphqlUrl: string; shippingLabelBase: string};

export interface WayfairConfig {
  mode: string;                  // WAYFAIR_MODE as set ('' when missing)
  clientId: string;              // server-only
  clientSecret: string;          // server-only
  supplierId: string | null;     // WAYFAIR_SUPPLIER_ID
  warehouseId: string | null;    // WAYFAIR_WAREHOUSE_ID (Wayfair's id; never the OMS warehouse 32)
  importEnabled: boolean;        // WAYFAIR_ORDER_IMPORT_ENABLED
  endpoints: Endpoints;
  mock: boolean;                 // a local mock (synthetic test instance only)
  problems: string[];            // reasons the integration cannot be used
  usable: boolean;
}

// Public view: which settings are present, never their values.
export interface WayfairConfigView {
  mode: string;
  client_id_set: boolean;
  client_secret_set: boolean;
  supplier_id: string | null;    // an account identifier, not a secret: shown so staff can check it
  warehouse_id: string | null;
  order_import_enabled: boolean;
  mock: boolean;
  problems: string[];
  usable: boolean;
}

const ID = /^[0-9]{1,12}$/;

export function wayfairConfig(): WayfairConfig {
  const env = projectEnv();
  const problems: string[] = [];
  const mode = env.WAYFAIR_MODE ?? '';
  if (!mode) problems.push('WAYFAIR_MODE is not set (use sandbox)');
  else if (mode !== 'sandbox') problems.push(`WAYFAIR_MODE is "${mode}": only sandbox is supported in this phase`);
  const clientId = env.WAYFAIR_SANDBOX_CLIENT_ID ?? '';
  const clientSecret = env.WAYFAIR_SANDBOX_CLIENT_SECRET ?? '';
  if (!clientId) problems.push('WAYFAIR_SANDBOX_CLIENT_ID is not set');
  if (!clientSecret) problems.push('WAYFAIR_SANDBOX_CLIENT_SECRET is not set');
  const supplierId = env.WAYFAIR_SUPPLIER_ID || null;
  const warehouseId = env.WAYFAIR_WAREHOUSE_ID || null;
  if (supplierId && !ID.test(supplierId)) problems.push('WAYFAIR_SUPPLIER_ID must be a numeric Wayfair supplier id');
  if (warehouseId && !ID.test(warehouseId)) problems.push('WAYFAIR_WAREHOUSE_ID must be a numeric Wayfair warehouse id');
  const importRaw = (env.WAYFAIR_ORDER_IMPORT_ENABLED ?? 'false').toLowerCase();
  const importEnabled = importRaw === 'true';
  if (importEnabled) {
    problems.push('WAYFAIR_ORDER_IMPORT_ENABLED=true is not supported: the OMS is the only source of orders. Set it to false.');
  }

  // A local mock replaces the endpoints only for a labelled synthetic test instance (USB_ENV_FILE)
  // and only on the loopback interface.
  let endpoints: Endpoints = SANDBOX_ENDPOINTS;
  let mock = false;
  if (env.WAYFAIR_TEST_MOCK_URL) {
    let url: URL | null = null;
    try {
      url = new URL(env.WAYFAIR_TEST_MOCK_URL);
    } catch {
      url = null;
    }
    if (envFileOverride && url && url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname)) {
      const base = url.origin;
      endpoints = {tokenUrl: `${base}/oauth/token`, audience: SANDBOX_ENDPOINTS.audience, graphqlUrl: `${base}/v1/graphql`,
                   shippingLabelBase: `${base}/v1/shipping_label/`};
      mock = true;
    } else {
      problems.push('WAYFAIR_TEST_MOCK_URL is only accepted on a synthetic test instance and a loopback address');
    }
  }
  return {mode, clientId, clientSecret, supplierId, warehouseId, importEnabled, endpoints, mock, problems, usable: problems.length === 0};
}

export function configView(c: WayfairConfig): WayfairConfigView {
  return {
    mode: c.mode, client_id_set: Boolean(c.clientId), client_secret_set: Boolean(c.clientSecret),
    supplier_id: c.supplierId, warehouse_id: c.warehouseId, order_import_enabled: c.importEnabled,
    mock: c.mock, problems: c.problems, usable: c.usable,
  };
}
