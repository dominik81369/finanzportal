import type { Metadata } from 'next';

import { PlaceholderSection } from './placeholder-section';

export const metadata: Metadata = { title: 'Übersicht' };

export default function OverviewPage() {
  return (
    <PlaceholderSection
      title="Übersicht"
      description="Ihre Finanzen auf einen Blick."
      planned={[
        'Kontostände und Vermögen im Überblick',
        'Einnahmen und Ausgaben des laufenden Monats',
        'Hinweise zu Budgets und anstehenden Kündigungsfristen',
      ]}
    />
  );
}
