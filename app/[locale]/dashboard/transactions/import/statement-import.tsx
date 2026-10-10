'use client';

/**
 * PDF-Kontoauszug (N26) importieren: Die Datei wird auf dem Server gelesen
 * und geprüft (lib/actions/import-statement.ts). Vorschau je Konto des
 * Auszugs (Hauptkonto, Spaces) mit Saldenprüfung, Zielkonto, neuen und
 * vorhandenen Buchungen; importiert werden alle Konten zusammen.
 */
import { useFormatter, useTranslations } from 'next-intl';
import { useEffect, useMemo, useRef, useState } from 'react';

import { Link } from '@/i18n/navigation';
import {
  importStatement,
  previewStatement,
  type StatementAccount,
  type StatementResponse,
  type StatementSectionResult,
  type StatementTargets,
} from '@/lib/actions/import-statement';
import { formatIban } from '@/lib/import/statement';

type StatementImportProps = {
  file: File;
  /** Konten beim Laden der Seite; danach liefert jede Antwort die aktuelle Liste. */
  accounts: StatementAccount[];
  onReset: () => void;
};

type OkResponse = Extract<StatementResponse, { status: 'ok' }>;

const NEW_ACCOUNT = 'new';

export function StatementImport({ file, accounts: initialAccounts, onReset }: StatementImportProps) {
  const t = useTranslations('Import.pdf');
  const format = useFormatter();
  const money = (value: number) => format.number(value, { style: 'currency', currency: 'EUR' });
  const day = (iso: string) => format.dateTime(new Date(`${iso}T00:00:00Z`), { dateStyle: 'medium', timeZone: 'UTC' });

  /** Zielkonten (nur die Auswahl löst eine neue Vorschau aus, nicht der Name). */
  const [choices, setChoices] = useState<Record<string, string>>({});
  const [names, setNames] = useState<Record<string, string>>({});
  const [preview, setPreview] = useState<OkResponse | null>(null);
  const [result, setResult] = useState<OkResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [importing, setImporting] = useState(false);
  const request = useRef(0);
  const accounts = (result ?? preview)?.accounts ?? initialAccounts;

  const targets = (sections: StatementSectionResult[]): StatementTargets =>
    Object.fromEntries(
      sections.map((section) => {
        const choice = choices[section.iban] ?? (section.accountId ?? NEW_ACCOUNT);
        return [
          section.iban,
          {
            accountId: choice === NEW_ACCOUNT ? null : choice,
            name: (names[section.iban] ?? section.newAccountName).trim() || section.newAccountName,
          },
        ];
      }),
    );

  const formData = (withTargets: StatementTargets | null) => {
    const data = new FormData();
    data.set('file', file);
    if (withTargets) {
      data.set('targets', JSON.stringify(withTargets));
    }
    return data;
  };

  const choiceKey = useMemo(() => JSON.stringify(choices), [choices]);

  // Vorschau beim Laden der Datei und bei jeder Änderung der Zielkonten.
  useEffect(() => {
    const id = ++request.current;
    setLoading(true);
    setError(null);
    const current = preview;
    previewStatement(formData(current ? targets(current.sections) : null)).then((response) => {
      if (id !== request.current) {
        return;
      }
      setLoading(false);
      if (response.status === 'ok') {
        setPreview(response);
      } else {
        // Ungültige Auswahl (z. B. zwei Konten auf dasselbe Ziel): Vorschau
        // bleibt stehen, damit die Auswahl korrigiert werden kann.
        if (!current) {
          setPreview(null);
        }
        setError(response.message);
      }
    });
    // Neue Vorschau nur bei anderer Datei oder anderen Zielkonten (nicht bei
    // jeder Eingabe im Namen eines neuen Kontos).
  }, [file, choiceKey]);

  const handleImport = async () => {
    if (!preview) {
      return;
    }
    setImporting(true);
    setError(null);
    const response = await importStatement(formData(targets(preview.sections)));
    setImporting(false);
    if (response.status === 'ok') {
      setResult(response);
      setPreview(null);
    } else {
      setError(response.message);
    }
  };

  const label = (section: StatementSectionResult) =>
    section.kind === 'main' ? t('mainAccount') : t('space', { name: section.name ?? '' });

  const totals = preview
    ? preview.sections.reduce(
        (sum, s) => ({ new: sum.new + s.new, duplicates: sum.duplicates + s.duplicates, newAccounts: sum.newAccounts + (s.accountId ? 0 : 1) }),
        { new: 0, duplicates: 0, newAccounts: 0 },
      )
    : null;

  if (result) {
    const created = result.sections.filter((s) => s.accountId === null).length;
    return (
      <section className="import-result" aria-labelledby="statement-result-heading">
        <h2 id="statement-result-heading">{t('result.heading')}</h2>
        <p role="status" className="form-success" id="statement-result">
          {t('result.summary', {
            new: result.sections.reduce((sum, s) => sum + s.new, 0),
            duplicates: result.sections.reduce((sum, s) => sum + s.duplicates, 0),
            accounts: result.sections.length,
            created,
          })}
          {result.ownIbansAdded > 0 ? ` ${t('result.ownIbans', { count: result.ownIbansAdded })}` : null}
          {result.learned > 0 ? ` ${t('result.learned', { count: result.learned })}` : null}
          {result.suggested > 0 ? (
            <>
              {' '}
              {t('result.suggested', { count: result.suggested })}{' '}
              <Link href="/dashboard/transactions/review">{t('result.toReview')}</Link>
            </>
          ) : null}
        </p>
        <ul className="statement-sections">
          {result.sections.map((section) => (
            <li key={section.iban} className="statement-section" data-section={section.iban}>
              <p className="statement-section-title">
                <strong>{label(section)}</strong>
                {section.resultAccountId ? (
                  <>
                    {' → '}
                    <Link href={`/dashboard/transactions?account=${section.resultAccountId}`}>
                      {section.accountId ? accounts.find((a) => a.id === section.accountId)?.name : section.newAccountName}
                    </Link>
                  </>
                ) : null}
              </p>
              <p className="cell-note">
                {t('result.section', { new: section.new, duplicates: section.duplicates, probable: section.probable })}
              </p>
              <BalanceNote section={section} money={money} after />
            </li>
          ))}
        </ul>
        <div className="actions">
          <Link className="button" href="/dashboard/transactions">
            {t('result.toList')}
          </Link>
          <button type="button" className="button button-secondary" onClick={onReset}>
            {t('result.again')}
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="import-preview" aria-labelledby="statement-preview-heading" aria-busy={loading}>
      <h2 id="statement-preview-heading">{t('heading')}</h2>
      {error ? (
        <p role="alert" className="form-error" id="statement-error">
          {error}
        </p>
      ) : null}
      {loading && !preview ? <p role="status">{t('reading')}</p> : null}
      {preview ? (
        <>
          <p className="cell-note" id="statement-detected">
            {preview.provisional
              ? t('detected.provisional', { from: day(preview.period.from), to: day(preview.period.to) })
              : t('detected.monthly', {
                  number: preview.number ?? '',
                  from: day(preview.period.from),
                  to: day(preview.period.to),
                })}
            {' · '}
            {t('detected.accounts', { count: preview.sections.length })}
          </p>
          {preview.provisional ? <p className="hint">{t('provisionalHint')}</p> : null}

          <ul className="statement-sections" id="statement-preview">
            {preview.sections.map((section) => {
              const choice = choices[section.iban] ?? (section.accountId ?? NEW_ACCOUNT);
              const options = accounts.filter((a) => a.iban === null || a.iban === section.iban);
              // Gibt es schon ein Konto mit dieser IBAN, ist es das einzig mögliche Ziel.
              const hasIbanAccount = accounts.some((a) => a.iban === section.iban);
              return (
                <li key={section.iban} className="statement-section" data-section={section.iban}>
                  <p className="statement-section-title">
                    <strong>{label(section)}</strong>
                    <span className="cell-note nowrap"> {formatIban(section.iban)}</span>
                  </p>
                  <p className="form-success statement-balance" data-check="statement">
                    {t('balanceOk', {
                      opening: money(section.opening),
                      incoming: money(section.incoming),
                      outgoing: money(Math.abs(section.outgoing)),
                      closing: money(section.closing),
                    })}
                  </p>
                  <div className="field-row">
                    <div className="filter-field">
                      <label htmlFor={`statement-target-${section.iban}`}>{t('target')}</label>
                      <select
                        id={`statement-target-${section.iban}`}
                        value={choice}
                        disabled={importing}
                        onChange={(e) => setChoices((current) => ({ ...current, [section.iban]: e.target.value }))}
                      >
                        {hasIbanAccount ? null : <option value={NEW_ACCOUNT}>{t('newAccount')}</option>}
                        {options.map((account) => (
                          <option key={account.id} value={account.id}>
                            {account.name} ({account.currency})
                          </option>
                        ))}
                      </select>
                    </div>
                    {choice === NEW_ACCOUNT ? (
                      <div className="filter-field">
                        <label htmlFor={`statement-name-${section.iban}`}>{t('newAccountName')}</label>
                        <input
                          id={`statement-name-${section.iban}`}
                          value={names[section.iban] ?? section.newAccountName}
                          maxLength={120}
                          disabled={importing}
                          onChange={(e) => setNames((current) => ({ ...current, [section.iban]: e.target.value }))}
                        />
                      </div>
                    ) : null}
                  </div>
                  <p className="statement-counts" data-counts="statement">
                    {t('counts', {
                      rows: section.rows,
                      new: section.new,
                      duplicates: section.duplicates,
                      categorized: section.categorized,
                    })}
                    {section.skippedZero > 0 ? ` ${t('skippedZero', { count: section.skippedZero })}` : null}
                  </p>
                  {section.probable > 0 ? (
                    <details className="form-warning statement-probable" data-probable={section.probable}>
                      <summary>{t('probable', { count: section.probable })}</summary>
                      <ul>
                        {section.probableRows.map((row, index) => (
                          <li key={index}>
                            {day(row.booking_date)} · {row.counterparty ?? '–'} · {money(row.amount)}
                          </li>
                        ))}
                      </ul>
                    </details>
                  ) : null}
                  {section.openingSet ? (
                    <p className="hint">{t('openingSet', { opening: money(section.opening) })}</p>
                  ) : null}
                  <BalanceNote section={section} money={money} />
                </li>
              );
            })}
          </ul>

          {preview.ownIbansAdded > 0 ? <p className="hint">{t('ownIbans', { count: preview.ownIbansAdded })}</p> : null}

          <button
            type="button"
            className="button"
            id="statement-import-button"
            onClick={handleImport}
            disabled={loading || importing || error !== null || !totals || (totals.new === 0 && totals.newAccounts === 0)}
          >
            {importing
              ? t('importing')
              : totals && totals.new === 0 && totals.newAccounts === 0
                ? t('nothingNew')
                : t('import', { count: totals?.new ?? 0 })}
          </button>
        </>
      ) : null}
      {!preview && !loading ? (
        <button type="button" className="button button-secondary" onClick={onReset}>
          {t('chooseOther')}
        </button>
      ) : null}
    </section>
  );
}

/** Kontostand der App zum Ende des Auszugs gegen den Auszug. */
function BalanceNote({
  section,
  money,
  after = false,
}: {
  section: StatementSectionResult;
  money: (value: number) => string;
  after?: boolean;
}) {
  const t = useTranslations('Import.pdf');
  if (Math.round(section.balance * 100) === Math.round(section.closing * 100)) {
    return (
      <p className="cell-note" data-balance="ok">
        {t(after ? 'balanceAfterOk' : 'balancePreviewOk', { balance: money(section.balance) })}
      </p>
    );
  }
  return (
    <p role="alert" className="form-warning" data-balance="mismatch">
      {t('balanceMismatch', { balance: money(section.balance), closing: money(section.closing) })}
    </p>
  );
}
