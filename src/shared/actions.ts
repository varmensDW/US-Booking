// Staff actions: request shapes shared by the forms (client) and the action API (server).
// The database functions (db/migrations/0008) validate again and own every business rule; these
// schemas only reject malformed requests early and give forms field-level messages.
import {z} from 'zod';

export const DIMENSION_UNITS = ['in', 'cm'] as const;
export const WEIGHT_UNITS = ['lb', 'kg', 'oz', 'g'] as const;
export const EVIDENCE_TYPES = ['marketplace_order_record', 'customer_confirmation', 'carrier_address_validation', 'other'] as const;

export const staffName = z.string().trim().min(2, 'Enter your name (at least 2 characters)').max(120)
  .refine(v => !/^(system|migration):/i.test(v), 'A staff name cannot start with system: or migration:');
// Measurements stay decimal strings end to end, so no float rounding touches them.
export const measure = z.string().trim()
  .regex(/^[0-9]{1,5}(\.[0-9]{1,3})?$/, 'Enter a positive number (up to 3 decimals)')
  .refine(v => Number(v) > 0, 'Must be greater than 0');
const id = z.number().int().positive();
const rowVersion = z.number().int().positive();

export const dimensionsInput = z.object({length: measure, width: measure, height: measure, unit: z.enum(DIMENSION_UNITS)});
export const weightInput = z.object({value: measure, unit: z.enum(WEIGHT_UNITS)});

export const profileSave = z.object({
  staff: staffName,
  profile_id: id.optional(),
  expected_version: z.number().int().positive().nullable().optional(),
  name: z.string().trim().min(2, 'Name the profile (at least 2 characters)').max(80),
  length: measure, width: measure, height: measure,
  dimension_unit: z.enum(DIMENSION_UNITS),
  packed_weight: measure.optional(),
  packed_weight_unit: z.enum(WEIGHT_UNITS).optional(),
  empty_weight: measure.optional(),
  empty_weight_unit: z.enum(WEIGHT_UNITS).optional(),
  note: z.string().trim().max(500).optional(),
}).refine(v => !v.packed_weight || v.packed_weight_unit, {message: 'Choose a unit for the packed weight', path: ['packed_weight_unit']})
  .refine(v => !v.empty_weight || v.empty_weight_unit, {message: 'Choose a unit for the empty packaging weight', path: ['empty_weight_unit']});

export const ACTION_SCHEMAS = {
  'profile-save': profileSave,
  'profile-assign': z.object({
    staff: staffName, assignment: z.enum(['us1_shippo', 'us1_amazon']), profile_id: id.nullable(), expected_profile_id: id.nullable(),
  }),
  'parcel-create': z.object({staff: staffName, group_id: id}),
  'parcel-measure': z.object({
    staff: staffName, parcel_id: id, expected_row_version: rowVersion,
    dimensions: z.union([z.literal('profile'), dimensionsInput]).optional(),
    weight: z.union([z.literal('profile'), weightInput]).optional(),
  }),
  'parcel-contents': z.object({
    staff: staffName, parcel_id: id, expected_row_version: rowVersion, confirm: z.boolean().optional(),
    items: z.array(z.object({oms_order_item_id: id, quantity: z.number().int().min(0).max(999999)})).max(500),
  }),
  'parcel-confirm': z.object({staff: staffName, parcel_id: id, expected_row_version: rowVersion, confirmed: z.boolean()}),
  'parcel-remove': z.object({staff: staffName, parcel_id: id, expected_row_version: rowVersion}),
  'parcel-packaging': z.object({
    staff: staffName, parcel_id: id, expected_row_version: rowVersion, mode: z.enum(['measured', 'provider_managed']),
    reason: z.string().trim().min(3, 'Say why this package differs from Wayfair data (at least 3 characters)').max(500).optional(),
  }),
  'destination-confirm': z.object({
    staff: staffName, oms_order_id: id, iso2: z.string().trim().regex(/^[A-Za-z]{2}$/, 'Choose a country'),
    evidence_type: z.enum(EVIDENCE_TYPES), evidence_ref: z.string().trim().min(3, 'Describe the evidence (at least 3 characters)').max(500),
    expected_address_hash: z.string().min(1).max(64),
  }),
  'destination-revoke': z.object({
    staff: staffName, confirmation_id: id, reason: z.string().trim().min(3, 'Give a reason (at least 3 characters)').max(500),
    expected_address_hash: z.string().min(1).max(64),
  }),
  'discrepancy-acknowledge': z.object({
    staff: staffName, discrepancy_id: id, expected_current_hash: z.string().regex(/^[0-9a-f]{32}$/),
    evidence: z.string().trim().min(3, 'Record why the locked parcel can stay as it is (at least 3 characters)').max(1000),
  }),
  'case-close': z.object({
    staff: staffName, case_id: id, outcome: z.enum(['resolved', 'dismissed']),
    evidence: z.string().trim().min(3, 'Record the evidence for this decision (at least 3 characters)').max(1000),
    expected_details_hash: z.string().regex(/^[0-9a-f]{32}$/),
  }),
} as const;

export type ActionKey = keyof typeof ACTION_SCHEMAS;
export type ActionInput<K extends ActionKey> = z.input<(typeof ACTION_SCHEMAS)[K]>;

export const ACTION_FUNCTIONS = {
  'profile-save': 'staff_profile_save',
  'profile-assign': 'staff_profile_assign',
  'parcel-create': 'staff_parcel_create',
  'parcel-measure': 'staff_parcel_measure',
  'parcel-contents': 'staff_parcel_set_contents',
  'parcel-confirm': 'staff_parcel_confirm_contents',
  'parcel-remove': 'staff_parcel_remove',
  'parcel-packaging': 'staff_parcel_set_packaging',
  'destination-confirm': 'staff_destination_confirm',
  'destination-revoke': 'staff_destination_revoke',
  'case-close': 'staff_case_close',
  'discrepancy-acknowledge': 'staff_discrepancy_acknowledge',
} as const satisfies Record<ActionKey, string>;
