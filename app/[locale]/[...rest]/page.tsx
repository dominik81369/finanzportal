/**
 * app/[locale]/[...rest]/page.tsx
 *
 * Fängt alle Pfade ohne eigene Seite ab, damit app/[locale]/not-found.tsx
 * innerhalb des Sprach-Layouts erscheint (lang, Styles, Übersetzung) statt
 * der nackten Standard-404 von Next.js.
 */
import { notFound } from 'next/navigation';

export default function CatchAllPage() {
  notFound();
}
