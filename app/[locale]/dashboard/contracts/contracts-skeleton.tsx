/**
 * Ladezustand der Vertragsseiten (Suspense-Fallback, während die Daten
 * gestreamt werden): Platzhalterflächen in Palettenfarben (.skeleton, ohne
 * Bewegung bei „weniger Bewegung“). Der Text ist nur für Screenreader;
 * aria-busy kennzeichnet den laufenden Ladevorgang.
 *
 * Bewusst kein loading.tsx, sondern Suspense mit Schlüssel je Render in der
 * Seite: Beim Neuladen nach einer Aktion (router.refresh) wartete der Router
 * sonst auf den gestreamten Inhalt einer schon sichtbaren Grenze und
 * übernahm ihn gelegentlich nicht (Next.js 15).
 */
import { getTranslations } from 'next-intl/server';

export async function ContractsSkeleton({ variant }: { variant: 'list' | 'detail' | 'form' }) {
  const t = await getTranslations('Contracts');
  const rows = variant === 'list' ? 3 : variant === 'detail' ? 4 : 6;

  return (
    <div className="skeleton-stack" aria-busy="true" aria-live="polite">
      <p className="sr-only" role="status">
        {t('loading')}
      </p>
      {Array.from({ length: rows }, (_, index) => (
        <span
          key={index}
          aria-hidden="true"
          className={`skeleton ${variant === 'list' ? 'skeleton-card' : 'skeleton-row'}`}
        />
      ))}
    </div>
  );
}
