import type { Metadata } from 'next';

import { PlaceholderSection } from '../placeholder-section';

export const metadata: Metadata = { title: 'Budgets' };

export default function BudgetsPage() {
  return (
    <PlaceholderSection
      title="Budgets"
      description="Ausgabengrenzen je Kategorie, Tag oder Konto."
      planned={[
        'Budgets für Woche, Monat, Quartal oder Jahr',
        'Fortschritt und Warnung ab einer frei wählbaren Schwelle',
      ]}
    />
  );
}
