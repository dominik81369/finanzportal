/**
 * lib/transaction-form-types.ts
 *
 * Gemeinsame Typen des Buchungsformulars (Anlegen und Bearbeiten) – für
 * Server Actions und Client-Komponenten.
 */

export type TransactionType = 'expense' | 'income';

export type TransactionField =
  | 'type'
  | 'amount'
  | 'currency'
  | 'bookingDate'
  | 'counterparty'
  | 'purpose'
  | 'account'
  | 'category'
  | 'tags';

/** Formularwerte als Strings – zum Vorbelegen (Bearbeiten, nach Fehlern). */
export type TransactionFormValues = {
  type: TransactionType;
  amount: string;
  currency: string;
  bookingDate: string;
  counterparty: string;
  purpose: string;
  accountId: string;
  categoryId: string;
  tagIds: string[];
  newTags: string;
};

export type TransactionFormState = {
  status: 'idle' | 'error';
  message?: string;
  fieldErrors?: Partial<Record<TransactionField, string>>;
  /** Zum Vorbelegen des Formulars nach einem Fehler. */
  values?: TransactionFormValues;
};

export type TransactionFormAction = (
  prevState: TransactionFormState,
  formData: FormData,
) => Promise<TransactionFormState>;
