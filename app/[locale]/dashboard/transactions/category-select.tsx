/**
 * Kategorie-Auswahl mit Gruppen nach Art (Ausgaben, Einnahmen, Transfers) –
 * gemeinsam für Regel-Formular und Kategorie-Korrektur.
 */
import { useTranslations } from 'next-intl';

import type { CategoryOption } from './transaction-form';

type CategorySelectProps = {
  id: string;
  name: string;
  categories: CategoryOption[];
  defaultValue: string;
  /** Leere Option („Ohne Kategorie“ bzw. „Bitte wählen“). */
  emptyLabel: string;
  required?: boolean;
};

export function CategorySelect({ id, name, categories, defaultValue, emptyLabel, required }: CategorySelectProps) {
  const t = useTranslations('Transactions.form');
  const groups = (['expense', 'income', 'transfer'] as const)
    .map((kind) => ({ kind, options: categories.filter((c) => c.kind === kind) }))
    .filter((group) => group.options.length > 0);

  return (
    <select id={id} name={name} defaultValue={defaultValue} required={required}>
      <option value="">{emptyLabel}</option>
      {groups.map((group) => (
        <optgroup key={group.kind} label={t(`categoryGroups.${group.kind}`)}>
          {group.options.map((category) => (
            <option key={category.id} value={category.id}>
              {category.label}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}
