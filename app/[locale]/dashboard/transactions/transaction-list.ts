/**
 * app/[locale]/dashboard/transactions/transaction-list.ts
 *
 * Lädt eine Seite der Transaktionsliste eines Nutzers – gemeinsam genutzt
 * von der eigenen Liste (/dashboard/transactions) und der Leseansicht des
 * Beraters (/advisor/clients/[clientId]).
 *
 * Reihenfolge: booking_date absteigend, bei gleichem Datum die neueste
 * Erfassung oben (created_at absteigend), id als letzter Tiebreaker – genau
 * die Reihenfolge des Index transactions_user_booking_created_idx
 * (Migration 20261002130000). Seiten per LIMIT/OFFSET (.range()).
 *
 * Die Abfrage filtert ausdrücklich auf user_id = übergebener Nutzer: RLS
 * lässt Berater die Buchungen ALLER aktiven Mandanten lesen (und den Nutzer
 * zusätzlich seine eigenen) – ohne Filter wären die Listen vermischt.
 */
import 'server-only';

import { redirect } from 'next/navigation';

import { localizedPath } from '@/i18n/paths';
import { createClient } from '@/lib/supabase/server';
import {
  UNCATEGORIZED,
  ilikeContainsPattern,
  listQueryString,
  pageCount,
  pageRange,
  type TransactionFilters,
} from '@/lib/transaction-filters';

type LoadTransactionListOptions = {
  userId: string;
  filters: TransactionFilters;
  page: number;
  /** Pfad der Liste ohne Sprachpräfix – Ziel bei Seiten jenseits des Endes. */
  listPath: string;
};

export async function loadTransactionList({ userId, filters, page, listPath }: LoadTransactionListOptions) {
  const supabase = await createClient();

  /** Gefilterte Abfrage; head: nur zählen (für Seiten jenseits des Endes). */
  const buildQuery = (head = false) => {
    let request = supabase
      .from('transactions')
      // tag_filter: eigener Alias nur für den Tag-Filter, damit transaction_tags
      // weiterhin ALLE Tags der Buchung liefert.
      .select(
        `id, source, booking_date, amount, currency, counterparty_name, purpose, categorization_source,
         account:accounts!transactions_account_fkey ( name ),
         rule:categorization_rules!transactions_categorization_rule_fkey ( pattern, origin ),
         category:categories!transactions_category_fkey ( name, default_key, color ),
         transaction_tags ( tag:tags!transaction_tags_tag_fkey ( id, name ) ),
         tag_filter:transaction_tags ( tag_id )`,
        { count: 'exact', head },
      )
      .eq('user_id', userId);

    if (filters.q) {
      const pattern = ilikeContainsPattern(filters.q);
      request = request.or(`counterparty_name.ilike.${pattern},purpose.ilike.${pattern}`);
    }
    if (filters.type === 'expense') {
      request = request.lt('amount', 0);
    } else if (filters.type === 'income') {
      request = request.gt('amount', 0);
    }
    if (filters.accountId) {
      request = request.eq('account_id', filters.accountId);
    }
    if (filters.categoryId === UNCATEGORIZED) {
      request = request.is('category_id', null);
    } else if (filters.categoryId) {
      request = request.eq('category_id', filters.categoryId);
    }
    if (filters.tagId) {
      // Eingebettete Zeilen filtern und Buchungen ohne Treffer ausschließen
      // (PostgREST: Null-Filter auf der Einbettung wirkt wie ein Inner Join).
      request = request.eq('tag_filter.tag_id', filters.tagId).not('tag_filter', 'is', null);
    }
    if (filters.assigned === 'auto') {
      request = request.eq('categorization_source', 'rule');
    } else if (filters.assigned === 'manual') {
      request = request
        .not('category_id', 'is', null)
        .or('categorization_source.is.null,categorization_source.neq.rule');
    }
    if (filters.from) {
      request = request.gte('booking_date', filters.from);
    }
    if (filters.to) {
      request = request.lte('booking_date', filters.to);
    }
    return request;
  };

  const { from, to } = pageRange(page);
  const { data: transactions, count, error } = await buildQuery()
    .order('booking_date', { ascending: false })
    .order('created_at', { ascending: false })
    .order('id', { ascending: true })
    .range(from, to);

  // Seite jenseits des Endes (alter Link, manipulierte URL): PostgREST
  // antwortet mit PGRST103 ohne Gesamtzahl → zählen und zur letzten Seite.
  if (error?.code === 'PGRST103') {
    const { count: total } = await buildQuery(true);
    redirect(`${await localizedPath(listPath)}${listQueryString(filters, pageCount(total ?? 0))}`);
  }
  if (error) {
    console.error('[transactions] Laden fehlgeschlagen', { code: error.code });
  }

  const total = count ?? 0;
  return {
    transactions: error ? null : (transactions ?? []),
    total,
    pages: pageCount(total),
    /** 1-basierte Nummer der ersten Zeile dieser Seite. */
    firstRow: from + 1,
  };
}

export type TransactionListRow = NonNullable<
  Awaited<ReturnType<typeof loadTransactionList>>['transactions']
>[number];
