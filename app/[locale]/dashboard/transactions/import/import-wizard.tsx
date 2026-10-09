'use client';

/**
 * Import-Assistent für Kontoauszüge (CSV/Excel).
 *
 * 1. Datei und Zielkonto wählen. Die Datei wird im Browser gelesen:
 *    Encoding und Trennzeichen erkannt (CSV) bzw. erstes Tabellenblatt
 *    gelesen (Excel), Kopfzeile gesucht, Spalten zugeordnet (lib/import/).
 * 2. Vorschau: erkannte Zuordnung (bei Unsicherheit hervorgehoben und
 *    jederzeit änderbar), Beispielzeilen, Zeilenfehler, Saldenabgleich und –
 *    per Dry-Run der Datenbank – neue Buchungen, Duplikate, Regel-Treffer.
 * 3. Import und Ergebnis, inklusive Abgleich gegen den Endsaldo der Datei.
 */
import { useFormatter, useTranslations } from 'next-intl';
import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react';

import { Link } from '@/i18n/navigation';
import {
  previewImport,
  runImport,
  type ImportRequest,
  type ImportSummary,
} from '@/lib/actions/import-transactions';
import { decodeBytes, detectDelimiter, parseCsv, type Delimiter, type DetectedEncoding } from '@/lib/import/parse';
import {
  IMPORT_FIELDS,
  MAX_IMPORT_ROWS,
  REQUIRED_FIELDS,
  buildRows,
  detectColumns,
  findHeaderRow,
  type Cell,
  type ColumnMapping,
  type ImportField,
} from '@/lib/import/statement';

type AccountOption = { id: string; name: string; currency: string };

type ImportWizardProps = {
  accounts: AccountOption[];
  currencies: readonly string[];
};

type LoadedFile = {
  name: string;
  kind: 'csv' | 'xlsx';
  cells: Cell[][];
  encoding: DetectedEncoding | null;
  delimiter: Delimiter | null;
};

const MAX_FILE_BYTES = 5 * 1024 * 1024;
const NEW_ACCOUNT = 'new';
const SAMPLE_ROWS = 8;

// Felder in der manuellen Zuordnung (Währung kommt aus dem Konto).
const MAPPED_FIELDS: readonly ImportField[] = [
  'date',
  'amount',
  'purpose',
  'counterparty',
  'valueDate',
  'balance',
  'transactionType',
  'counterpartyIban',
  'description',
  'mandateReference',
  'creditorId',
  'bookingStatus',
];

const emptyMapping = (): ColumnMapping =>
  Object.fromEntries(IMPORT_FIELDS.map((field) => [field, null])) as ColumnMapping;

async function readFile(file: File): Promise<LoadedFile> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b; // „PK“ – .xlsx ist ein ZIP-Archiv
  if (isZip || /\.xlsx$/i.test(file.name)) {
    const { readSheet } = await import('read-excel-file/browser');
    const cells = (await readSheet(file)) as Cell[][];
    return { name: file.name, kind: 'xlsx', cells, encoding: null, delimiter: null };
  }
  if (/\.xls$/i.test(file.name) || (bytes[0] === 0xd0 && bytes[1] === 0xcf)) {
    throw new Error('legacyExcel');
  }
  const { text, encoding } = decodeBytes(bytes);
  const delimiter = detectDelimiter(text);
  return { name: file.name, kind: 'csv', cells: parseCsv(text, delimiter), encoding, delimiter };
}

export function ImportWizard({ accounts, currencies }: ImportWizardProps) {
  const t = useTranslations('Import');
  const format = useFormatter();

  const [target, setTarget] = useState<string>(accounts[0]?.id ?? NEW_ACCOUNT);
  const [newName, setNewName] = useState('');
  const [newCurrency, setNewCurrency] = useState(currencies[0] ?? 'EUR');
  const [loadError, setLoadError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const [loaded, setLoaded] = useState<LoadedFile | null>(null);
  const [headerIndex, setHeaderIndex] = useState<number | null>(null);
  const [mapping, setMapping] = useState<ColumnMapping>(emptyMapping);
  const [autoConfident, setAutoConfident] = useState(true);

  const [preview, setPreview] = useState<ImportSummary | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [importing, setImporting] = useState(false);
  const [result, setResult] = useState<ImportSummary | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const previewRequest = useRef(0);
  const fileInput = useRef<HTMLInputElement>(null);

  const account = accounts.find((a) => a.id === target) ?? null;
  const accountCurrency = account?.currency ?? newCurrency;
  const money = (value: number, currency = accountCurrency) =>
    format.number(value, { style: 'currency', currency });

  const header = loaded && headerIndex !== null ? (loaded.cells[headerIndex] ?? []) : [];
  const missing = REQUIRED_FIELDS.filter((field) => mapping[field] === null);
  const built = useMemo(() => {
    if (!loaded || headerIndex === null || REQUIRED_FIELDS.some((field) => mapping[field] === null)) {
      return null;
    }
    return buildRows(loaded.cells, headerIndex, mapping);
  }, [loaded, headerIndex, mapping]);

  /** Anfrage an die Datenbank; der Name eines neuen Kontos zählt erst beim Import. */
  const buildRequest = (name: string): ImportRequest | null => {
    if (!built || built.rows.length === 0 || built.rows.length > MAX_IMPORT_ROWS) {
      return null;
    }
    return target === NEW_ACCOUNT
      ? { accountId: null, newAccount: { name, currency: newCurrency }, rows: built.rows }
      : { accountId: target, rows: built.rows };
  };
  const previewRequestData = useMemo(
    () => buildRequest('Import'),
    // buildRequest liest nur built, target und newCurrency.
    [built, target, newCurrency],
  );

  // Vorschau der Datenbank (Duplikate, Regel-Treffer) bei jeder Änderung.
  useEffect(() => {
    if (!previewRequestData || result) {
      setPreview(null);
      return;
    }
    const id = ++previewRequest.current;
    setPreviewing(true);
    setPreviewError(null);
    previewImport(previewRequestData).then((response) => {
      if (id !== previewRequest.current) {
        return;
      }
      setPreviewing(false);
      if (response.status === 'ok') {
        setPreview(response.summary);
      } else {
        setPreview(null);
        setPreviewError(response.message);
      }
    });
  }, [previewRequestData, result]);

  /** Vorschau verwerfen; clearFile leert zusätzlich die Dateiauswahl. */
  const reset = (clearFile = false) => {
    setLoaded(null);
    setHeaderIndex(null);
    setMapping(emptyMapping());
    setPreview(null);
    setResult(null);
    setImportError(null);
    setLoadError(null);
    if (clearFile && fileInput.current) {
      fileInput.current.value = '';
    }
  };

  const applyHeader = (cells: Cell[][], index: number | null) => {
    setHeaderIndex(index);
    if (index === null) {
      setMapping(emptyMapping());
      setAutoConfident(false);
      return;
    }
    const detection = detectColumns(cells[index] ?? []);
    setMapping(detection.mapping);
    setAutoConfident(detection.confident);
  };

  const handleAnalyze = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const file = fileInput.current?.files?.[0];
    setResult(null);
    setImportError(null);
    if (!file) {
      setLoadError(t('errors.noFile'));
      return;
    }
    if (file.size > MAX_FILE_BYTES) {
      setLoadError(t('errors.fileTooLarge', { max: 5 }));
      return;
    }
    setLoading(true);
    setLoadError(null);
    try {
      const next = await readFile(file);
      setLoaded(next);
      applyHeader(next.cells, findHeaderRow(next.cells));
    } catch (error) {
      setLoaded(null);
      setLoadError(error instanceof Error && error.message === 'legacyExcel' ? t('errors.legacyExcel') : t('errors.unreadable'));
    } finally {
      setLoading(false);
    }
  };

  const handleImport = async () => {
    const request = buildRequest(newName.trim() || loaded?.name.replace(/\.[^.]+$/, '') || 'Import');
    if (!request) {
      return;
    }
    setImporting(true);
    setImportError(null);
    const response = await runImport(request);
    setImporting(false);
    if (response.status === 'ok') {
      setResult(response.summary);
      setPreview(null);
    } else {
      setImportError(response.message);
    }
  };

  const columnLabel = (index: number) => {
    const label = String(header[index] ?? '').trim();
    return t('mapping.column', { number: index + 1, label: label || t('mapping.unnamed') });
  };

  const closingCheck =
    result && built?.balanceCheck.status === 'closingOnly' && result.balance !== null
      ? { closing: built.balanceCheck.closing, balance: result.balance }
      : null;

  return (
    <div className="import-wizard">
      {/* Schritt 1: Datei und Konto */}
      <form className="form import-select" onSubmit={handleAnalyze}>
        {loadError ? (
          <p role="alert" className="form-error">
            {loadError}
          </p>
        ) : null}

        <label htmlFor="import-file">{t('file')}</label>
        <input
          ref={fileInput}
          id="import-file"
          name="file"
          type="file"
          accept=".csv,.txt,.xlsx,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          aria-describedby="import-file-hint"
          onChange={() => reset()}
        />
        <p id="import-file-hint" className="hint">
          {t('fileHint', { max: 5 })}
        </p>

        <label htmlFor="import-account">{t('account')}</label>
        <select id="import-account" value={target} onChange={(e) => setTarget(e.target.value)}>
          {accounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.name} ({a.currency})
            </option>
          ))}
          <option value={NEW_ACCOUNT}>{t('newAccount')}</option>
        </select>

        {target === NEW_ACCOUNT ? (
          <div className="field-row">
            <div className="filter-field">
              <label htmlFor="import-new-name">{t('newAccountName')}</label>
              <input
                id="import-new-name"
                value={newName}
                maxLength={120}
                placeholder={t('newAccountPlaceholder')}
                onChange={(e) => setNewName(e.target.value)}
              />
            </div>
            <div className="filter-field">
              <label htmlFor="import-new-currency">{t('currency')}</label>
              <select id="import-new-currency" value={newCurrency} onChange={(e) => setNewCurrency(e.target.value)}>
                {currencies.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>
          </div>
        ) : null}

        <button type="submit" disabled={loading}>
          {loading ? t('analyzing') : t('analyze')}
        </button>
      </form>

      {/* Schritt 2: Zuordnung und Vorschau */}
      {loaded && !result ? (
        <section className="import-preview" aria-labelledby="import-preview-heading">
          <h2 id="import-preview-heading">{t('preview.heading')}</h2>
          <p className="cell-note" id="import-detected">
            {[
              loaded.kind === 'xlsx' ? t('detected.excel') : t('detected.encoding', { encoding: (loaded.encoding ?? '').toUpperCase() }),
              loaded.delimiter ? t('detected.delimiter', { delimiter: t(`delimiters.${delimiterKey(loaded.delimiter)}`) }) : null,
              headerIndex !== null ? t('detected.header', { line: headerIndex + 1 }) : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>

          {!autoConfident || headerIndex === null ? (
            <p role="alert" className="form-warning" id="import-mapping-warning">
              {headerIndex === null ? t('mapping.noHeader') : t('mapping.unsure')}
            </p>
          ) : null}

          <fieldset className="import-mapping">
            <legend>{t('mapping.legend')}</legend>
            <div className="filter-field">
              <label htmlFor="import-header-line">{t('mapping.headerLine')}</label>
              <input
                id="import-header-line"
                type="number"
                min={1}
                max={loaded.cells.length}
                value={headerIndex === null ? '' : headerIndex + 1}
                onChange={(e) => {
                  const line = Number(e.target.value);
                  applyHeader(loaded.cells, Number.isInteger(line) && line >= 1 && line <= loaded.cells.length ? line - 1 : null);
                }}
              />
            </div>
            {headerIndex !== null
              ? MAPPED_FIELDS.map((field) => (
                  <div className="filter-field" key={field}>
                    <label htmlFor={`import-map-${field}`}>
                      {t(`fields.${field}`)}
                      {REQUIRED_FIELDS.includes(field) ? ' *' : ''}
                    </label>
                    <select
                      id={`import-map-${field}`}
                      value={mapping[field] ?? ''}
                      aria-invalid={REQUIRED_FIELDS.includes(field) && mapping[field] === null ? true : undefined}
                      onChange={(e) =>
                        setMapping((current) => ({ ...current, [field]: e.target.value === '' ? null : Number(e.target.value) }))
                      }
                    >
                      <option value="">{t('mapping.none')}</option>
                      {header.map((_, index) => (
                        <option key={index} value={index}>
                          {columnLabel(index)}
                        </option>
                      ))}
                    </select>
                  </div>
                ))
              : null}
          </fieldset>

          {missing.length > 0 && headerIndex !== null ? (
            <p role="alert" className="form-error">
              {t('mapping.missing', { fields: missing.map((f) => t(`fields.${f}`)).join(', ') })}
            </p>
          ) : null}

          {built ? (
            <>
              {built.rows.length > 0 ? (
                <div className="table-scroll">
                  <table className="transactions-table import-sample">
                    <caption>{t('preview.caption', { shown: Math.min(SAMPLE_ROWS, built.rows.length), total: built.rows.length })}</caption>
                    <thead>
                      <tr>
                        <th scope="col">{t('fields.date')}</th>
                        <th scope="col">{t('fields.counterparty')}</th>
                        <th scope="col">{t('fields.purpose')}</th>
                        <th scope="col" className="amount">
                          {t('fields.amount')}
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {built.rows.slice(0, SAMPLE_ROWS).map((row, index) => (
                        <tr key={index}>
                          <td className="nowrap">
                            {format.dateTime(new Date(`${row.booking_date}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' })}
                          </td>
                          <td>{row.counterparty}</td>
                          <td>{row.purpose}</td>
                          <td className={`amount ${row.amount < 0 ? 'amount-negative' : 'amount-positive'}`}>
                            {money(row.amount, row.currency ?? accountCurrency)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : (
                <p className="empty-state">{t('preview.noRows')}</p>
              )}

              {built.errors.length > 0 ? (
                <div role="alert" className="form-warning" id="import-row-errors">
                  <p>{t('preview.rowErrors', { count: built.errors.length })}</p>
                  <ul>
                    {built.errors.slice(0, 5).map((error) => (
                      <li key={error.line}>{t(`preview.${error.reason}`, { line: error.line, value: error.value || '–' })}</li>
                    ))}
                  </ul>
                  {built.errors.length > 5 ? <p>{t('preview.moreErrors', { count: built.errors.length - 5 })}</p> : null}
                </div>
              ) : null}
              {built.skippedZero > 0 ? <p className="cell-note">{t('preview.skippedZero', { count: built.skippedZero })}</p> : null}
              {built.skippedPending > 0 ? (
                <p className="cell-note" id="import-skipped-pending">
                  {t('preview.skippedPending', { count: built.skippedPending })}
                </p>
              ) : null}
              {built.rows.length > MAX_IMPORT_ROWS ? (
                <p role="alert" className="form-error">
                  {t('errors.tooManyRows', { max: MAX_IMPORT_ROWS })}
                </p>
              ) : null}

              <BalanceCheckNote check={built.balanceCheck} money={money} />

              <div className="import-summary" role="status" id="import-summary">
                {previewing ? (
                  <p>{t('preview.checking')}</p>
                ) : preview ? (
                  <p>
                    {t('preview.summary', {
                      new: preview.new,
                      duplicates: preview.duplicates,
                      categorized: preview.categorized,
                    })}
                    {preview.enriched > 0 ? ` ${t('preview.enriched', { count: preview.enriched })}` : null}
                  </p>
                ) : null}
              </div>
              {previewError ? (
                <p role="alert" className="form-error">
                  {previewError}
                </p>
              ) : null}
              {importError ? (
                <p role="alert" className="form-error">
                  {importError}
                </p>
              ) : null}

              <button
                type="button"
                className="button"
                onClick={handleImport}
                disabled={
                  !previewRequestData || !preview || (preview.new === 0 && preview.enriched === 0) || previewing || importing
                }
              >
                {importing
                  ? t('importing')
                  : preview && preview.new === 0 && preview.enriched > 0
                    ? t('importEnrich', { count: preview.enriched })
                    : t('import', { count: preview?.new ?? 0 })}
              </button>
            </>
          ) : null}
        </section>
      ) : null}

      {/* Schritt 3: Ergebnis */}
      {result ? (
        <section className="import-result" aria-labelledby="import-result-heading">
          <h2 id="import-result-heading">{t('result.heading')}</h2>
          <p role="status" className="form-success" id="import-result">
            {t('result.summary', { new: result.new, duplicates: result.duplicates, categorized: result.categorized })}
            {result.enriched > 0 ? ` ${t('result.enriched', { count: result.enriched })}` : null}
            {result.learned > 0 ? ` ${t('result.learned', { count: result.learned })}` : null}
            {result.suggested > 0 ? (
              <>
                {' '}
                {t('result.suggested', { count: result.suggested })}{' '}
                <Link href="/dashboard/transactions/review">{t('result.toReview')}</Link>
              </>
            ) : null}
          </p>
          {built?.balanceCheck.status === 'mismatch' ? <BalanceCheckNote check={built.balanceCheck} money={money} /> : null}
          {closingCheck ? (
            closingCheck.closing === closingCheck.balance ? (
              <p className="form-success" id="import-closing-check">
                {t('result.closingOk', { balance: money(closingCheck.balance, result.currency) })}
              </p>
            ) : (
              <p role="alert" className="form-warning" id="import-closing-check">
                {t('result.closingMismatch', {
                  closing: money(closingCheck.closing, result.currency),
                  balance: money(closingCheck.balance, result.currency),
                })}
              </p>
            )
          ) : null}
          <div className="actions">
            <Link className="button" href="/dashboard/transactions">
              {t('result.toList')}
            </Link>
            <button type="button" className="button button-secondary" onClick={() => reset(true)}>
              {t('result.again')}
            </button>
          </div>
        </section>
      ) : null}
    </div>
  );
}

function delimiterKey(delimiter: Delimiter): 'semicolon' | 'comma' | 'tab' {
  return delimiter === ';' ? 'semicolon' : delimiter === ',' ? 'comma' : 'tab';
}

function BalanceCheckNote({
  check,
  money,
}: {
  check: ReturnType<typeof buildRows>['balanceCheck'];
  money: (value: number) => string;
}) {
  const t = useTranslations('Import.balance');
  switch (check.status) {
    case 'ok':
      return (
        <p className="form-success" id="import-balance-check">
          {t('ok', { opening: money(check.opening), closing: money(check.closing) })}
        </p>
      );
    case 'mismatch':
      return (
        <p role="alert" className="form-warning" id="import-balance-check">
          {t('mismatch', {
            opening: money(check.opening),
            closing: money(check.closing),
            sum: money(check.sum),
            difference: money(check.difference),
          })}
        </p>
      );
    case 'closingOnly':
      return (
        <p className="cell-note" id="import-balance-check">
          {t('closingOnly', { closing: money(check.closing) })}
        </p>
      );
    default:
      return null;
  }
}
