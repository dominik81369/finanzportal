/**
 * i18n/messages.check.ts
 *
 * Compile-Zeit-Prüfung: messages/en.json muss exakt dieselben Schlüssel wie
 * messages/de.json haben. Fehlt oder überzählt ein Schlüssel, schlägt
 * `npm run typecheck` (auch in CI) fehl. Wird nie importiert.
 */
import type de from '../messages/de.json';
import type en from '../messages/en.json';

/** Rekursiv: nur die Schlüsselstruktur, Werte werden zu string. */
type Shape<T> = T extends string ? string : { [K in keyof T]: Shape<T[K]> };

type Exact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;

const sameKeys: Exact<Shape<typeof de>, Shape<typeof en>> = true;

export {};
void sameKeys;
