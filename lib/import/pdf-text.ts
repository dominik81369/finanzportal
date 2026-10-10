/**
 * lib/import/pdf-text.ts
 *
 * Text einer PDF mit Position je Seite (pdf.js über unpdf, eine Variante
 * ohne Worker für Serverless-Umgebungen). Nur auf dem Server verwendet
 * (lib/actions/import-statement.ts); die Datei wird nicht gespeichert.
 */
import { extractTextItems } from 'unpdf';

import type { PdfPage } from '@/lib/import/n26-pdf';

/** Seiten mit Textstücken (x/y in PDF-Koordinaten, Ursprung unten links). */
export async function readPdfPages(bytes: Uint8Array): Promise<PdfPage[]> {
  const { items } = await extractTextItems(bytes);
  return items.map((page) => ({
    items: page
      .filter((item) => item.str.trim() !== '')
      .map((item) => ({ text: item.str, x: item.x, y: item.y, width: item.width, size: item.fontSize })),
  }));
}

/** Beginnt die Datei wie eine PDF („%PDF-“)? */
export function looksLikePdf(bytes: Uint8Array): boolean {
  return bytes.length > 5 && String.fromCharCode(...bytes.subarray(0, 5)) === '%PDF-';
}
