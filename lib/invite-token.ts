/**
 * lib/invite-token.ts
 *
 * Format, Erzeugung und Hashing der Einladungstokens (advisor_clients).
 *
 * - Token: 32 Byte aus crypto.randomBytes (256 Bit), base64url-kodiert →
 *   43 URL-sichere Zeichen. accept_advisor_invitation() verlangt ≥ 32 Zeichen.
 * - In der Datenbank steht ausschließlich SHA-256(token) als Hex – exakt der
 *   Wert, den die RPC per encode(digest(p_token, 'sha256'), 'hex') vergleicht.
 *   Ein Salt ist bewusst nicht vorgesehen: Der Hash muss für den Lookup
 *   deterministisch sein, und bei 256 Bit Zufall sind Wörterbuch- oder
 *   Rainbow-Table-Angriffe aussichtslos.
 */
import 'server-only';

import { createHash, randomBytes } from 'node:crypto';

export const INVITE_TOKEN_BYTES = 32;
export const INVITE_TTL_DAYS = 7;

/** base64url ohne Padding: ceil(32 * 4 / 3) = 43 Zeichen */
const INVITE_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export function generateInviteToken(): string {
  return randomBytes(INVITE_TOKEN_BYTES).toString('base64url');
}

export function hashInviteToken(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

/** Formatprüfung vor dem RPC-Aufruf – ersetzt NICHT die Prüfung in der Datenbank. */
export function isWellFormedInviteToken(value: unknown): value is string {
  return typeof value === 'string' && INVITE_TOKEN_PATTERN.test(value);
}

export function invitePath(token: string): string {
  return `/invite/${token}`;
}
