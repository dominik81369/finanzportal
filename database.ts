/**
 * types/database.ts
 *
 * Typdefinitionen im Format von `supabase gen types typescript`, 1:1 passend
 * zu supabase/schema.sql. Nach jeder Migration neu generieren:
 *
 *   npx supabase gen types typescript --project-id <ref> --schema public > types/database.ts
 *
 * Handgeschriebene Domain-Typen gehören NICHT hierher (werden beim Generieren
 * überschrieben), sondern nach types/domain.ts.
 *
 * Hinweis: numeric-Spalten werden als number geliefert. Beträge sind auf
 * numeric(14,2) begrenzt und liegen damit sicher im Double-Präzisionsbereich.
 */

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[];

export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: {
          user_id: string;
          role: Database['public']['Enums']['user_role'];
          first_name: string | null;
          last_name: string | null;
          locale: string;
          base_currency: string;
          onboarding_completed_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          user_id: string;
          role?: Database['public']['Enums']['user_role'];
          first_name?: string | null;
          last_name?: string | null;
          locale?: string;
          base_currency?: string;
          onboarding_completed_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          user_id?: string;
          role?: Database['public']['Enums']['user_role'];
          first_name?: string | null;
          last_name?: string | null;
          locale?: string;
          base_currency?: string;
          onboarding_completed_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      advisor_clients: {
        Row: {
          id: string;
          user_id: string | null;
          advisor_id: string;
          status: Database['public']['Enums']['advisor_link_status'];
          invited_email: string;
          invite_token_hash: string | null;
          invite_expires_at: string | null;
          invited_at: string;
          accepted_at: string | null;
          revoked_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string | null;
          advisor_id?: string;
          status?: Database['public']['Enums']['advisor_link_status'];
          invited_email: string;
          invite_token_hash?: string | null;
          invite_expires_at?: string | null;
          invited_at?: string;
          accepted_at?: string | null;
          revoked_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string | null;
          advisor_id?: string;
          status?: Database['public']['Enums']['advisor_link_status'];
          invited_email?: string;
          invite_token_hash?: string | null;
          invite_expires_at?: string | null;
          invited_at?: string;
          accepted_at?: string | null;
          revoked_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'advisor_clients_user_id_fkey';
            columns: ['user_id'];
            isOneToOne: false;
            referencedRelation: 'profiles';
            referencedColumns: ['user_id'];
          },
          {
            foreignKeyName: 'advisor_clients_advisor_id_fkey';
            columns: ['advisor_id'];
            isOneToOne: false;
            referencedRelation: 'profiles';
            referencedColumns: ['user_id'];
          },
        ];
      };

      accounts: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          type: Database['public']['Enums']['account_type'];
          provider: Database['public']['Enums']['account_provider'];
          provider_account_id: string | null;
          institution_name: string | null;
          iban_last4: string | null;
          currency: string;
          balance: number;
          balance_updated_at: string | null;
          is_liability: boolean;
          include_in_net_worth: boolean;
          last_synced_at: string | null;
          archived_at: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          name: string;
          type: Database['public']['Enums']['account_type'];
          provider?: Database['public']['Enums']['account_provider'];
          provider_account_id?: string | null;
          institution_name?: string | null;
          iban_last4?: string | null;
          currency?: string;
          balance?: number;
          balance_updated_at?: string | null;
          is_liability?: never;
          include_in_net_worth?: boolean;
          last_synced_at?: string | null;
          archived_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          type?: Database['public']['Enums']['account_type'];
          provider?: Database['public']['Enums']['account_provider'];
          provider_account_id?: string | null;
          institution_name?: string | null;
          iban_last4?: string | null;
          currency?: string;
          balance?: number;
          balance_updated_at?: string | null;
          is_liability?: never;
          include_in_net_worth?: boolean;
          last_synced_at?: string | null;
          archived_at?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      categories: {
        Row: {
          id: string;
          user_id: string;
          parent_id: string | null;
          name: string;
          kind: Database['public']['Enums']['category_kind'];
          color: string | null;
          icon: string | null;
          is_default: boolean;
          sort_order: number;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          parent_id?: string | null;
          name: string;
          kind: Database['public']['Enums']['category_kind'];
          color?: string | null;
          icon?: string | null;
          is_default?: boolean;
          sort_order?: number;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          parent_id?: string | null;
          name?: string;
          kind?: Database['public']['Enums']['category_kind'];
          color?: string | null;
          icon?: string | null;
          is_default?: boolean;
          sort_order?: number;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'categories_parent_fkey';
            columns: ['parent_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      transactions: {
        Row: {
          id: string;
          user_id: string;
          account_id: string;
          category_id: string | null;
          booking_date: string;
          value_date: string | null;
          amount: number;
          currency: string;
          counterparty_name: string | null;
          purpose: string | null;
          categorization_source: Database['public']['Enums']['categorization_source'] | null;
          external_id: string | null;
          import_hash: string | null;
          notes: string | null;
          exclude_from_budget: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          account_id: string;
          category_id?: string | null;
          booking_date: string;
          value_date?: string | null;
          amount: number;
          currency?: string;
          counterparty_name?: string | null;
          purpose?: string | null;
          categorization_source?: Database['public']['Enums']['categorization_source'] | null;
          external_id?: string | null;
          import_hash?: string | null;
          notes?: string | null;
          exclude_from_budget?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          account_id?: string;
          category_id?: string | null;
          booking_date?: string;
          value_date?: string | null;
          amount?: number;
          currency?: string;
          counterparty_name?: string | null;
          purpose?: string | null;
          categorization_source?: Database['public']['Enums']['categorization_source'] | null;
          external_id?: string | null;
          import_hash?: string | null;
          notes?: string | null;
          exclude_from_budget?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'transactions_account_fkey';
            columns: ['account_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'accounts';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transactions_category_fkey';
            columns: ['category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      portfolios: {
        Row: {
          id: string;
          user_id: string;
          account_id: string | null;
          name: string;
          broker: string | null;
          currency: string;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          account_id?: string | null;
          name: string;
          broker?: string | null;
          currency?: string;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          account_id?: string | null;
          name?: string;
          broker?: string | null;
          currency?: string;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'portfolios_account_fkey';
            columns: ['account_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'accounts';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      assets: {
        Row: {
          id: string;
          user_id: string;
          portfolio_id: string | null;
          name: string;
          instrument_type: Database['public']['Enums']['instrument_type'];
          asset_class: Database['public']['Enums']['asset_class'];
          region: Database['public']['Enums']['market_region'];
          isin: string | null;
          wkn: string | null;
          ticker: string | null;
          sector: string | null;
          currency: string;
          quantity: number;
          avg_purchase_price: number | null;
          current_price: number | null;
          price_updated_at: string | null;
          market_value: number;
          exposure: Json;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          portfolio_id?: string | null;
          name: string;
          instrument_type: Database['public']['Enums']['instrument_type'];
          asset_class: Database['public']['Enums']['asset_class'];
          region?: Database['public']['Enums']['market_region'];
          isin?: string | null;
          wkn?: string | null;
          ticker?: string | null;
          sector?: string | null;
          currency?: string;
          quantity?: number;
          avg_purchase_price?: number | null;
          current_price?: number | null;
          price_updated_at?: string | null;
          market_value?: never;
          exposure?: Json;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          portfolio_id?: string | null;
          name?: string;
          instrument_type?: Database['public']['Enums']['instrument_type'];
          asset_class?: Database['public']['Enums']['asset_class'];
          region?: Database['public']['Enums']['market_region'];
          isin?: string | null;
          wkn?: string | null;
          ticker?: string | null;
          sector?: string | null;
          currency?: string;
          quantity?: number;
          avg_purchase_price?: number | null;
          current_price?: number | null;
          price_updated_at?: string | null;
          market_value?: never;
          exposure?: Json;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'assets_portfolio_fkey';
            columns: ['portfolio_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'portfolios';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      real_estate_objects: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          usage: Database['public']['Enums']['real_estate_usage'];
          street: string | null;
          postal_code: string | null;
          city: string | null;
          country_code: string;
          purchase_date: string | null;
          purchase_price: number | null;
          ancillary_purchase_costs: number;
          current_value: number | null;
          valuation_date: string | null;
          living_area_sqm: number | null;
          monthly_cold_rent: number;
          monthly_non_allocable_costs: number;
          building_share_pct: number | null;
          loan_account_id: string | null;
          notes: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          name: string;
          usage?: Database['public']['Enums']['real_estate_usage'];
          street?: string | null;
          postal_code?: string | null;
          city?: string | null;
          country_code?: string;
          purchase_date?: string | null;
          purchase_price?: number | null;
          ancillary_purchase_costs?: number;
          current_value?: number | null;
          valuation_date?: string | null;
          living_area_sqm?: number | null;
          monthly_cold_rent?: number;
          monthly_non_allocable_costs?: number;
          building_share_pct?: number | null;
          loan_account_id?: string | null;
          notes?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          usage?: Database['public']['Enums']['real_estate_usage'];
          street?: string | null;
          postal_code?: string | null;
          city?: string | null;
          country_code?: string;
          purchase_date?: string | null;
          purchase_price?: number | null;
          ancillary_purchase_costs?: number;
          current_value?: number | null;
          valuation_date?: string | null;
          living_area_sqm?: number | null;
          monthly_cold_rent?: number;
          monthly_non_allocable_costs?: number;
          building_share_pct?: number | null;
          loan_account_id?: string | null;
          notes?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'real_estate_objects_loan_account_fkey';
            columns: ['loan_account_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'accounts';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };
    };

    Views: {
      [_ in never]: never;
    };

    Functions: {
      accept_advisor_invitation: {
        Args: { p_token: string };
        Returns: string;
      };
    };

    Enums: {
      user_role: 'client' | 'advisor';
      advisor_link_status: 'invited' | 'active' | 'revoked';
      account_type: 'checking' | 'savings' | 'credit_card' | 'depot' | 'loan' | 'cash' | 'other';
      account_provider: 'manual' | 'csv' | 'gocardless' | 'enable_banking' | 'plaid';
      category_kind: 'income' | 'expense' | 'transfer';
      categorization_source: 'manual' | 'rule' | 'provider' | 'ai';
      instrument_type: 'stock' | 'etf' | 'fund' | 'bond' | 'crypto' | 'commodity' | 'cash' | 'other';
      asset_class: 'equity' | 'fixed_income' | 'real_estate' | 'commodity' | 'crypto' | 'cash' | 'other';
      market_region:
        | 'global'
        | 'north_america'
        | 'europe'
        | 'japan'
        | 'asia_pacific'
        | 'emerging_markets'
        | 'other';
      real_estate_usage: 'self_occupied' | 'rented' | 'mixed' | 'vacant';
    };

    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

// ---------------------------------------------------------------------
// Helper-Typen (Kurzformen wie im Supabase-Generator)
// ---------------------------------------------------------------------
type PublicSchema = Database['public'];

export type Tables<T extends keyof PublicSchema['Tables']> = PublicSchema['Tables'][T]['Row'];

export type TablesInsert<T extends keyof PublicSchema['Tables']> =
  PublicSchema['Tables'][T]['Insert'];

export type TablesUpdate<T extends keyof PublicSchema['Tables']> =
  PublicSchema['Tables'][T]['Update'];

export type Enums<T extends keyof PublicSchema['Enums']> = PublicSchema['Enums'][T];

export type Functions<T extends keyof PublicSchema['Functions']> = PublicSchema['Functions'][T];

// Laufzeit-Konstanten, z. B. für Zod-Schemas oder Select-Optionen.
export const Constants = {
  public: {
    Enums: {
      user_role: ['client', 'advisor'],
      advisor_link_status: ['invited', 'active', 'revoked'],
      account_type: ['checking', 'savings', 'credit_card', 'depot', 'loan', 'cash', 'other'],
      account_provider: ['manual', 'csv', 'gocardless', 'enable_banking', 'plaid'],
      category_kind: ['income', 'expense', 'transfer'],
      categorization_source: ['manual', 'rule', 'provider', 'ai'],
      instrument_type: ['stock', 'etf', 'fund', 'bond', 'crypto', 'commodity', 'cash', 'other'],
      asset_class: ['equity', 'fixed_income', 'real_estate', 'commodity', 'crypto', 'cash', 'other'],
      market_region: [
        'global',
        'north_america',
        'europe',
        'japan',
        'asia_pacific',
        'emerging_markets',
        'other',
      ],
      real_estate_usage: ['self_occupied', 'rented', 'mixed', 'vacant'],
    },
  },
} as const;
