/**
 * types/database.ts
 *
 * Typdefinitionen im Format von `supabase gen types typescript`, 1:1 passend
 * zu supabase/migrations/. Nach jeder Migration neu generieren:
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
          password_set_at: string | null;
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
          password_set_at?: never;
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
          password_set_at?: never;
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
          opening_balance: number;
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
          opening_balance?: number;
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
          opening_balance?: number;
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
          parent_category_id: string | null;
          name: string;
          kind: Database['public']['Enums']['category_kind'];
          color: string | null;
          icon: string | null;
          is_default: boolean;
          sort_order: number;
          default_key: string | null;
          budget_group: Database['public']['Enums']['budget_group'] | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          parent_category_id?: string | null;
          name: string;
          kind: Database['public']['Enums']['category_kind'];
          color?: string | null;
          icon?: string | null;
          is_default?: boolean;
          sort_order?: number;
          default_key?: string | null;
          budget_group?: Database['public']['Enums']['budget_group'] | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          parent_category_id?: string | null;
          name?: string;
          kind?: Database['public']['Enums']['category_kind'];
          color?: string | null;
          icon?: string | null;
          is_default?: boolean;
          sort_order?: number;
          default_key?: string | null;
          budget_group?: Database['public']['Enums']['budget_group'] | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'categories_parent_fkey';
            columns: ['parent_category_id', 'user_id'];
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
          transaction_type: string | null;
          counterparty_iban: string | null;
          description: string | null;
          categorization_source: Database['public']['Enums']['categorization_source'] | null;
          categorization_rule_id: string | null;
          counterparty_key: string | null;
          recurrence: 'weekly' | 'biweekly' | 'monthly' | 'bimonthly' | 'quarterly' | 'semiannual' | 'yearly' | null;
          auto_category_id: string | null;
          auto_source: Database['public']['Enums']['categorization_source'] | null;
          auto_rule_id: string | null;
          features: string[] | null;
          categorization_confidence: number | null;
          auto_confidence: number | null;
          suggested_category_id: string | null;
          suggestion_confidence: number | null;
          external_id: string | null;
          import_hash: string | null;
          notes: string | null;
          exclude_from_budget: boolean;
          source: Database['public']['Enums']['transaction_source'];
          recurring_contract_id: string | null;
          contract_link_manual: boolean;
          mandate_reference: string | null;
          creditor_id: string | null;
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
          transaction_type?: string | null;
          counterparty_iban?: string | null;
          description?: string | null;
          categorization_source?: Database['public']['Enums']['categorization_source'] | null;
          categorization_rule_id?: string | null;
          counterparty_key?: string | null;
          recurrence?: 'weekly' | 'biweekly' | 'monthly' | 'bimonthly' | 'quarterly' | 'semiannual' | 'yearly' | null;
          auto_category_id?: string | null;
          auto_source?: Database['public']['Enums']['categorization_source'] | null;
          auto_rule_id?: string | null;
          features?: string[] | null;
          categorization_confidence?: number | null;
          auto_confidence?: number | null;
          suggested_category_id?: string | null;
          suggestion_confidence?: number | null;
          external_id?: string | null;
          import_hash?: string | null;
          notes?: string | null;
          exclude_from_budget?: boolean;
          source?: Database['public']['Enums']['transaction_source'];
          recurring_contract_id?: string | null;
          contract_link_manual?: boolean;
          mandate_reference?: string | null;
          creditor_id?: string | null;
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
          transaction_type?: string | null;
          counterparty_iban?: string | null;
          description?: string | null;
          categorization_source?: Database['public']['Enums']['categorization_source'] | null;
          categorization_rule_id?: string | null;
          counterparty_key?: string | null;
          recurrence?: 'weekly' | 'biweekly' | 'monthly' | 'bimonthly' | 'quarterly' | 'semiannual' | 'yearly' | null;
          auto_category_id?: string | null;
          auto_source?: Database['public']['Enums']['categorization_source'] | null;
          auto_rule_id?: string | null;
          features?: string[] | null;
          categorization_confidence?: number | null;
          auto_confidence?: number | null;
          suggested_category_id?: string | null;
          suggestion_confidence?: number | null;
          external_id?: string | null;
          import_hash?: string | null;
          notes?: string | null;
          exclude_from_budget?: boolean;
          source?: Database['public']['Enums']['transaction_source'];
          recurring_contract_id?: string | null;
          contract_link_manual?: boolean;
          mandate_reference?: string | null;
          creditor_id?: string | null;
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
          {
            foreignKeyName: 'transactions_recurring_contract_fkey';
            columns: ['recurring_contract_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'recurring_contracts';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transactions_categorization_rule_fkey';
            columns: ['categorization_rule_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categorization_rules';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transactions_auto_category_fkey';
            columns: ['auto_category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transactions_suggested_category_fkey';
            columns: ['suggested_category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transactions_auto_rule_fkey';
            columns: ['auto_rule_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categorization_rules';
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

      tags: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          color: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          name: string;
          color?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          color?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      transaction_tags: {
        Row: {
          transaction_id: string;
          tag_id: string;
          user_id: string;
          created_at: string;
        };
        Insert: {
          transaction_id: string;
          tag_id: string;
          user_id?: string;
          created_at?: string;
        };
        Update: {
          transaction_id?: string;
          tag_id?: string;
          user_id?: string;
          created_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'transaction_tags_transaction_fkey';
            columns: ['transaction_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'transactions';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'transaction_tags_tag_fkey';
            columns: ['tag_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'tags';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      budgets: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          category_id: string | null;
          tag_id: string | null;
          account_id: string | null;
          period: Database['public']['Enums']['budget_period'];
          starts_on: string;
          ends_on: string | null;
          amount: number;
          currency: string;
          alert_threshold_pct: number;
          is_active: boolean;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          name: string;
          category_id?: string | null;
          tag_id?: string | null;
          account_id?: string | null;
          period?: Database['public']['Enums']['budget_period'];
          starts_on?: string;
          ends_on?: string | null;
          amount: number;
          currency?: string;
          alert_threshold_pct?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          category_id?: string | null;
          tag_id?: string | null;
          account_id?: string | null;
          period?: Database['public']['Enums']['budget_period'];
          starts_on?: string;
          ends_on?: string | null;
          amount?: number;
          currency?: string;
          alert_threshold_pct?: number;
          is_active?: boolean;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'budgets_category_fkey';
            columns: ['category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'budgets_tag_fkey';
            columns: ['tag_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'tags';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'budgets_account_fkey';
            columns: ['account_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'accounts';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      budget_settings: {
        Row: {
          user_id: string;
          basis: Database['public']['Enums']['budget_basis'];
          needs_pct: number;
          wants_pct: number;
          savings_pct: number;
          fixed_amount: number | null;
          fixed_currency: string;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          user_id?: string;
          basis?: Database['public']['Enums']['budget_basis'];
          needs_pct?: number;
          wants_pct?: number;
          savings_pct?: number;
          fixed_amount?: number | null;
          fixed_currency?: string;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          user_id?: string;
          basis?: Database['public']['Enums']['budget_basis'];
          needs_pct?: number;
          wants_pct?: number;
          savings_pct?: number;
          fixed_amount?: number | null;
          fixed_currency?: string;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [];
      };

      recurring_contracts: {
        Row: {
          id: string;
          user_id: string;
          name: string;
          counterparty_name: string | null;
          match_pattern: string | null;
          account_id: string | null;
          category_id: string | null;
          rhythm: Database['public']['Enums']['contract_rhythm'];
          interval_count: number;
          expected_amount: number | null;
          amount_tolerance_pct: number;
          currency: string;
          first_booking_date: string | null;
          last_booking_date: string | null;
          next_expected_date: string | null;
          notice_period_days: number | null;
          term_end_date: string | null;
          cancellation_deadline: string | null;
          auto_renewal: boolean;
          status: Database['public']['Enums']['contract_status'];
          detection_source: Database['public']['Enums']['contract_detection'];
          detection_confidence: number | null;
          cancelled_on: string | null;
          notes: string | null;
          contract_type: Database['public']['Enums']['contract_type'];
          counterparty_key: string | null;
          mandate_reference: string | null;
          creditor_id: string | null;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          name: string;
          counterparty_name?: string | null;
          match_pattern?: string | null;
          account_id?: string | null;
          category_id?: string | null;
          rhythm?: Database['public']['Enums']['contract_rhythm'];
          interval_count?: number;
          expected_amount?: number | null;
          amount_tolerance_pct?: number;
          currency?: string;
          first_booking_date?: string | null;
          last_booking_date?: string | null;
          next_expected_date?: string | null;
          notice_period_days?: number | null;
          term_end_date?: string | null;
          cancellation_deadline?: never;
          auto_renewal?: boolean;
          status?: Database['public']['Enums']['contract_status'];
          detection_source?: Database['public']['Enums']['contract_detection'];
          detection_confidence?: number | null;
          cancelled_on?: string | null;
          notes?: string | null;
          contract_type?: Database['public']['Enums']['contract_type'];
          counterparty_key?: string | null;
          mandate_reference?: string | null;
          creditor_id?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          name?: string;
          counterparty_name?: string | null;
          match_pattern?: string | null;
          account_id?: string | null;
          category_id?: string | null;
          rhythm?: Database['public']['Enums']['contract_rhythm'];
          interval_count?: number;
          expected_amount?: number | null;
          amount_tolerance_pct?: number;
          currency?: string;
          first_booking_date?: string | null;
          last_booking_date?: string | null;
          next_expected_date?: string | null;
          notice_period_days?: number | null;
          term_end_date?: string | null;
          cancellation_deadline?: never;
          auto_renewal?: boolean;
          status?: Database['public']['Enums']['contract_status'];
          detection_source?: Database['public']['Enums']['contract_detection'];
          detection_confidence?: number | null;
          cancelled_on?: string | null;
          notes?: string | null;
          contract_type?: Database['public']['Enums']['contract_type'];
          counterparty_key?: string | null;
          mandate_reference?: string | null;
          creditor_id?: string | null;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'recurring_contracts_account_fkey';
            columns: ['account_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'accounts';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'recurring_contracts_category_fkey';
            columns: ['category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
        ];
      };

      categorization_settings: {
        Row: {
          user_id: string;
          bayes_threshold: number;
          review_amount_limit: number;
          updated_at: string;
        };
        Insert: {
          user_id?: string;
          bayes_threshold?: number;
          review_amount_limit?: number;
          updated_at?: string;
        };
        Update: {
          user_id?: string;
          bayes_threshold?: number;
          review_amount_limit?: number;
          updated_at?: string;
        };
        Relationships: [];
      };

      categorization_rules: {
        Row: {
          id: string;
          user_id: string;
          category_id: string;
          name: string | null;
          match_field: Database['public']['Enums']['rule_match_field'];
          match_type: Database['public']['Enums']['rule_match_type'];
          pattern: string;
          case_sensitive: boolean;
          account_id: string | null;
          amount_min: number | null;
          amount_max: number | null;
          priority: number;
          is_active: boolean;
          origin: string;
          created_at: string;
          updated_at: string;
        };
        Insert: {
          id?: string;
          user_id?: string;
          category_id: string;
          name?: string | null;
          match_field?: Database['public']['Enums']['rule_match_field'];
          match_type?: Database['public']['Enums']['rule_match_type'];
          pattern: string;
          case_sensitive?: boolean;
          account_id?: string | null;
          amount_min?: number | null;
          amount_max?: number | null;
          priority?: number;
          is_active?: boolean;
          origin?: string;
          created_at?: string;
          updated_at?: string;
        };
        Update: {
          id?: string;
          user_id?: string;
          category_id?: string;
          name?: string | null;
          match_field?: Database['public']['Enums']['rule_match_field'];
          match_type?: Database['public']['Enums']['rule_match_type'];
          pattern?: string;
          case_sensitive?: boolean;
          account_id?: string | null;
          amount_min?: number | null;
          amount_max?: number | null;
          priority?: number;
          is_active?: boolean;
          origin?: string;
          created_at?: string;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: 'categorization_rules_category_fkey';
            columns: ['category_id', 'user_id'];
            isOneToOne: false;
            referencedRelation: 'categories';
            referencedColumns: ['id', 'user_id'];
          },
          {
            foreignKeyName: 'categorization_rules_account_fkey';
            columns: ['account_id', 'user_id'];
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
      create_manual_transaction: {
        Args: {
          p_booking_date: string;
          p_amount: number;
          p_counterparty_name: string;
          p_purpose?: string;
          p_account_id?: string;
          p_category_id?: string;
          p_tag_ids?: string[];
          p_new_tag_names?: string[];
          p_currency?: string;
        };
        Returns: string;
      };
      update_manual_transaction: {
        Args: {
          p_id: string;
          p_booking_date: string;
          p_amount: number;
          p_counterparty_name: string;
          p_purpose?: string;
          p_account_id?: string;
          p_category_id?: string;
          p_tag_ids?: string[];
          p_new_tag_names?: string[];
          p_currency?: string;
        };
        Returns: string;
      };
      delete_manual_transaction: {
        Args: { p_id: string };
        Returns: undefined;
      };
      account_foreign_currency_totals: {
        Args: { p_user_id: string };
        Returns: { account_id: string; currency: string; total: number }[];
      };
      set_category_budget_groups: {
        Args: { p_assignments: Json };
        Returns: number;
      };
      create_categorization_rule: {
        Args: {
          p_pattern: string;
          p_category_id: string;
          p_match_field?: Database['public']['Enums']['rule_match_field'];
          p_match_type?: Database['public']['Enums']['rule_match_type'];
          p_direction?: 'in' | 'out' | null;
        };
        Returns: string;
      };
      load_standard_rules: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      apply_categorization_rules: {
        Args: { p_rule_id?: string | null; p_dry_run?: boolean; p_overwrite_auto?: boolean };
        Returns: number;
      };
      add_own_account_identifier: {
        Args: { p_kind: 'name' | 'iban'; p_value: string; p_category_id?: string | null };
        Returns: Json;
      };
      set_own_account_category: {
        Args: { p_rule_id: string; p_category_id: string };
        Returns: number;
      };
      categorization_quality: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      rule_quality: {
        Args: { p_min_hits?: number; p_max_error?: number };
        Returns: {
          rule_id: string | null;
          pattern: string | null;
          origin: string;
          is_active: boolean;
          hits: number;
          corrected: number;
          flagged: boolean;
        }[];
      };
      set_rule_active: {
        Args: { p_rule_id: string; p_active: boolean };
        Returns: undefined;
      };
      uncategorized_groups: {
        Args: { p_limit?: number };
        Returns: {
          group_key: string;
          label: string | null;
          tx_count: number;
          total: number;
          currency: string;
          first_date: string;
          last_date: string;
          samples: string[] | null;
          recurrence: string | null;
          suggestion_category_id: string | null;
          suggestion_source: 'own_name' | 'memory' | 'variant' | null;
          suggestion_detail: string | null;
        }[];
      };
      categorize_group: {
        Args: { p_key: string; p_category_id: string };
        Returns: number;
      };
      refresh_suggestions: {
        Args: Record<PropertyKey, never>;
        Returns: number;
      };
      refresh_contracts: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      sync_contracts: {
        Args: Record<PropertyKey, never>;
        Returns: number;
      };
      budget_category_totals: {
        Args: { p_user_id: string; p_from: string; p_to: string };
        Returns: {
          month: string;
          currency: string;
          category_id: string | null;
          budget_group: Database['public']['Enums']['budget_group'] | null;
          kind: Database['public']['Enums']['category_kind'] | null;
          flag: string | null;
          own_account: boolean;
          amount: number;
        }[];
      };
      save_category_budget: {
        Args: {
          p_id: string | null;
          p_category_id: string;
          p_period: Database['public']['Enums']['budget_period'];
          p_amount: number;
          p_currency: string;
          p_threshold_pct: number;
        };
        Returns: string;
      };
      save_budget_settings: {
        Args: {
          p_basis: Database['public']['Enums']['budget_basis'];
          p_needs_pct: number;
          p_wants_pct: number;
          p_savings_pct: number;
          p_fixed_amount: number | null;
          p_fixed_currency: string;
        };
        Returns: undefined;
      };
      contract_actuals: {
        Args: { p_user_id: string; p_from: string; p_to: string };
        Returns: {
          contract_id: string;
          currency: string;
          debit_count: number;
          debits: number;
          credit_count: number;
          credits: number;
        }[];
      };
      contract_counterparties: {
        Args: { p_limit?: number };
        Returns: {
          counterparty_key: string;
          label: string | null;
          tx_count: number;
          last_amount: number;
          last_date: string;
          recurrence: string | null;
          contract_type: Database['public']['Enums']['contract_type'];
          has_contract: boolean;
        }[];
      };
      save_contract: {
        Args: {
          p_id: string | null;
          p_name: string;
          p_counterparty_key: string | null;
          p_counterparty_name: string | null;
          p_rhythm: Database['public']['Enums']['contract_rhythm'];
          p_interval_count: number;
          p_amount: number;
          p_next_expected_date: string | null;
          p_contract_type: Database['public']['Enums']['contract_type'];
          p_account_id: string | null;
          p_category_id: string | null;
          p_notes: string | null;
          p_tolerance_pct?: number;
        };
        Returns: string;
      };
      set_contract_status: {
        Args: {
          p_id: string;
          p_status: Database['public']['Enums']['contract_status'];
          p_contract_type?: Database['public']['Enums']['contract_type'] | null;
        };
        Returns: undefined;
      };
      delete_contract: {
        Args: { p_id: string };
        Returns: undefined;
      };
      set_contract_link: {
        Args: { p_transaction_id: string; p_contract_id: string | null };
        Returns: undefined;
      };
      confirm_suggestions: {
        Args: { p_ids: string[] };
        Returns: number;
      };
      save_categorization_settings: {
        Args: { p_threshold: number; p_review_amount_limit: number };
        Returns: undefined;
      };
      bayes_evaluate: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      reset_machine_categorization: {
        Args: Record<PropertyKey, never>;
        Returns: number;
      };
      categorization_stats: {
        Args: Record<PropertyKey, never>;
        Returns: Json;
      };
      reorder_categorization_rules: {
        Args: { p_ids: string[] };
        Returns: undefined;
      };
      import_transactions: {
        Args: {
          p_account_id: string | null;
          p_rows: Json;
          p_dry_run?: boolean;
          p_new_account_name?: string | null;
          p_new_account_currency?: string | null;
        };
        Returns: Json;
      };
      set_transaction_category: {
        Args: { p_id: string; p_category_id: string | null };
        Returns: Json;
      };
    };

    Enums: {
      user_role: 'client' | 'advisor';
      advisor_link_status: 'invited' | 'active' | 'revoked';
      account_type: 'checking' | 'savings' | 'credit_card' | 'depot' | 'loan' | 'cash' | 'other';
      account_provider: 'manual' | 'csv' | 'gocardless' | 'enable_banking' | 'plaid';
      category_kind: 'income' | 'expense' | 'transfer';
      categorization_source: 'manual' | 'rule' | 'provider' | 'ai' | 'learned';
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
      transaction_source: 'manual' | 'csv_import' | 'bank_sync';
      budget_period: 'weekly' | 'monthly' | 'quarterly' | 'yearly';
      budget_group: 'needs' | 'wants' | 'savings';
      contract_rhythm: 'weekly' | 'monthly' | 'quarterly' | 'semiannual' | 'yearly';
      contract_status: 'suggested' | 'active' | 'cancellation_pending' | 'cancelled' | 'dismissed';
      contract_detection: 'manual' | 'auto';
      budget_basis: 'expenses' | 'expenses_avg3' | 'fixed' | 'income';
      contract_type:
        | 'subscription'
        | 'telecom'
        | 'energy'
        | 'insurance'
        | 'housing'
        | 'loan'
        | 'membership'
        | 'public_fee'
        | 'savings'
        | 'other';
      rule_match_field:
        | 'counterparty'
        | 'purpose'
        | 'counterparty_or_purpose'
        | 'transaction_type'
        | 'counterparty_iban'
        | 'description'
        | 'any_text';
      rule_match_type: 'contains' | 'equals' | 'starts_with' | 'regex' | 'word' | 'all_words';
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
      categorization_source: ['manual', 'rule', 'provider', 'ai', 'learned'],
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
      transaction_source: ['manual', 'csv_import', 'bank_sync'],
      budget_period: ['weekly', 'monthly', 'quarterly', 'yearly'],
      budget_group: ['needs', 'wants', 'savings'],
      contract_rhythm: ['weekly', 'monthly', 'quarterly', 'semiannual', 'yearly'],
      contract_status: ['suggested', 'active', 'cancellation_pending', 'cancelled', 'dismissed'],
      contract_detection: ['manual', 'auto'],
      budget_basis: ['expenses', 'expenses_avg3', 'fixed', 'income'],
      contract_type: [
        'subscription',
        'telecom',
        'energy',
        'insurance',
        'housing',
        'loan',
        'membership',
        'public_fee',
        'savings',
        'other',
      ],
      rule_match_field: [
        'counterparty',
        'purpose',
        'counterparty_or_purpose',
        'transaction_type',
        'counterparty_iban',
        'description',
        'any_text',
      ],
      rule_match_type: ['contains', 'equals', 'starts_with', 'regex', 'word', 'all_words'],
    },
  },
} as const;
