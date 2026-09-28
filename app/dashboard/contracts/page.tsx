import type { Metadata } from 'next';

import { PlaceholderSection } from '../placeholder-section';

export const metadata: Metadata = { title: 'Verträge' };

export default function ContractsPage() {
  return (
    <PlaceholderSection
      title="Verträge"
      description="Wiederkehrende Zahlungen wie Abos, Versicherungen und Mitgliedschaften."
      planned={[
        'Automatisch erkannte Verträge bestätigen oder verwerfen',
        'Rhythmus, erwarteter Betrag und nächste Abbuchung',
        'Kündigungsfristen mit Erinnerung vor dem Stichtag',
      ]}
    />
  );
}
