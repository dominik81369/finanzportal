import type { Metadata } from 'next';

import { PlaceholderSection } from '../placeholder-section';

export const metadata: Metadata = { title: 'Transaktionen' };

export default function TransactionsPage() {
  return (
    <PlaceholderSection
      title="Transaktionen"
      description="Alle Buchungen Ihrer Konten – manuell erfasst, importiert oder synchronisiert."
      planned={[
        'Manuelle Erfassung mit Kategorie und Tags',
        'Suche und Filter nach Konto, Kategorie, Tag und Zeitraum',
        'Automatische Kategorisierung über eigene Regeln',
      ]}
    />
  );
}
