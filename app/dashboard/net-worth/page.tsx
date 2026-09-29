import type { Metadata } from 'next';

import { PlaceholderSection } from '../placeholder-section';

export const metadata: Metadata = { title: 'Net Worth' };

export default function NetWorthPage() {
  return (
    <PlaceholderSection
      title="Net Worth"
      description="Ihr Nettovermögen: Konten, Depots und Immobilien abzüglich Verbindlichkeiten."
      planned={[
        'Vermögen nach Anlageklasse und Region',
        'Entwicklung über die Zeit',
      ]}
    />
  );
}
