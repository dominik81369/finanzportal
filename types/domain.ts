/**
 * types/domain.ts
 *
 * Handgeschriebene Domain-Typen auf Basis von types/database.ts.
 * Bildet u. a. die Spalten-Grants aus supabase/migrations/ ab, damit unerlaubte
 * Schreibzugriffe (z. B. profiles.role) bereits zur Compile-Zeit auffallen.
 */
import {
  Constants,
  type Enums,
  type Json,
  type Tables,
  type TablesInsert,
  type TablesUpdate,
} from './database';

// Row-Aliase ------------------------------------------------------------
export type Profile = Tables<'profiles'>;
export type AdvisorClient = Tables<'advisor_clients'>;
export type Account = Tables<'accounts'>;
export type Category = Tables<'categories'>;
export type Transaction = Tables<'transactions'>;
export type Portfolio = Tables<'portfolios'>;
export type Asset = Tables<'assets'>;
export type RealEstateObject = Tables<'real_estate_objects'>;
export type Tag = Tables<'tags'>;
export type TransactionTag = Tables<'transaction_tags'>;
export type Budget = Tables<'budgets'>;
export type RecurringContract = Tables<'recurring_contracts'>;
export type CategorizationRule = Tables<'categorization_rules'>;

export type UserRole = Enums<'user_role'>;
export type MarketRegion = Enums<'market_region'>;
export type AssetClass = Enums<'asset_class'>;
export type TransactionSource = Enums<'transaction_source'>;
export type BudgetPeriod = Enums<'budget_period'>;
export type BudgetGroup = Enums<'budget_group'>;
export type ContractRhythm = Enums<'contract_rhythm'>;
export type ContractStatus = Enums<'contract_status'>;
export type RuleMatchField = Enums<'rule_match_field'>;
export type RuleMatchType = Enums<'rule_match_type'>;

// Schreib-Typen gemäß Spalten-Grants ------------------------------------
/** Einzige Spalten, die `authenticated` in profiles ändern darf. */
export type ProfileUpdate = Pick<
  TablesUpdate<'profiles'>,
  'first_name' | 'last_name' | 'locale' | 'base_currency' | 'onboarding_completed_at'
>;

/** Einladung durch Berater; advisor_id wird per Default auf auth.uid() gesetzt. */
export type AdvisorInvitationInsert = Required<
  Pick<TablesInsert<'advisor_clients'>, 'invited_email' | 'invite_token_hash' | 'invite_expires_at'>
>;

/** Einziger erlaubter Statuswechsel über die Data API. */
export type AdvisorLinkRevoke = { status: 'revoked' };

/**
 * Budget mit genau einer Bezugsgröße (CHECK budgets_single_scope):
 * Kategorie ODER Tag ODER Konto.
 */
export type BudgetScope =
  | { category_id: string; tag_id?: null; account_id?: null }
  | { tag_id: string; category_id?: null; account_id?: null }
  | { account_id: string; category_id?: null; tag_id?: null };

export type BudgetInsert = Omit<
  TablesInsert<'budgets'>,
  'category_id' | 'tag_id' | 'account_id'
> &
  BudgetScope;

// Look-through-Exposure (assets.exposure) -------------------------------
/** Gewichte jeweils 0..1 (Anteil am Positionswert). */
export type AssetExposure = {
  regions?: Partial<Record<MarketRegion, number>>;
  asset_classes?: Partial<Record<AssetClass, number>>;
  sectors?: Partial<Record<string, number>>;
  /** ISO-3166-1 alpha-2 */
  countries?: Partial<Record<string, number>>;
};

export type AssetWithExposure = Omit<Asset, 'exposure'> & { exposure: AssetExposure };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function toWeightMap<K extends string>(
  value: unknown,
  allowedKeys?: readonly K[],
): Partial<Record<K, number>> | undefined {
  if (!isRecord(value)) return undefined;

  const result: Partial<Record<K, number>> = {};
  for (const [key, weight] of Object.entries(value)) {
    if (allowedKeys && !(allowedKeys as readonly string[]).includes(key)) continue;
    if (typeof weight !== 'number' || !Number.isFinite(weight) || weight < 0 || weight > 1) continue;
    result[key as K] = weight;
  }
  return Object.keys(result).length > 0 ? result : undefined;
}

/** Validiert das untypisierte jsonb-Feld defensiv; ungültige Einträge werden verworfen. */
export function parseAssetExposure(value: Json | null | undefined): AssetExposure {
  if (!isRecord(value)) return {};

  const exposure: AssetExposure = {};
  const regions = toWeightMap(value.regions, Constants.public.Enums.market_region);
  const assetClasses = toWeightMap(value.asset_classes, Constants.public.Enums.asset_class);
  const sectors = toWeightMap<string>(value.sectors);
  const countries = toWeightMap<string>(value.countries);

  if (regions) exposure.regions = regions;
  if (assetClasses) exposure.asset_classes = assetClasses;
  if (sectors) exposure.sectors = sectors;
  if (countries) exposure.countries = countries;
  return exposure;
}

export function withParsedExposure(asset: Asset): AssetWithExposure {
  return { ...asset, exposure: parseAssetExposure(asset.exposure) };
}
