// Shippo TEST-mode configuration (server-only). Values come from this project's .env through
// projectEnv(); the API token never reaches the browser, a log line or an error message.
//
// Endpoints and field names are taken from Shippo's official API documentation
// (docs.goshippo.com, "Authentication", "Testing the Shippo API", "Create a new shipment",
// "Retrieve shipment rates", "Create a shipping label", "Create a new customs declaration",
// "Create a new address"; read 2026-10-23). Only test mode is configured here: this workflow
// refuses a token that is not a documented Shippo TEST token.
import {envFileOverride, projectEnv} from '../db';

export const API_BASE = 'https://api.goshippo.com';

export const DISTANCE_UNITS = ['in', 'cm', 'ft', 'mm', 'm', 'yd'] as const;
export const MASS_UNITS = ['g', 'kg', 'lb', 'oz'] as const;
// Required for a purchase in the US, AU and CA (Shippo "Create a new address"); enforced here only
// for those three, left optional elsewhere since Shippo's own requirement varies by destination.
const STATE_REQUIRED_COUNTRIES = new Set(['US', 'CA', 'AU']);

export interface ShipFromAddress {
  name: string;
  company: string | null;
  street1: string;
  street2: string | null;
  city: string;
  state: string | null;
  zip: string;
  country: string;      // ISO 2-letter
  phone: string;
  email: string;
}

export interface ShippoConfig {
  mode: string;             // SHIPPO_MODE as set ('' when missing)
  token: string;            // server-only
  apiBase: string;
  shipFrom: ShipFromAddress | null;
  // SHIPPO_SHIP_RETURN_* is OPTIONAL and distinct from the ship-from address above: this account
  // has different default sender and return addresses, and Shippo's documentation does not say
  // what happens to returns when address_return is omitted (not "defaults to address_from", not
  // "uses the dashboard return address" -- undocumented either way). So this app never assumes
  // either: it sends address_return only when explicitly configured here, and otherwise reports
  // the gap rather than guessing (see returnAddressConfigured below and configView's ship_return).
  shipReturn: ShipFromAddress | null;
  returnAddressConfigured: boolean;   // true once any SHIPPO_SHIP_RETURN_* value is set, even if incomplete
  mock: boolean;            // a local mock (synthetic test instance only)
  problems: string[];
  usable: boolean;
}

// Public view: which settings are present, never the token value. The ship-from (and, if set,
// ship-return) address is shown in full because it is this warehouse's own operational address
// (not a secret) and staff need to see exactly what was configured, rather than guess.
export interface ShippoConfigView {
  mode: string;
  token_set: boolean;
  token_is_test: boolean;
  ship_from: ShipFromAddress | null;
  ship_return: ShipFromAddress | null;
  return_address_configured: boolean;
  mock: boolean;
  problems: string[];
  usable: boolean;
}

// `required`: names (env suffix, label) that must all be present for a complete address. Used for
// both the mandatory ship-from address and the optional ship-return address.
function readAddress(env: Record<string, string>, prefix: string, problems: string[], opts: {optional: boolean}): {address: ShipFromAddress | null; anySet: boolean} {
  const get = (k: string) => (env[`${prefix}_${k}`] ?? '').trim();
  const required: Array<[string, string]> = [
    ['NAME', 'name'], ['STREET1', 'street1'], ['CITY', 'city'], ['ZIP', 'zip'], ['COUNTRY', 'country'],
    ['PHONE', 'phone'], ['EMAIL', 'email'],
  ];
  const all = [...required.map(([k]) => k), 'COMPANY', 'STREET2', 'STATE'];
  const anySet = all.some(k => Boolean(get(k)));
  if (opts.optional && !anySet) return {address: null, anySet: false};
  const missing = required.filter(([k]) => !get(k));
  const country = get('COUNTRY').toUpperCase();
  const state = get('STATE');
  if (get('COUNTRY') && !/^[A-Za-z]{2}$/.test(get('COUNTRY'))) problems.push(`${prefix}_COUNTRY must be a two-letter ISO code`);
  if (country && STATE_REQUIRED_COUNTRIES.has(country) && !state) problems.push(`${prefix}_STATE is required for an address in ${country}`);
  if (missing.length) {
    problems.push(`${opts.optional ? 'return' : 'ship-from'} address is incomplete: ${missing.map(([k]) => `${prefix}_${k}`).join(', ')} not set`);
    return {address: null, anySet};
  }
  if (!/^[A-Za-z]{2}$/.test(get('COUNTRY'))) return {address: null, anySet};
  return {
    anySet,
    address: {
      name: get('NAME'), company: get('COMPANY') || null, street1: get('STREET1'), street2: get('STREET2') || null,
      city: get('CITY'), state: state || null, zip: get('ZIP'), country, phone: get('PHONE'), email: get('EMAIL'),
    },
  };
}

export function shippoConfig(): ShippoConfig {
  const env = projectEnv();
  const problems: string[] = [];
  const mode = env.SHIPPO_MODE ?? '';
  if (!mode) problems.push('SHIPPO_MODE is not set (use test)');
  else if (mode !== 'test') problems.push(`SHIPPO_MODE is "${mode}": only test is supported in this workflow`);
  const token = env.SHIPPO_API_TOKEN ?? '';
  if (!token) problems.push('SHIPPO_API_TOKEN is not set');
  else if (!token.startsWith('shippo_test_')) {
    problems.push('SHIPPO_API_TOKEN is not a Shippo TEST token (must start with shippo_test_); live credentials are refused in this workflow');
  }
  const {address: shipFrom} = readAddress(env, 'SHIPPO_SHIP_FROM', problems, {optional: false});
  const {address: shipReturn, anySet: returnAddressConfigured} = readAddress(env, 'SHIPPO_SHIP_RETURN', problems, {optional: true});

  // A local mock replaces the API base only for a labelled synthetic test instance (USB_ENV_FILE)
  // and only on the loopback interface, exactly as src/server/wayfair/config.ts does.
  let apiBase = API_BASE;
  let mock = false;
  if (env.SHIPPO_TEST_MOCK_URL) {
    let url: URL | null = null;
    try {
      url = new URL(env.SHIPPO_TEST_MOCK_URL);
    } catch {
      url = null;
    }
    if (envFileOverride && url && url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname)) {
      apiBase = url.origin;
      mock = true;
    } else {
      problems.push('SHIPPO_TEST_MOCK_URL is only accepted on a synthetic test instance and a loopback address');
    }
  }
  return {mode, token, apiBase, shipFrom, shipReturn, returnAddressConfigured, mock, problems, usable: problems.length === 0};
}

export function configView(c: ShippoConfig): ShippoConfigView {
  return {
    mode: c.mode, token_set: Boolean(c.token), token_is_test: c.token.startsWith('shippo_test_'),
    ship_from: c.shipFrom, ship_return: c.shipReturn, return_address_configured: c.returnAddressConfigured,
    mock: c.mock, problems: c.problems, usable: c.usable,
  };
}
