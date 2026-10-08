'use client';

/**
 * Formular für Aktionen auf gestreamten Seiten (Verträge: Bestätigen,
 * Verwerfen, Lösen …): ruft die Server Action auf und zeigt danach den
 * neuen Stand mit Meldung.
 *
 * Die Actions leiten nicht per redirect() weiter, sondern liefern das Ziel
 * (z. B. lib/actions/contracts.ts); der Client navigiert selbst – auf derselben
 * Seite mit router.replace (Meldungen erzeugen keinen Verlaufseintrag),
 * sonst mit router.push. Die Suspense-Grenzen der Seiten tragen je Render
 * einen neuen Schlüssel; sonst wurde der gestreamte Inhalt nach einer
 * Aktion gelegentlich nicht übernommen (Next.js 15).
 *
 * Ohne JavaScript sendet das Formular die Action wie gewohnt; die Seite
 * zeigt dann den neuen Stand ohne Meldung.
 */
import { useRouter } from 'next/navigation';
import { useCallback, useTransition, type FormEvent, type ReactNode } from 'react';

import type { ContractActionResult } from '@/lib/actions/contracts';

type ActionFormProps = {
  action: (formData: FormData) => Promise<ContractActionResult>;
  className?: string;
  children: ReactNode;
};

/** Nach einer Action zur gelieferten Adresse (gleiche Seite: replace, sonst push). */
export function useShowResult() {
  const router = useRouter();
  return useCallback(
    (redirectTo: string) => {
      const target = new URL(redirectTo, window.location.href);
      const href = `${target.pathname}${target.search}`;
      if (target.pathname === window.location.pathname) {
        router.replace(href);
      } else {
        router.push(href);
      }
    },
    [router],
  );
}

export function ActionForm({ action, className, children }: ActionFormProps) {
  const showResult = useShowResult();
  const [isPending, startTransition] = useTransition();

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (isPending) {
      return;
    }
    const formData = new FormData(event.currentTarget);
    startTransition(async () => {
      const { redirectTo } = await action(formData);
      startTransition(() => showResult(redirectTo));
    });
  };

  return (
    <form
      action={action as unknown as (formData: FormData) => Promise<void>}
      onSubmit={handleSubmit}
      className={className}
      aria-busy={isPending || undefined}
    >
      {children}
    </form>
  );
}
